import Foundation

/// A provider failure, classified by what the worker should do about it.
public enum ProviderError: Error, Equatable, Sendable {
    /// No connection: nothing reached the provider. Retry with backoff ("waiting for internet").
    case offline
    /// The request may have reached the provider (timeout, dropped connection after sending).
    /// The provider may have processed and billed it; retries are bounded.
    case uncertain(String)
    /// 401: the key is wrong or revoked.
    case unauthorized(String)
    /// 403: the key lacks permission (organization, region, model access).
    case forbidden(String)
    /// 413: the upload is too large for this provider/tier.
    case payloadTooLarge
    /// 429 rate limit. `retryAfter` from headers when present.
    case rateLimited(retryAfter: TimeInterval?)
    /// Quota or billing exhausted: needs the user, not a hot retry loop.
    case quotaExhausted(String)
    /// Model or parameters rejected (400/404/422): a configuration problem.
    case configuration(String)
    /// The provider could not decode the audio.
    case invalidAudio(String)
    /// 5xx or other transient server failure.
    case server(Int)
    /// 2xx with a body we could not understand.
    case malformedResponse
    case canceled

    public var shortCode: String {
        switch self {
        case .offline: return "offline"
        case .uncertain: return "uncertain"
        case .unauthorized: return "unauthorized"
        case .forbidden: return "forbidden"
        case .payloadTooLarge: return "too-large"
        case .rateLimited: return "rate-limited"
        case .quotaExhausted: return "quota"
        case .configuration: return "configuration"
        case .invalidAudio: return "invalid-audio"
        case .server(let status): return "server-\(status)"
        case .malformedResponse: return "malformed-response"
        case .canceled: return "canceled"
        }
    }
}

public struct ProviderTranscript: Sendable, Equatable {
    public var text: String
    public init(text: String) { self.text = text }
}

public enum KeyCheck: Sendable, Equatable {
    /// The provider accepted the key for an authenticated call. This proves the credential, not
    /// transcription quota or billing.
    case accepted
    case rejected(String)
    case unreachable
    case inconclusive(String)
}

public protocol TranscriptionProvider: Sendable {
    var id: ProviderID { get }
    var model: String { get }
    var capabilities: ProviderCapabilities { get }
    func transcribe(audio: URL, language: String?, apiKey: String) async throws -> ProviderTranscript
    func checkKey(_ apiKey: String) async -> KeyCheck
}

/// Shared request/response handling for the OpenAI-compatible transcription endpoints of Groq and
/// OpenAI. Hosts are fixed in code; there is no user-configurable base URL.
public struct OpenAICompatibleProvider: TranscriptionProvider {
    public let id: ProviderID
    public let model: String
    public let capabilities: ProviderCapabilities
    let transcriptionURL: URL
    let modelsURL: URL
    let transport: HTTPTransport
    let temporaryDirectory: URL
    let uploadTimeout: TimeInterval

