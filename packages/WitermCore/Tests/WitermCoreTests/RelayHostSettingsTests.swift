#if os(macOS)
import Darwin
import Foundation
import XCTest
@testable import WitermCore

final class RelayHostSettingsTests: XCTestCase {
  private func directory() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("witerm-settings-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }

  func testPrivateConfigurationRoundTripAndAtomicUpdate() throws {
    let url = try directory(); let store = RelayHostConfigurationStore(stateDirectory: url)
    XCTAssertEqual(try store.readAll(), [])
    try store.upsert(.init(serverAddress: "https://example.com", deviceName: "My Mac", enabled: true))
    let value = try XCTUnwrap(store.readAll().first)
    XCTAssertTrue(value.enabled)
    XCTAssertEqual(value.serverAddress, "https://example.com")
    try store.upsert(.init(serverAddress: value.serverAddress, deviceName: "My Mac", enabled: false))
    XCTAssertEqual(try store.readAll().map(\.enabled), [false])
    let file = url.appendingPathComponent("relay-hosts.json")
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    let raw = try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
    XCTAssertEqual(Set(raw?.keys.map { $0 } ?? []), ["hosts"])
    let host = try XCTUnwrap((raw?["hosts"] as? [[String: Any]])?.first)
    XCTAssertEqual(Set(host.keys), ["server_address", "device_name", "enabled"])
  }

  func testSeveralServersAreIndependent() throws {
    let store = RelayHostConfigurationStore(stateDirectory: try directory())
    try store.upsert(.init(serverAddress: "https://one.example.com", deviceName: "Mac", enabled: true))
    try store.upsert(.init(serverAddress: "https://two.example.com", deviceName: "Mac", enabled: true))
    try store.upsert(.init(serverAddress: "https://ONE.example.com:443/", deviceName: "Mac", enabled: false))
    let hosts = try store.readAll()
    XCTAssertEqual(hosts.map(\.serverAddress), ["https://two.example.com", "https://one.example.com"])
    XCTAssertEqual(hosts.map(\.enabled), [true, false])
    try store.remove(serverAddress: "https://two.example.com")
    XCTAssertEqual(try store.readAll().map(\.serverAddress), ["https://one.example.com"])
    try store.remove(serverAddress: "https://absent.example.com")
    XCTAssertEqual(try store.readAll().count, 1)
  }

  func testRejectsDuplicateServersAndTooManyEntries() throws {
    let store = RelayHostConfigurationStore(stateDirectory: try directory())
    let first = RelayHostConfiguration(serverAddress: "https://example.com", deviceName: "Mac", enabled: true)
    try store.writeAll([first])
    XCTAssertThrowsError(try store.writeAll([first, .init(serverAddress: "https://EXAMPLE.com:443", deviceName: "Mac", enabled: false)]))
    let many = (0...RelayHostConfigurationStore.limit).map {
      RelayHostConfiguration(serverAddress: "https://s\($0).example.com", deviceName: "Mac", enabled: true)
    }
    XCTAssertThrowsError(try store.writeAll(many))
    XCTAssertEqual(try store.readAll(), [first])
  }

  func testReadsLegacySingleServerFileUntilFirstWrite() throws {
    let url = try directory(); let store = RelayHostConfigurationStore(stateDirectory: url)
    let legacy = url.appendingPathComponent("relay.json")
    let fd = open(legacy.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    XCTAssertGreaterThanOrEqual(fd, 0)
    let bytes = Array("{\"device_name\":\"Mac\",\"enabled\":true,\"server_address\":\"https://example.com\"}".utf8)
    XCTAssertEqual(write(fd, bytes, bytes.count), bytes.count); close(fd)
    XCTAssertEqual(try store.readAll(), [.init(serverAddress: "https://example.com", deviceName: "Mac", enabled: true)])
    try store.upsert(.init(serverAddress: "https://two.example.com", deviceName: "Mac", enabled: true))
    XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
    XCTAssertEqual(try store.readAll().map(\.serverAddress), ["https://example.com", "https://two.example.com"])
  }

  func testRejectsInsecureOriginWithoutChangingPriorSetting() throws {
    let store = RelayHostConfigurationStore(stateDirectory: try directory())
    let value = RelayHostConfiguration(serverAddress: "https://example.com", deviceName: "Mac", enabled: false)
    try store.upsert(value)
    XCTAssertThrowsError(try store.upsert(.init(serverAddress: "http://example.com", deviceName: "Mac", enabled: true)))
    XCTAssertEqual(try store.readAll(), [value])
  }

  func testRejectsUnsafeFileAndUnknownFields() throws {
    let url = try directory(); let store = RelayHostConfigurationStore(stateDirectory: url)
    let file = url.appendingPathComponent("relay-hosts.json")
    try Data("{\"hosts\":[{\"server_address\":\"https://example.com\",\"device_name\":\"Mac\",\"enabled\":true,\"key\":\"never-allowed\"}]}".utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    XCTAssertThrowsError(try store.readAll())
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path)
    XCTAssertThrowsError(try store.readAll())
    XCTAssertThrowsError(try store.upsert(.init(serverAddress: "https://example.com", deviceName: "Mac", enabled: false)))
    XCTAssertThrowsError(try store.writeAll([]))
  }

  func testUnsafeLegacyFileBlocksWrites() throws {
    let url = try directory(); let store = RelayHostConfigurationStore(stateDirectory: url)
    let legacy = url.appendingPathComponent("relay.json")
    try Data("{\"server_address\":\"https://example.com\",\"device_name\":\"Mac\",\"enabled\":true}".utf8).write(to: legacy)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: legacy.path)
    XCTAssertThrowsError(try store.readAll())
    XCTAssertThrowsError(try store.writeAll([]))
    XCTAssertTrue(FileManager.default.fileExists(atPath: legacy.path))
  }

  func testRejectsFIFOWithoutWaitingForWriter() throws {
    let url = try directory()
    XCTAssertEqual(mkfifo(url.appendingPathComponent("relay-hosts.json").path, 0o600), 0)
    XCTAssertThrowsError(try RelayHostConfigurationStore(stateDirectory: url).readAll())
  }

  func testRejectsSymbolicLinkDirectory() throws {
    let parent = try directory(); let target = parent.appendingPathComponent("real")
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let link = parent.appendingPathComponent("link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
    XCTAssertThrowsError(try RelayHostConfigurationStore(stateDirectory: link).readAll())
  }
}
#endif
