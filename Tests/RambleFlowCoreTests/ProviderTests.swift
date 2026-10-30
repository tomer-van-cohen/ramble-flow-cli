import Foundation
import Testing
@testable import RambleFlowCore

@Suite("Provider contracts (mock HTTP only)")
struct ProviderTests {
    let key = "gsk_SECRETSECRETSECRET1234"

    func audioFile(_ temp: TempDir) -> URL {
        let url = temp.url.appendingPathComponent("chunk.m4a")
        FileManager.default.createFile(atPath: url.path, contents: Data(repeating: 0xAB, count: 4096))
        return url
    }

    func fields(_ body: Data) -> [String: String] {
        let text = String(decoding: body, as: UTF8.self)
        var result: [String: String] = [:]
        let pattern = try! NSRegularExpression(pattern: #"name="([^"]+)"(?:; filename="([^"]+)")?\r\n(?:Content-Type: [^\r]+\r\n)?\r\n"#)
        for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            let name = String(text[Range(match.range(at: 1), in: text)!])
            if let fileRange = Range(match.range(at: 2), in: text) {
                result[name] = "file:" + text[fileRange]
            } else {
                let after = text[Range(match.range, in: text)!.upperBound...]
                result[name] = String(after).components(separatedBy: "\r\n").first ?? ""
            }
        }
        return result
    }

