import Foundation

enum OpenAIError: Error, Equatable {
    /// An HTTP error with the API's own message.
    case http(status: Int, message: String)
    case network
    case invalidResponse
}

/// The OpenAI Responses API (`POST /v1/responses`), stateless: Orbit sends
/// the whole context it chose each time (`store: false`), so nothing is kept
/// on OpenAI's side between requests beyond what its policies say.
struct OpenAIResponses: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    static let endpoint = URL(string: "https://api.openai.com/v1/responses")!
    let endpoint: URL
    let transport: Transport

    init(endpoint: URL = OpenAIResponses.endpoint, transport: @escaping Transport = OpenAIResponses.urlSession) {
        self.endpoint = endpoint
        self.transport = transport
    }

    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 600
        configuration.timeoutIntervalForResource = 900
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration)
    }()

    static let urlSession: Transport = { request in try await session.data(for: request) }

    /// One response for `body`. Cancelling the calling task cancels the request.
    func create(_ body: JSONValue, key: String) async throws -> JSONValue {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try Self.encode(body)
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await transport(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw OpenAIError.network
        }
        guard let http = response as? HTTPURLResponse else { throw OpenAIError.invalidResponse }
        let json = try? JSONDecoder().decode(JSONValue.self, from: data)
        guard (200..<300).contains(http.statusCode) else {
            let message = json?["error"]?["message"]?.string ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw OpenAIError.http(status: http.statusCode, message: String(message.prefix(500)))
        }
        guard let json, json["output"]?.array != nil else { throw OpenAIError.invalidResponse }
        return json
    }

    /// Keys sorted: Swift dictionaries have no stable order, and the same
    /// instructions and tools must be the same bytes on every request for
    /// the API's prompt cache to match them.
    static func encode(_ body: JSONValue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(body)
    }

    /// What a response asked for: its text, tool calls, and the items to
    /// keep in context as they came (reasoning with its encrypted content).
    struct Reply: Equatable {
        struct Call: Equatable {
            let callID: String
            let name: String
            let arguments: String
        }
        /// The output in its order: reasoning must stay just before the
        /// call or message it led to when it's sent back.
        enum Part: Equatable {
            case text(String)
            case call(Call)
            case reasoning(JSONValue)
        }
        var parts: [Part] = []
        var calls: [Call] { parts.compactMap { if case .call(let call) = $0 { call } else { nil } } }
        var inputTokens = 0
        var cachedTokens = 0
        var outputTokens = 0
    }

    static func parse(_ response: JSONValue) -> Reply {
        var reply = Reply()
        for item in response["output"]?.array ?? [] {
            switch item["type"]?.string {
            case "message":
                let texts = (item["content"]?.array ?? []).filter { $0["type"]?.string == "output_text" }.compactMap { $0["text"]?.string }
                let text = texts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
                if !text.isEmpty { reply.parts.append(.text(text)) }
            case "function_call":
                if let id = item["call_id"]?.string, let name = item["name"]?.string {
                    reply.parts.append(.call(Reply.Call(callID: id, name: name, arguments: item["arguments"]?.string ?? "{}")))
                }
            case "reasoning":
                reply.parts.append(.reasoning(item))
            default:
                break
            }
        }
        let usage = response["usage"]
        reply.inputTokens = usage?["input_tokens"]?.int ?? 0
        reply.cachedTokens = usage?["input_tokens_details"]?["cached_tokens"]?.int ?? 0
        reply.outputTokens = usage?["output_tokens"]?.int ?? 0
        return reply
    }
}
