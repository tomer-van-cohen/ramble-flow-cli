// Development only: a loopback stand-in for the Groq/OpenAI transcription endpoints, used by
// scripts/e2e.sh together with a test-hooks build. It listens on 127.0.0.1, never forwards
// anything, and logs each request's path, size and form fields (never the Authorization header)
// as JSON lines.
//
// Environment:
//   MOCK_PORT           port (default 8765)
//   MOCK_LOG            JSON-lines log path (default mock-provider.log)
//   MOCK_STALL_CALL     1-based transcription call number to hold before answering
//   MOCK_STALL_SECONDS  how long to hold it (default 30)
//   MOCK_FAIL           "N:STATUS,…" answers transcription call N with that HTTP status
//   MOCK_REJECT_SUBSTRING  keys containing this text get 401 from the models endpoint
import Darwin
import Foundation

let env = ProcessInfo.processInfo.environment
let port = UInt16(env["MOCK_PORT"] ?? "8765") ?? 8765
let logPath = env["MOCK_LOG"] ?? "mock-provider.log"
let stallCall = Int(env["MOCK_STALL_CALL"] ?? "0") ?? 0
let stallSeconds = Double(env["MOCK_STALL_SECONDS"] ?? "30") ?? 30
let rejectSubstring = env["MOCK_REJECT_SUBSTRING"] ?? "rejected"
var failures: [Int: Int] = [:]
for item in (env["MOCK_FAIL"] ?? "").split(separator: ",") {
    let parts = item.split(separator: ":")
    if parts.count == 2, let n = Int(parts[0]), let status = Int(parts[1]) { failures[n] = status }
}

let samples = [
    "This is a synthetic transcript produced by the local mock provider.",
    "זהו תמלול סינתטי לבדיקה, with some English mixed in.",
]

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int
    init(_ start: Int) { value = start }
    func next() -> Int { lock.lock(); defer { lock.unlock() }; value += 1; return value }
}
let existing = (try? String(contentsOfFile: logPath, encoding: .utf8))?.split(separator: "\n").count ?? 0
let counter = Counter(existing)
let logLock = NSLock()

func appendLog(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
    logLock.lock()
    defer { logLock.unlock() }
    if !FileManager.default.fileExists(atPath: logPath) { FileManager.default.createFile(atPath: logPath, contents: nil) }
    if let handle = FileHandle(forWritingAtPath: logPath) {
        handle.seekToEndOfFile()
        handle.write(data + Data("\n".utf8))
        try? handle.close()
    }
}

func formFields(_ body: Data, contentType: String) -> [String: Any] {
    guard let range = contentType.range(of: "boundary=") else { return [:] }
    let boundary = Data(("--" + contentType[range.upperBound...]).utf8)
    var result: [String: Any] = [:]
    var cursor = body.startIndex
    var parts: [Data] = []
    while let found = body.range(of: boundary, in: cursor..<body.endIndex) {
        if cursor != body.startIndex { parts.append(body[cursor..<found.lowerBound]) }
        cursor = found.upperBound
    }
    for part in parts {
        guard let split = part.range(of: Data("\r\n\r\n".utf8)) else { continue }
        let header = String(decoding: part[part.startIndex..<split.lowerBound], as: UTF8.self)
        var value = part[split.upperBound...]
        if value.count >= 2 { value = value.dropLast(2) }
        guard let nameRange = header.range(of: #"name="([^"]+)""#, options: .regularExpression) else { continue }
        let name = String(header[nameRange].dropFirst(6).dropLast())
        if let fileRange = header.range(of: #"filename="([^"]*)""#, options: .regularExpression) {
            result[name] = ["filename": String(header[fileRange].dropFirst(10).dropLast()), "bytes": value.count]
        } else {
            result[name] = String(decoding: value, as: UTF8.self)
        }
    }
    return result
}

func respond(_ fd: Int32, status: Int, json: Any) {
    let body = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
    let reason = [200: "OK", 401: "Unauthorized", 413: "Payload Too Large", 429: "Too Many Requests", 500: "Internal Server Error"][status] ?? "Status"
    var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
    if status == 429 { head += "Retry-After: 2\r\n" }
    head += "\r\n"
    let data = Data(head.utf8) + body
    data.withUnsafeBytes { buffer in
        var offset = 0
        while offset < buffer.count {
            let n = Darwin.write(fd, buffer.baseAddress! + offset, buffer.count - offset)
            if n <= 0 { break }
            offset += n
        }
    }
}

func handle(_ fd: Int32) {
    defer { close(fd) }
    var buffer = Data()
    var chunk = [UInt8](repeating: 0, count: 65536)
    var headerEnd: Range<Data.Index>?
    while headerEnd == nil {
        let n = read(fd, &chunk, chunk.count)
        if n <= 0 { return }
        buffer.append(chunk, count: n)
        headerEnd = buffer.range(of: Data("\r\n\r\n".utf8))
    }
    let headerText = String(decoding: buffer[buffer.startIndex..<headerEnd!.lowerBound], as: UTF8.self)
    let lines = headerText.components(separatedBy: "\r\n")
    let requestLine = lines.first?.split(separator: " ") ?? []
    let method = requestLine.first.map(String.init) ?? ""
    let path = requestLine.count > 1 ? String(requestLine[1]) : ""
    var headers: [String: String] = [:]
    for line in lines.dropFirst() {
        if let colon = line.firstIndex(of: ":") {
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
    }
    let length = Int(headers["content-length"] ?? "0") ?? 0
    var body = buffer[headerEnd!.upperBound...]
    while body.count < length {
        let n = read(fd, &chunk, chunk.count)
        if n <= 0 { break }
        body.append(contentsOf: chunk[0..<n])
    }
    let authorization = headers["authorization"] ?? ""

    if method == "GET" {
        if authorization.contains(rejectSubstring) {
            respond(fd, status: 401, json: ["error": ["code": "invalid_api_key", "message": "rejected by mock"]])
        } else {
            respond(fd, status: 200, json: ["data": [["id": "mock-model"]]])
        }
        return
    }

    let n = counter.next()
    let fields = formFields(Data(body), contentType: headers["content-type"] ?? "")
    appendLog(["call": n, "path": path, "bytes": length, "authorized": authorization.hasPrefix("Bearer "),
               "fields": fields, "time": Date().timeIntervalSince1970])
    if n == stallCall { Thread.sleep(forTimeInterval: stallSeconds) }
    if let status = failures[n] {
        respond(fd, status: status, json: ["error": ["code": "mock_failure"]])
        return
    }
    let audio = (fields["file"] as? [String: Any])?["bytes"] as? Int ?? 0
    respond(fd, status: 200, json: ["text": "[part \(n), \(audio) bytes] " + samples[n % samples.count]])
}

signal(SIGPIPE, SIG_IGN)
let server = socket(AF_INET, SOCK_STREAM, 0)
var yes: Int32 = 1
setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
var address = sockaddr_in()
address.sin_family = sa_family_t(AF_INET)
address.sin_port = port.bigEndian
address.sin_addr.s_addr = inet_addr("127.0.0.1")
let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(server, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
guard bound == 0, listen(server, 16) == 0 else {
    FileHandle.standardError.write(Data("mock provider: cannot listen on 127.0.0.1:\(port)\n".utf8))
    exit(1)
}
FileHandle.standardError.write(Data("mock provider on 127.0.0.1:\(port)\n".utf8))
while true {
    let client = accept(server, nil, nil)
    if client < 0 { continue }
    DispatchQueue.global().async { handle(client) }
}
