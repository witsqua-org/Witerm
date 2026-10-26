#if os(macOS)
import Darwin
import Foundation

public struct RelayHostConfiguration: Codable, Sendable, Equatable {
  public let serverAddress: String
  public let deviceName: String
  public let enabled: Bool

  public init(serverAddress: String, deviceName: String, enabled: Bool) {
    self.serverAddress = serverAddress
    self.deviceName = deviceName
    self.enabled = enabled
  }

  enum CodingKeys: String, CodingKey {
    case serverAddress = "server_address"
    case deviceName = "device_name"
    case enabled
  }
}

/// Persists only user-selected connection settings, never identity keys or
/// tokens. One entry per server, so a Mac can accept relayed connections
/// through several servers at once. The single-server `relay.json` written by
/// earlier versions is still read until the first write replaces it.
public struct RelayHostConfigurationStore: Sendable {
  public static let limit = 8
  private static let byteLimit = 32_768
  private let directory: URL
  private var file: URL { directory.appendingPathComponent("relay-hosts.json") }
  private var legacyFile: URL { directory.appendingPathComponent("relay.json") }

  public init(stateDirectory: URL) { directory = stateDirectory }

  public func readAll() throws -> [RelayHostConfiguration] {
    try validateDirectory()
    if let data = try readFile(file) {
      guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        Set(raw.keys) == ["hosts"], let hosts = raw["hosts"] as? [[String: Any]],
        hosts.count <= Self.limit,
        hosts.allSatisfy({ Set($0.keys) == ["server_address", "device_name", "enabled"] })
      else { throw LocalAgentClientError.invalidResponse }
      let decoded = try JSONDecoder().decode(Hosts.self, from: data).hosts
      return try unique(decoded.map(validated))
    }
    guard let data = try readFile(legacyFile) else { return [] }
    guard let raw = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      Set(raw.keys) == ["server_address", "device_name", "enabled"] else {
      throw LocalAgentClientError.invalidResponse
    }
    return [try validated(JSONDecoder().decode(RelayHostConfiguration.self, from: data))]
  }

  /// Replaces every entry. Rejects the whole set, leaving the previous one in
  /// place, if any entry is invalid or two entries name the same server.
  public func writeAll(_ configurations: [RelayHostConfiguration]) throws {
    try validateDirectory()
    guard configurations.count <= Self.limit else { throw LocalAgentClientError.invalidResponse }
    let hosts = try unique(configurations.map(validated))
    // An unsafe legacy file blocks writes rather than being silently replaced.
    _ = try readFile(legacyFile)
    let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
    try writeFile(file, data: try encoder.encode(Hosts(hosts: hosts)))
    if unlink(legacyFile.path) != 0 && errno != ENOENT { throw LocalAgentClientError.unavailable }
  }

  /// Adds the entry, or replaces the one for the same server.
  public func upsert(_ configuration: RelayHostConfiguration) throws {
    let next = try validated(configuration)
    var hosts = try readAll().filter { $0.serverAddress != next.serverAddress }
    hosts.append(next)
    try writeAll(hosts)
  }

  /// Removes the entry for a server, if there is one.
  public func remove(serverAddress: String) throws {
    let server = try PairingServerAddress.normalized(serverAddress).absoluteString
    let hosts = try readAll()
    guard hosts.contains(where: { $0.serverAddress == server }) else { return }
    try writeAll(hosts.filter { $0.serverAddress != server })
  }

  private struct Hosts: Codable { let hosts: [RelayHostConfiguration] }

  private func unique(_ hosts: [RelayHostConfiguration]) throws -> [RelayHostConfiguration] {
    guard Set(hosts.map(\.serverAddress)).count == hosts.count else { throw LocalAgentClientError.invalidResponse }
    return hosts
  }

  private func readFile(_ url: URL) throws -> Data? {
    let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
    if fd < 0 {
      if errno == ENOENT { return nil }
      throw LocalAgentClientError.unsafeSocket
    }
    defer { Darwin.close(fd) }
    try validateFile(fd)
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let count = Darwin.read(fd, &buffer, buffer.count)
      if count == 0 { break }
      if count < 0 {
        if errno == EINTR { continue }
        throw LocalAgentClientError.unavailable
      }
      guard data.count + count <= Self.byteLimit else { throw LocalAgentClientError.invalidResponse }
      data.append(contentsOf: buffer.prefix(count))
    }
    return data
  }

  private func writeFile(_ url: URL, data: Data) throws {
    var existing = stat()
    if lstat(url.path, &existing) == 0 {
      guard existing.st_uid == geteuid(), existing.st_mode & S_IFMT == S_IFREG,
        existing.st_mode & 0o7777 == 0o600 else { throw LocalAgentClientError.unsafeSocket }
    } else if errno != ENOENT { throw LocalAgentClientError.unavailable }
    let temporary = directory.appendingPathComponent(".relay-" + UUID().uuidString)
    let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw LocalAgentClientError.unavailable }
    defer { Darwin.close(fd); _ = unlink(temporary.path) }
    let success = data.withUnsafeBytes { raw -> Bool in
      guard let base = raw.baseAddress else { return false }
      var sent = 0
      while sent < raw.count {
        let count = Darwin.write(fd, base.advanced(by: sent), raw.count - sent)
        if count < 0 && errno == EINTR { continue }
        if count <= 0 { return false }
        sent += count
      }
      return true
    }
    guard success, fsync(fd) == 0, rename(temporary.path, url.path) == 0 else {
      throw LocalAgentClientError.unavailable
    }
  }

  private func validateDirectory() throws {
    var info = stat()
    guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
      info.st_uid == geteuid(), info.st_mode & 0o7777 == 0o700 else {
      throw LocalAgentClientError.unsafeSocket
    }
  }

  private func validateFile(_ fd: Int32) throws {
    var info = stat()
    guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_uid == geteuid(), info.st_mode & 0o7777 == 0o600,
      info.st_size <= Self.byteLimit else { throw LocalAgentClientError.unsafeSocket }
  }

  private func validated(_ config: RelayHostConfiguration) throws -> RelayHostConfiguration {
    let server = try PairingServerAddress.normalized(config.serverAddress)
    let name = config.deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, name.unicodeScalars.count <= 64,
      !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
      throw PairingClientError.invalidDeviceName
    }
    return RelayHostConfiguration(serverAddress: server.absoluteString, deviceName: name, enabled: config.enabled)
  }
}
#endif
