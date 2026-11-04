import Foundation

/// Whether the Macs a client device is paired with are connected to the
/// relay server, pushed by the server as it learns it (`GET
/// /v1/relay/presence`, protocol/relay-v1.md, "Presence"). Not every server
/// has it: one that answers 404 doesn't, and the client lists terminals
/// instead. It carries grant IDs and online flags only.
public enum RelayPresence {
  /// The most grants one stream watches.
  public static let maxGrants = 16

  public enum Failure: Error, Equatable {
    /// The server has no presence stream (an older server).
    case unsupported
  }

  /// The first message: which grants to watch.
  static func watchRequest(grantIDs: [String]) throws -> Data {
    struct Watch: Encodable {
      let type = "watch"
      let grant_ids: [String]
    }
    let ids = Array(grantIDs.prefix(maxGrants))
    guard !ids.isEmpty, ids.allSatisfy({ PairingEncoding.canonicalID($0) == $0 }), Set(ids).count == ids.count
    else { throw RelayError.invalidMessage }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(Watch(grant_ids: ids))
  }

  /// A presence message: each watched grant's Mac, online or not.
  static func decode(_ data: Data) throws -> [String: Bool] {
    struct Entry: Decodable {
      let grant_id: String
      let online: Bool
    }
    struct Message: Decodable {
      let type: String
      let hosts: [Entry]
    }
    guard data.count <= 4096, let message = try? JSONDecoder().decode(Message.self, from: data),
      message.type == "presence", message.hosts.count <= maxGrants,
      message.hosts.allSatisfy({ PairingEncoding.canonicalID($0.grant_id) == $0.grant_id })
    else { throw RelayError.invalidMessage }
    var result: [String: Bool] = [:]
    for entry in message.hosts { result[entry.grant_id] = entry.online }
    return result
  }

  /// Watches `grantIDs` until cancelled: the first value is a snapshot, then
  /// each change. Ends with `Failure.unsupported` on a server without
  /// presence, or with the relay error that closed it.
  public static func watch(pairing: PairingClient, grantIDs: [String])
    -> AsyncThrowingStream<[String: Bool], Error>
  {
    AsyncThrowingStream { continuation in
      let task = Task {
        do {
          let request = try watchRequest(grantIDs: grantIDs)
          let credentials = try await pairing.relayCredentials()
          let socket = try RelayWebSocket(credentials: credentials, path: "v1/relay/presence")
          defer { socket.close() }
          do { try await socket.sendText(request) } catch {
            throw socket.unsupported ? Failure.unsupported : error
          }
          while !Task.isCancelled {
            let data: Data
            do { data = try await socket.control() } catch {
              throw socket.unsupported ? Failure.unsupported : error
            }
            continuation.yield(try decode(data))
          }
          continuation.finish()
        } catch {
          continuation.finish(throwing: error)
        }
      }
      continuation.onTermination = { _ in task.cancel() }
    }
  }
}
