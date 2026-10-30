import Darwin
import Foundation
import RambleFlowCore

public enum Providers {
    public static func make(_ id: ProviderID, model: String, transport: HTTPTransport, temporaryDirectory: URL) -> TranscriptionProvider {
        switch id {
        case .groq: return OpenAICompatibleProvider.groq(transport: transport, temporaryDirectory: temporaryDirectory, model: model)
        case .openai: return OpenAICompatibleProvider.openAI(transport: transport, temporaryDirectory: temporaryDirectory, model: model)
        }
    }
}

/// Status written by the background process after every pass, for `ramble-flow status`.
public struct StatusFile: Codable, Equatable, Sendable {
    public var version: String
    public var pid: Int32
    public var updatedAt: Date
    public var phase: String
    public var detail: String?
    public var pending: Int
    public var attention: Int
    public var undecided: Int
    public var lastExportedName: String?
    public var lastExportedAt: Date?

    public static func read(_ url: URL) -> StatusFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(StatusFile.self, from: data)
    }

    func write(_ url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) { try? data.write(to: url, options: [.atomic]) }
    }
}

/// `ramble-flow run`: the background process started by the LaunchAgent.
public enum Daemon {
    public static func dependencies(paths: AppPaths, store: JobStore, config: ConfigStore, transport: HTTPTransport = URLSessionTransport(),
                                    settings: WorkerSettings = WorkerSettings()) -> WorkerDependencies {
        let uploads = paths.work.appendingPathComponent("uploads", isDirectory: true)
        let scratch = paths.work
        return WorkerDependencies(
            store: store, paths: paths, config: config,
            credentials: KeyFileStore(url: paths.secrets),
            audio: AVFoundationAudioPipeline(),
            makeProvider: { id, model in Providers.make(id, model: model, transport: transport, temporaryDirectory: uploads) },
            sourceFolder: { ConfiguredFolders.source(config.current) },
            destinationFolder: { ConfiguredFolders.destination(config.current) },
            metadata: { VoiceMemosMetadata.load(recordingsFolder: $0, scratch: scratch) },
            settings: settings)
    }

    public static func run(paths: AppPaths, interval: TimeInterval = 10) async -> Int32 {
        umask(0o077)
        do {
            try paths.createDirectories()
        } catch {
            FileHandle.standardError.write(Data("ramble-flow: cannot create \(paths.root.path)\n".utf8))
            return 1
        }
        Log.shared.configure(directory: paths.logs)

        let lock = WorkerLock()
        guard lock.acquire(at: paths.lock) else {
            Log.shared.warn("another ramble-flow process is already running; exiting")
            return 0
        }

        let store: JobStore
        do {
            store = try JobStore(url: paths.database)
        } catch {
            Log.shared.error("cannot open the job database: \(error)")
            return 1
        }
        let config = ConfigStore(url: paths.config)
        var settings = WorkerSettings()
        var scanInterval = interval
        #if RAMBLE_FLOW_TEST_HOOKS
        let env = ProcessInfo.processInfo.environment
        if let value = env["RAMBLE_FLOW_TEST_SCAN_INTERVAL"].flatMap(Double.init) { scanInterval = value }
        if let value = env["RAMBLE_FLOW_TEST_STABILITY_WINDOW"].flatMap(Double.init) { settings.stabilityWindow = value }
        #endif
        let worker = TranscriptionWorker(dependencies: dependencies(paths: paths, store: store, config: config, settings: settings))
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        Log.shared.info("started ramble-flow \(Product.version) pid \(getpid()) on macOS \(os)")

        let loop = Task {
            var lastActivationProblem: String?
            while !Task.isCancelled {
                let current = config.current
                if current.setupCompleted {
                    if ((try? store.activation()) ?? nil) == nil {
                        do {
                            let info = try await worker.activate()
                            Log.shared.info("watching for recordings made after \(ISO8601DateFormatter().string(from: info.cutoff))")
                            lastActivationProblem = nil
                        } catch {
                            let reason = "\(error)"
                            if reason != lastActivationProblem {
                                Log.shared.warn("cannot start watching yet: \(reason)")
                                lastActivationProblem = reason
                            }
                        }
                    }
                    let status = await worker.tick()
                    let last = status
                    StatusFile(version: Product.version, pid: getpid(), updatedAt: Date(), phase: last.phase.rawValue, detail: last.detail,
                               pending: last.pending, attention: last.attention, undecided: last.undecided,
                               lastExportedName: last.lastExportedName, lastExportedAt: last.lastExportedAt).write(paths.status)
                } else {
                    StatusFile(version: Product.version, pid: getpid(), updatedAt: Date(), phase: "notConfigured", detail: nil,
                               pending: 0, attention: 0, undecided: 0, lastExportedName: nil, lastExportedAt: nil).write(paths.status)
                }
                try? await Task.sleep(nanoseconds: UInt64(scanInterval * 1_000_000_000))
            }
        }

        // SIGTERM (launchctl bootout, logout), SIGINT, SIGHUP: stop after the current step. Every
        // step is committed to the job store, so stopping at any point is safe.
        var sources: [DispatchSourceSignal] = []
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler {
                Log.shared.info("stopping (signal \(sig))")
                loop.cancel()
            }
            source.resume()
            sources.append(source)
        }
        await loop.value
        withExtendedLifetime(sources) {}
        lock.release()
        Log.shared.info("stopped")
        Log.shared.flush()
        return 0
    }
}