    @Test func groqRequestContract() async throws {
        let temp = TempDir("groq")
        let transport = MockTransport([MockTransport.json(200, #"{"text":"  שלום world  "}"#)])
        let provider = OpenAICompatibleProvider.groq(transport: transport, temporaryDirectory: temp.sub("tmp"))
        let result = try await provider.transcribe(audio: audioFile(temp), language: nil, apiKey: key)
        #expect(result.text == "שלום world")
        let sent = try #require(transport.captured.first)
        #expect(sent.request.url?.absoluteString == "https://api.groq.com/openai/v1/audio/transcriptions")
        #expect(sent.request.httpMethod == "POST")
        #expect(sent.request.value(forHTTPHeaderField: "Authorization") == "Bearer \(key)")
        #expect(sent.request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
        let f = fields(sent.body)
        #expect(f["model"] == "whisper-large-v3")
        #expect(f["response_format"] == "json")
        #expect(f["temperature"] == "0")
        #expect(f["language"] == nil, "automatic language detection by default")
        #expect(f["file"] == "file:audio.m4a", "titles never leave the Mac")
        #expect(sent.body.count > 4096)
        #expect((try? FileManager.default.contentsOfDirectory(atPath: temp.url.appendingPathComponent("tmp").path))?.isEmpty == true, "multipart temp file removed")
    }

    @Test func openAIRequestContract() async throws {
        let temp = TempDir("openai")
        let transport = MockTransport([MockTransport.json(200, #"{"text":"Hello","languages":[{"code":"en"}]}"#)])
        let provider = OpenAICompatibleProvider.openAI(transport: transport, temporaryDirectory: temp.sub("tmp"))
        let result = try await provider.transcribe(audio: audioFile(temp), language: "he", apiKey: "sk-proj-abcdefghijklmnop")
        #expect(result.text == "Hello")
        let sent = try #require(transport.captured.first)
        #expect(sent.request.url?.absoluteString == "https://api.openai.com/v1/audio/transcriptions")
        let f = fields(sent.body)
        #expect(f["model"] == "gpt-transcribe")
        #expect(f["languages[]"] == "he")
        #expect(f["language"] == nil, "gpt-transcribe takes languages[], never both")
    }

    @Test func emptyTextIsAValidNoSpeechResult() async throws {
        let temp = TempDir("empty")
        let provider = OpenAICompatibleProvider.groq(transport: MockTransport([MockTransport.json(200, #"{"text":""}"#)]), temporaryDirectory: temp.url)
        #expect(try await provider.transcribe(audio: audioFile(temp), language: nil, apiKey: key).text == "")
    }

    func failure(_ response: Result<HTTPResponse, Error>) async -> ProviderError? {
        let temp = TempDir("err")
        let provider = OpenAICompatibleProvider.groq(transport: MockTransport([response]), temporaryDirectory: temp.url)
        do {
            _ = try await provider.transcribe(audio: audioFile(temp), language: nil, apiKey: key)
            return nil
        } catch let error as ProviderError {
            return error
        } catch {
            return nil
        }
    }

    @Test func httpFailuresAreClassified() async {
        #expect(await failure(MockTransport.json(401, #"{"error":{"message":"Invalid API Key gsk_SECRETSECRETSECRET1234","type":"invalid_request_error","code":"invalid_api_key"}}"#)) == .unauthorized("invalid_api_key"))
        #expect(await failure(MockTransport.json(403, #"{"error":{"code":"permission_denied"}}"#)) == .forbidden("permission_denied"))
        #expect(await failure(MockTransport.json(413, #"{"error":{"code":"request_too_large"}}"#)) == .payloadTooLarge)
        #expect(await failure(MockTransport.json(400, #"{"error":{"code":"request_too_large"}}"#)) == .payloadTooLarge)
        #expect(await failure(MockTransport.json(429, #"{"error":{"code":"rate_limit_exceeded"}}"#, headers: ["Retry-After": "17"])) == .rateLimited(retryAfter: 17))
        #expect(await failure(MockTransport.json(429, #"{}"#, headers: ["x-ratelimit-reset-audio-seconds": "1m30.5s"])) == .rateLimited(retryAfter: 90.5))
        #expect(await failure(MockTransport.json(429, #"{}"#)) == .rateLimited(retryAfter: nil))
        #expect(await failure(MockTransport.json(429, #"{"error":{"type":"insufficient_quota","code":"insufficient_quota"}}"#)) == .quotaExhausted("insufficient_quota"))
        #expect(await failure(MockTransport.json(404, #"{"error":{"code":"model_not_found"}}"#)) == .configuration("model_not_found"))
        #expect(await failure(MockTransport.json(400, #"{"error":{"code":"invalid_file_format"}}"#)) == .invalidAudio("invalid_file_format"))
        #expect(await failure(MockTransport.json(500, "oops")) == .server(500))
        #expect(await failure(MockTransport.json(503, "")) == .server(503))
        #expect(await failure(MockTransport.json(200, "<html>not json</html>")) == .malformedResponse)
        #expect(await failure(MockTransport.json(200, #"{"segments":[]}"#)) == .malformedResponse)
    }

    @Test func retryAfterAcceptsHTTPDates() {
        let future = Date().addingTimeInterval(120)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        let seconds = OpenAICompatibleProvider.retryAfter(HTTPResponse(status: 429, headers: ["retry-after": formatter.string(from: future)]))
        #expect(seconds != nil && abs(seconds! - 120) < 5)
        #expect(OpenAICompatibleProvider.parseDuration("12ms") == 0.012)
        #expect(OpenAICompatibleProvider.parseDuration("2h") == 7200)
    }

    @Test func transportFailuresSeparateOfflineFromUncertain() async {
        #expect(await failure(.failure(URLError(.notConnectedToInternet))) == .offline)
        #expect(await failure(.failure(URLError(.cannotFindHost))) == .offline)
        #expect(await failure(.failure(URLError(.timedOut))) == .uncertain("timeout"))
        #expect(await failure(.failure(URLError(.networkConnectionLost))) == .uncertain("connection-lost"))
        #expect(await failure(.failure(URLError(.cancelled))) == .canceled)
        #expect(await failure(.failure(CancellationError())) == .canceled)
    }

    @Test func keysNeverLeakThroughErrorsOrRedaction() async {
        let error = await failure(MockTransport.json(401, #"{"error":{"message":"Incorrect API key provided: gsk_SECRETSECRETSECRET1234","code":"gsk_SECRETSECRETSECRET1234"}}"#))
        #expect(!String(describing: error).contains("SECRETSECRET"))
        #expect(!Redactor.redact("Authorization: Bearer abc.def-ghi").contains("abc.def"))
        #expect(!Redactor.redact("key sk-proj-ABCDEFGHIJKLMNOP done").contains("ABCDEFGHIJ"))
        #expect(Redactor.mask("gsk_abcdefghijklmnop1234") == "gsk_••••••••1234")
        #expect(Redactor.mask("short") == "•••••")
    }

    @Test func keyCheckProvesCredentialOnly() async {
        let temp = TempDir("check")
        let ok = OpenAICompatibleProvider.groq(transport: MockTransport([MockTransport.json(200, #"{"data":[]}"#)]), temporaryDirectory: temp.url)
        #expect(await ok.checkKey(key) == .accepted)
        let bad = OpenAICompatibleProvider.openAI(transport: MockTransport([MockTransport.json(401, #"{"error":{"code":"invalid_api_key"}}"#)]), temporaryDirectory: temp.url)
        #expect(await bad.checkKey("sk-wrong-key-0000") == .rejected("invalid_api_key"))
        let offline = OpenAICompatibleProvider.groq(transport: MockTransport([.failure(URLError(.notConnectedToInternet))]), temporaryDirectory: temp.url)
        #expect(await offline.checkKey(key) == .unreachable)
        let transport = MockTransport([MockTransport.json(200, "{}")])
        _ = await OpenAICompatibleProvider.groq(transport: transport, temporaryDirectory: temp.url).checkKey(key)
        #expect(transport.captured.first?.request.url?.absoluteString == "https://api.groq.com/openai/v1/models")
        #expect(transport.captured.first?.request.httpMethod == "GET")
    }

    @Test func providerHostsAreFixedHTTPS() {
        let temp = TempDir("hosts")
        for provider in [OpenAICompatibleProvider.groq(transport: MockTransport([]), temporaryDirectory: temp.url),
                         OpenAICompatibleProvider.openAI(transport: MockTransport([]), temporaryDirectory: temp.url)] {
            #expect(provider.transcriptionURL.scheme == "https")
            #expect(provider.capabilities.targetUploadBytes < provider.capabilities.maxUploadBytes)
            #expect(provider.capabilities.maxUploadBytes <= 25_000_000)
        }
    }

    @Test func multipartStreamsLargeFilesFromDisk() throws {
        let temp = TempDir("multipart")
        let audio = temp.url.appendingPathComponent("big.m4a")
        let handle = try { () -> FileHandle in
            FileManager.default.createFile(atPath: audio.path, contents: nil)
            return try FileHandle(forWritingTo: audio)
        }()
        for _ in 0..<12 { handle.write(Data(repeating: 1, count: 1 << 20)) }
        try handle.close()
        var body = MultipartBody(boundary: "B")
        body.addField("model", "m")
        body.addFile("file", fileName: "audio.m4a", contentType: "audio/mp4", url: audio)
        let out = temp.url.appendingPathComponent("body")
        let size = try body.write(to: out)
        #expect(size > 12 << 20)
        let tail = try FileHandle(forReadingFrom: out)
        try tail.seek(toOffset: UInt64(size - 7))
        #expect(String(decoding: try tail.readToEnd() ?? Data(), as: UTF8.self) == "--B--\r\n")
    }
}
