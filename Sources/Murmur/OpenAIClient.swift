import Foundation

/// Small protocol so other STT providers can be added later and tests can mock the network.
protocol TranscriptionClient {
    func transcribe(_ audio: URL) async throws -> String
    func complete(system: String, user: String, model: String) async throws -> String
}

struct APIError: LocalizedError {
    /// Short human-readable message, e.g. "STT failed: 401 invalid_api_key".
    /// Surfaces directly in notifications, so keep it readable.
    let shortMessage: String
    let statusCode: Int?
    let mentionsModel: Bool

    init(_ shortMessage: String, statusCode: Int? = nil, mentionsModel: Bool = false) {
        self.shortMessage = shortMessage
        self.statusCode = statusCode
        self.mentionsModel = mentionsModel
    }

    var errorDescription: String? { shortMessage }
}

extension Error {
    var shortMessage: String {
        if let api = self as? APIError { return api.shortMessage }
        if let url = self as? URLError { return "Network error: \(url.localizedDescription)" }
        return localizedDescription
    }
}

final class OpenAIClient: TranscriptionClient {
    private let settings: Settings
    private let session: URLSession

    init(settings: Settings) {
        self.settings = settings
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 120
        self.session = URLSession(configuration: config)
    }

    // MARK: - Transcription

    func transcribe(_ audio: URL) async throws -> String {
        let model = settings.sttModel
        do {
            return try await transcribeOnce(audio, model: model)
        } catch let error as APIError where error.mentionsModel && model != "whisper-1" {
            NSLog("Murmur: STT model '%@' rejected (%@) — falling back to whisper-1", model, error.shortMessage)
            return try await transcribeOnce(audio, model: "whisper-1")
        }
    }

    private func transcribeOnce(_ audio: URL, model: String) async throws -> String {
        let key = try requireKey()
        let boundary = "murmur-\(UUID().uuidString)"

        var body = Data()
        func formField(_ name: String, _ value: String) {
            body.appendString("--\(boundary)\r\n")
            body.appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
            body.appendString("\(value)\r\n")
        }
        formField("model", model)
        if settings.language != "auto" {
            formField("language", settings.language)
        }
        body.appendString("--\(boundary)\r\n")
        body.appendString("Content-Disposition: form-data; name=\"file\"; filename=\"\(audio.lastPathComponent)\"\r\n")
        body.appendString("Content-Type: audio/wav\r\n\r\n")
        body.append(try Data(contentsOf: audio))
        body.appendString("\r\n--\(boundary)--\r\n")

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/audio/transcriptions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let data = try await send(request, label: "STT")
        struct Response: Decodable { let text: String }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data) else {
            throw APIError("STT failed: unreadable response")
        }
        return decoded.text
    }

    // MARK: - Chat completion

    func complete(system: String, user: String, model: String) async throws -> String {
        let key = try requireKey()
        let payload: [String: Any] = [
            "model": model,
            "temperature": 0,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]

        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let data = try await send(request, label: "Formatting")
        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable { let content: String }
                let message: Message
            }
            let choices: [Choice]
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
              let content = decoded.choices.first?.message.content
        else {
            throw APIError("Formatting failed: unreadable response")
        }
        return content
    }

    // MARK: - Plumbing

    private func requireKey() throws -> String {
        guard let key = settings.apiKey else {
            throw APIError("No API key set — use \"Set API key…\" in the menu")
        }
        return key
    }

    /// One automatic retry on connection-level errors; HTTP errors become readable APIErrors.
    private func send(_ request: URLRequest, label: String) async throws -> Data {
        var lastConnectionError: URLError?
        for attempt in 0..<2 {
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw APIError("\(label) failed: no HTTP response")
                }
                guard (200..<300).contains(http.statusCode) else {
                    throw Self.httpError(label: label, status: http.statusCode, body: data)
                }
                return data
            } catch let error as URLError {
                lastConnectionError = error
                if attempt == 0 { continue }
            }
        }
        throw APIError("\(label) failed: \(lastConnectionError?.localizedDescription ?? "connection error")")
    }

    static func httpError(label: String, status: Int, body: Data) -> APIError {
        struct ErrorEnvelope: Decodable {
            struct Inner: Decodable {
                let message: String?
                let code: String?
                let type: String?
            }
            let error: Inner
        }
        var detail = ""
        var mentionsModel = false
        if let envelope = try? JSONDecoder().decode(ErrorEnvelope.self, from: body) {
            detail = envelope.error.code ?? envelope.error.message ?? envelope.error.type ?? ""
            let haystack = "\(envelope.error.code ?? "") \(envelope.error.message ?? "") \(envelope.error.type ?? "")"
            mentionsModel = (400..<500).contains(status) && haystack.lowercased().contains("model")
        }
        let suffix = detail.isEmpty ? "" : " \(String(detail.prefix(120)))"
        return APIError("\(label) failed: \(status)\(suffix)", statusCode: status, mentionsModel: mentionsModel)
    }
}

extension Data {
    mutating func appendString(_ string: String) {
        append(Data(string.utf8))
    }
}
