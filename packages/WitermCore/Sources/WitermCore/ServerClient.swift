import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct ServerInfo: Codable, Sendable, Equatable {
    public let service: String
    public let protocolVersion: Int
    public let capabilities: [String]

    enum CodingKeys: String, CodingKey {
        case service, capabilities
        case protocolVersion = "protocol_version"
    }
}

public enum ServerClientError: Error, Sendable {
    case invalidAddress
    case unavailable
    case incompatibleServer
}

public actor ServerClient {
    /// The info document is a few hundred bytes and readiness needs no body.
    /// A misbehaving server cannot make a diagnostic buffer more than this.
    static let infoLimit = 16_384
    static let readinessLimit = 4_096
    private let session: URLSession

    public init() { self.init(configuration: .ephemeral) }

    init(configuration: URLSessionConfiguration, resourceTimeout: TimeInterval = 15) {
        configuration.timeoutIntervalForRequest = 10
        // Bounds each whole response, including one that trickles in slowly.
        configuration.timeoutIntervalForResource = resourceTimeout
        session = URLSession(configuration: configuration)
    }

    public nonisolated static func validatedURL(for address: String) throws -> URL {
        guard let base = URL(string: address),
              let scheme = base.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = base.host, !host.isEmpty,
              base.user == nil, base.password == nil,
              base.query == nil, base.fragment == nil,
              base.path.isEmpty || base.path == "/" else {
            throw ServerClientError.invalidAddress
        }
        return base
    }

    public func checkConnection(address: String) async throws -> ServerInfo {
        let base = try Self.validatedURL(for: address)
        let (data, status) = try await fetch(base.appendingPathComponent("v1/info"), limit: Self.infoLimit)
        guard status == 200 else { throw ServerClientError.unavailable }
        let info = try JSONDecoder().decode(ServerInfo.self, from: data)
        guard info.service == "witerm", info.protocolVersion == 1 else {
            throw ServerClientError.incompatibleServer
        }
        let (_, readiness) = try await fetch(base.appendingPathComponent("readyz"), limit: Self.readinessLimit)
        guard readiness == 200 else { throw ServerClientError.unavailable }
        return info
    }

    private func fetch(_ url: URL, limit: Int) async throws -> (Data, Int) {
        let (bytes, response) = try await session.bytes(from: url)
        guard let response = response as? HTTPURLResponse else { throw ServerClientError.unavailable }
        guard response.expectedContentLength <= limit else { throw ServerClientError.incompatibleServer }
        var data = Data()
        for try await byte in bytes {
            guard data.count < limit else { throw ServerClientError.incompatibleServer }
            data.append(byte)
        }
        return (data, response.statusCode)
    }
}