    public static func groq(transport: HTTPTransport, temporaryDirectory: URL, model: String = ProviderID.groq.defaultModel) -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(
            id: .groq,
            model: model,
            capabilities: ProviderCapabilities(
                // 25 MB on the free tier (larger on paid tiers; not assumed).
                maxUploadBytes: 25_000_000,
                targetUploadBytes: 20_000_000,
                maxChunkDuration: 30 * 60,
                acceptedExtensions: ["flac", "mp3", "mp4", "mpeg", "mpga", "m4a", "ogg", "wav", "webm"]),
            transcriptionURL: endpoint(host: "api.groq.com", path: "/openai/v1/audio/transcriptions"),
            modelsURL: endpoint(host: "api.groq.com", path: "/openai/v1/models"),
            transport: transport,
            temporaryDirectory: temporaryDirectory,
            uploadTimeout: 300)
    }

    public static func openAI(transport: HTTPTransport, temporaryDirectory: URL, model: String = ProviderID.openai.defaultModel) -> OpenAICompatibleProvider {
        OpenAICompatibleProvider(
            id: .openai,
            model: model,
            capabilities: ProviderCapabilities(
                maxUploadBytes: 25_000_000,
                targetUploadBytes: 20_000_000,
                // No duration limit is documented for gpt-transcribe; earlier OpenAI transcription
                // models rejected long inputs, so requests stay at 20 minutes.
                maxChunkDuration: 20 * 60,
                acceptedExtensions: ["mp3", "mp4", "mpeg", "mpga", "m4a", "wav", "webm"]),
            transcriptionURL: endpoint(host: "api.openai.com", path: "/v1/audio/transcriptions"),
            modelsURL: endpoint(host: "api.openai.com", path: "/v1/models"),
            transport: transport,
            temporaryDirectory: temporaryDirectory,
            uploadTimeout: 300)
    }

    private static func endpoint(host: String, path: String) -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.path = path
        #if RAMBLE_FLOW_TEST_HOOKS
        // Test-hook builds only (never the installed app): send requests to a loopback mock server.
        if let override = ProcessInfo.processInfo.environment["RAMBLE_FLOW_TEST_PROVIDER_PORT"], let port = Int(override) {
            components.scheme = "http"
            components.host = "127.0.0.1"
            components.port = port
            components.path = "/\(host)" + path
        }
        #endif
        return components.url!
    }

    public func transcribe(audio: URL, language: String?, apiKey: String) async throws -> ProviderTranscript {
        var body = MultipartBody()
        body.addField("model", model)
        switch id {
        case .groq:
            body.addField("response_format", "json")
            body.addField("temperature", "0")
            if let language, !language.isEmpty { body.addField("language", language) }
        case .openai:
            // gpt-transcribe takes `languages[]` (a list) instead of the older singular `language`.
            if let language, !language.isEmpty { body.addField("languages[]", language) }
        }
        // A neutral file name: the recording's title never leaves the Mac.
        body.addFile("file", fileName: "audio.m4a", contentType: "audio/mp4", url: audio)

        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let bodyFile = temporaryDirectory.appendingPathComponent("upload-\(UUID().uuidString).multipart")
        defer { try? FileManager.default.removeItem(at: bodyFile) }
        try body.write(to: bodyFile)

        var request = URLRequest(url: transcriptionURL)
        request.httpMethod = "POST"
        request.timeoutInterval = uploadTimeout
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue(body.contentType, forHTTPHeaderField: "Content-Type")

        let response: HTTPResponse
        do {
            response = try await transport.send(request, bodyFile: bodyFile)
        } catch {
            throw Self.classify(transportError: error)
        }
        guard (200..<300).contains(response.status) else {
            throw Self.classify(response: response)
        }
        guard let object = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any],
              let text = object["text"] as? String else {
            throw ProviderError.malformedResponse
        }
        return ProviderTranscript(text: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public func checkKey(_ apiKey: String) async -> KeyCheck {
        var request = URLRequest(url: modelsURL)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        do {
            let response = try await transport.send(request, bodyFile: nil)
            switch response.status {
            case 200..<300: return .accepted
            case 401, 403: return .rejected(Self.safeErrorCode(response.body) ?? "HTTP \(response.status)")
            default: return .inconclusive("HTTP \(response.status)")
            }
        } catch {
            if case ProviderError.offline = Self.classify(transportError: error) { return .unreachable }
            return .unreachable
        }
    }

    // MARK: Classification

    static func classify(transportError error: Error) -> ProviderError {
        if error is CancellationError { return .canceled }
        guard let urlError = error as? URLError else { return .uncertain("transport") }
        switch urlError.code {
        case .cancelled: return .canceled
        case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
             .internationalRoamingOff, .dataNotAllowed, .secureConnectionFailed:
            return .offline
        case .timedOut, .networkConnectionLost, .badServerResponse:
            return .uncertain(urlError.code == .timedOut ? "timeout" : "connection-lost")
        default:
            return .uncertain("url-error-\(urlError.code.rawValue)")
        }
    }

    /// Only the provider's machine-readable code/type is kept; free-text messages can echo key
    /// fragments and are not stored or shown.
    static func safeErrorCode(_ body: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        let error = object["error"] as? [String: Any] ?? object
        let code = (error["code"] as? String) ?? (error["type"] as? String)
        return code.map { Redactor.redact($0) }
    }

    static func retryAfter(_ response: HTTPResponse) -> TimeInterval? {
        if let value = response.header("Retry-After") {
            if let seconds = TimeInterval(value.trimmingCharacters(in: .whitespaces)) { return max(0, seconds) }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if let date = formatter.date(from: value) { return max(0, date.timeIntervalSinceNow) }
        }
        // Groq/OpenAI style reset hints, e.g. "1m30.5s", "12ms", "2s".
        for name in ["x-ratelimit-reset-requests", "x-ratelimit-reset-audio-seconds", "x-ratelimit-reset-tokens"] {
            if let value = response.header(name), let seconds = parseDuration(value) { return seconds }
        }
        return nil
    }

    static func parseDuration(_ value: String) -> TimeInterval? {
        let pattern = try! NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)(ms|h|m|s)"#)
        let matches = pattern.matches(in: value, range: NSRange(value.startIndex..., in: value))
        guard !matches.isEmpty else { return TimeInterval(value) }
        var total: TimeInterval = 0
        for match in matches {
            guard let numberRange = Range(match.range(at: 1), in: value), let unitRange = Range(match.range(at: 2), in: value),
                  let number = Double(value[numberRange]) else { continue }
            switch value[unitRange] {
            case "ms": total += number / 1000
            case "h": total += number * 3600
            case "m": total += number * 60
            default: total += number
            }
        }
        return total
    }

    static func classify(response: HTTPResponse) -> ProviderError {
        let code = safeErrorCode(response.body) ?? ""
        switch response.status {
        case 401: return .unauthorized(code)
        case 403: return .forbidden(code)
        case 413: return .payloadTooLarge
        case 429:
            if ["insufficient_quota", "billing_hard_limit_reached", "billing_not_active"].contains(code) {
                return .quotaExhausted(code)
            }
            return .rateLimited(retryAfter: retryAfter(response))
        case 402: return .quotaExhausted(code)
        case 400, 404, 415, 422:
            if code.contains("too_large") || code == "request_too_large" { return .payloadTooLarge }
            if code.contains("audio") || code.contains("file") || code == "invalid_file_format" { return .invalidAudio(code) }
            return .configuration(code.isEmpty ? "HTTP \(response.status)" : code)
        case 408: return .uncertain("timeout")
        case 500...599: return .server(response.status)
        default: return .configuration("HTTP \(response.status)")
        }
    }
}
