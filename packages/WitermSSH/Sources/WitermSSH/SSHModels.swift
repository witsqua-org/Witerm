import Foundation

public struct SSHHost: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var hostname: String
    public var port: Int
    public var username: String
    public init(id: UUID = UUID(), hostname: String, port: Int = 22, username: String) {
        self.id = id; self.hostname = hostname; self.port = port; self.username = username
    }
    public var authority: String { "[\(hostname.lowercased())]:\(port)" }
    public func validate() throws {
        guard !hostname.isEmpty, hostname.utf8.count <= 253,
              !hostname.contains(where: { $0.isWhitespace || $0.isNewline }),
              !hostname.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              (1...65535).contains(port), !username.isEmpty, username.utf8.count <= 255,
              !username.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw SSHFailure.invalidConfiguration }
    }
}

public struct SSHProfile: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var host: SSHHost
    public var jumpHosts: [SSHHost]
    public init(id: UUID = UUID(), name: String, host: SSHHost, jumpHosts: [SSHHost] = []) {
        self.id = id; self.name = name; self.host = host; self.jumpHosts = jumpHosts
    }
    public func validate() throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              name.count <= 80, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), jumpHosts.count <= 4,
              Set((jumpHosts + [host]).map(\.id)).count == jumpHosts.count + 1
        else { throw SSHFailure.invalidConfiguration }
        for endpoint in jumpHosts + [host] { try endpoint.validate() }
    }
}

public enum SSHCredential: Sendable {
    case password(String)
    case privateKey(String, passphrase: String?)
}

public struct SSHHostKey: Codable, Hashable, Sendable {
    public let authority: String
    public let algorithm: String
    public let publicKey: String
    public let fingerprint: String
    public init(authority: String, algorithm: String, publicKey: String, fingerprint: String) {
        self.authority = authority; self.algorithm = algorithm
        self.publicKey = publicKey; self.fingerprint = fingerprint
    }
}

public enum SSHHostKeyStatus: Equatable, Sendable {
    case trusted
    case unknown
    case changed(previousFingerprint: String)
}

public enum SSHFailure: Error, Equatable, Sendable {
    case invalidConfiguration, missingCredential, unsupportedPrivateKey
    case hostKeyRejected, hostKeyChanged, disconnected, backpressure, transferTooLarge
    case invalidPath, invalidForward, storageUnavailable, cancelled
}

public struct SSHFileEntry: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let name: String
    public let path: String
    public let isDirectory: Bool
    public let size: UInt64?
    public init(name: String, path: String, isDirectory: Bool, size: UInt64?) {
        self.name = name; self.path = path; self.isDirectory = isDirectory; self.size = size
    }
}

public struct SSHForward: Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case local, remote }
    public let id: UUID
    public let kind: Kind
    public let listenPort: Int
    public let targetHost: String
    public let targetPort: Int
    public init(id: UUID = UUID(), kind: Kind, listenPort: Int, targetHost: String, targetPort: Int) {
        self.id = id; self.kind = kind; self.listenPort = listenPort
        self.targetHost = targetHost; self.targetPort = targetPort
    }
}
