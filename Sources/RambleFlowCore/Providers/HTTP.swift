import Foundation

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data

    public init(status: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.status = status
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? {
        let lower = name.lowercased()
        return headers.first { $0.key.lowercased() == lower }?.value
    }
}

/// The only network door. Tests replace it with a scripted mock; production uses URLSession.
public protocol HTTPTransport: Sendable {
    /// `bodyFile` is streamed from disk (uploads never load a whole recording into memory).
    func send(_ request: URLRequest, bodyFile: URL?) async throws -> HTTPResponse
}

public struct URLSessionTransport: HTTPTransport {
    private let session: URLSession

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.waitsForConnectivity = false
            configuration.timeoutIntervalForRequest = 120
            configuration.timeoutIntervalForResource = 15 * 60
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            self.session = URLSession(configuration: configuration)
        }
    }

    public func send(_ request: URLRequest, bodyFile: URL?) async throws -> HTTPResponse {
        let (data, response): (Data, URLResponse)
        if let bodyFile {
            (data, response) = try await session.upload(for: request, fromFile: bodyFile)
        } else {
            (data, response) = try await session.data(for: request)
        }
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        return HTTPResponse(status: http.statusCode, headers: headers, body: data)
    }
}

/// Builds a multipart/form-data body in a temporary file, copying the audio in 1 MB pieces.
public struct MultipartBody {
    public let boundary: String
    private var parts: [Part] = []

    private enum Part {
        case field(name: String, value: String)
        case file(name: String, fileName: String, contentType: String, url: URL)
    }

    public init(boundary: String = "RambleFlow-\(UUID().uuidString)") {
        self.boundary = boundary
    }

    public var contentType: String { "multipart/form-data; boundary=\(boundary)" }

    public mutating func addField(_ name: String, _ value: String) {
        parts.append(.field(name: name, value: value))
    }

    public mutating func addFile(_ name: String, fileName: String, contentType: String, url: URL) {
        parts.append(.file(name: name, fileName: fileName, contentType: contentType, url: url))
    }

    /// Writes the body to `destination` and returns its size in bytes.
    @discardableResult
    public func write(to destination: URL) throws -> Int64 {
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let out = try FileHandle(forWritingTo: destination)
        defer { try? out.close() }
        func put(_ string: String) { out.write(Data(string.utf8)) }
        for part in parts {
            put("--\(boundary)\r\n")
            switch part {
            case .field(let name, let value):
                put("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n")
            case .file(let name, let fileName, let contentType, let url):
                put("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(fileName)\"\r\n")
                put("Content-Type: \(contentType)\r\n\r\n")
                let input = try FileHandle(forReadingFrom: url)
                defer { try? input.close() }
                while let data = try input.read(upToCount: 1 << 20), !data.isEmpty {
                    out.write(data)
                }
                put("\r\n")
            }
        }
        put("--\(boundary)--\r\n")
        return Int64(try out.offset())
    }
}
