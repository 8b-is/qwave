import Foundation

public enum MemoryProviderError: Error, Equatable {
    case unavailable
    case emptyPrompt
    case transport(String)
    case insecureEndpoint
    case denied(MemoryWaveDenial)
}

public protocol MemoryProviding: Sendable {
    var kind: MemoryProviderKind { get }
    var isAvailable: Bool { get }
    func complete(system: String, user: String) async throws -> String
}

public struct NullMemoryProvider: MemoryProviding {
    public init() {}
    public var kind: MemoryProviderKind { .none }
    public var isAvailable: Bool { false }
    public func complete(system: String, user: String) async throws -> String {
        throw MemoryProviderError.unavailable
    }
}

/// OpenAI-compatible chat/completions. Default remote is xAI (`api.x.ai`)
/// but any HTTPS endpoint that speaks the same schema works — Ollama,
/// LM Studio, vLLM, a self-hosted proxy.
public struct OpenAICompatibleProvider: MemoryProviding, Sendable {
    public var baseURL: URL
    public var model: String
    public var apiKey: String
    public var session: URLSession

    public init(baseURL: URL, model: String, apiKey: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.model = model
        self.apiKey = apiKey
        self.session = session
    }

    public var kind: MemoryProviderKind { .openaiCompatible }
    public var isAvailable: Bool { !apiKey.isEmpty && baseURL.scheme?.lowercased() == "https" }

    public func complete(system: String, user: String) async throws -> String {
        guard !user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MemoryProviderError.emptyPrompt
        }
        guard baseURL.scheme?.lowercased() == "https" else {
            throw MemoryProviderError.insecureEndpoint
        }
        let endpoint = baseURL.appendingPathComponent("chat/completions")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let body: [String: Any] = [
            "model": model,
            "stream": false,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user],
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status) else {
            throw MemoryProviderError.transport("HTTP \(status)")
        }
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let choices = json["choices"] as? [[String: Any]],
            let message = choices.first?["message"] as? [String: Any],
            let content = message["content"] as? String
        else {
            throw MemoryProviderError.transport("malformed completion")
        }
        return content
    }
}

/// On-device Apple Intelligence when the SDK and hardware expose it.
/// The browser stays fully functional when this provider reports unavailable.
public struct OnDeviceMemoryProvider: MemoryProviding {
    public init() {}
    public var kind: MemoryProviderKind { .onDevice }

    public var isAvailable: Bool {
        #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                return true
            }
        #endif
        return false
    }

    public func complete(system: String, user: String) async throws -> String {
        #if canImport(FoundationModels)
            if #available(macOS 26.0, *) {
                return try await FoundationModelsBridge.complete(system: system, user: user)
            }
        #endif
        throw MemoryProviderError.unavailable
    }
}

#if canImport(FoundationModels)
    import FoundationModels

    @available(macOS 26.0, *)
    enum FoundationModelsBridge {
        static func complete(system: String, user: String) async throws -> String {
            let session = LanguageModelSession()
            let response = try await session.respond(to: "\(system)\n\n\(user)")
            return String(describing: response.content)
        }
    }
#endif
