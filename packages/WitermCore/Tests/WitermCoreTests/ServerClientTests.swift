import Foundation
import XCTest
@testable import WitermCore

/// Serves canned diagnostics in chunks without Content-Length, so limits must
/// hold while streaming. A route with `finish: false` never completes.
private final class ServerStubProtocol: URLProtocol, @unchecked Sendable {
    struct Route { var body: Data; var finish = true }
    nonisolated(unsafe) static var routes: [String: Route] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let route = Self.routes[url.path],
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: [:]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        var offset = 0
        while offset < route.body.count {
            let end = min(offset + 65_536, route.body.count)
            client?.urlProtocol(self, didLoad: route.body.subdata(in: offset..<end))
            offset = end
        }
        if route.finish { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() {}
}

final class ServerClientTests: XCTestCase {
    private let info = Data(#"{"service":"witerm","protocol_version":1,"capabilities":[]}"#.utf8)

    private func stubbedClient(info: Data, readiness: ServerStubProtocol.Route, timeout: TimeInterval = 15) -> ServerClient {
        ServerStubProtocol.routes = ["/v1/info": .init(body: info), "/readyz": readiness]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ServerStubProtocol.self]
        return ServerClient(configuration: configuration, resourceTimeout: timeout)
    }

    func testDiagnosticsAcceptSmallResponses() async throws {
        let result = try await stubbedClient(info: info, readiness: .init(body: Data("ok".utf8)))
            .checkConnection(address: "http://localhost:8080")
        XCTAssertEqual(result.service, "witerm")
    }

    func testDiagnosticsRejectOversizedResponses() async throws {
        let large = Data(repeating: 0x20, count: 4 << 20)
        for client in [stubbedClient(info: info + large, readiness: .init(body: Data())),
                       stubbedClient(info: info, readiness: .init(body: large))] {
            do {
                _ = try await client.checkConnection(address: "http://localhost:8080")
                XCTFail("an oversized diagnostic response was buffered")
            } catch ServerClientError.incompatibleServer {}
        }
    }

    func testDiagnosticsBoundTheWholeResponseTime() async throws {
        let client = stubbedClient(info: info, readiness: .init(body: Data("o".utf8), finish: false), timeout: 1)
        let began = ContinuousClock.now
        do {
            _ = try await client.checkConnection(address: "http://localhost:8080")
            XCTFail("an unfinished response was accepted")
        } catch {}
        XCTAssertLessThan(began.duration(to: .now), .seconds(5))
    }

    func testAddressValidationBeforeSaving() throws {
        for address in ["https://witerm.example.com", "http://localhost:8080", "http://127.0.0.1:8080/"] {
            XCTAssertNotNil(try ServerClient.validatedURL(for: address).host)
        }
        for address in ["https://", "localhost:8080", "https://example.com/path", "https://example.com#fragment", "https://user@example.com"] {
            XCTAssertThrowsError(try ServerClient.validatedURL(for: address))
        }
    }

    func testLiveServerConnection() async throws {
        guard let address = ProcessInfo.processInfo.environment["WITERM_TEST_SERVER_URL"] else {
            throw XCTSkip("Set WITERM_TEST_SERVER_URL to test a running server")
        }
        let info = try await ServerClient().checkConnection(address: address)
        XCTAssertEqual(info.service, "witerm")
    }

    func testSharedServerContract() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("protocol/fixtures/server-info.json"))
        let info = try JSONDecoder().decode(ServerInfo.self, from: data)
        XCTAssertEqual(info.service, "witerm")
        XCTAssertEqual(info.protocolVersion, 1)
        XCTAssertEqual(info.capabilities, ["device_identity_v1", "device_pairing_v1", "encrypted_relay_v1"])
    }

    func testRejectsAddressesThatCouldExposeCredentials() async throws {
        let client = ServerClient()
        for address in ["file:///tmp/witerm", "https://user:secret@example.com", "https://example.com?token=secret", "https://example.com/prefix"] {
            do {
                _ = try await client.checkConnection(address: address)
                XCTFail("accepted invalid address")
            } catch ServerClientError.invalidAddress {
                // Validation occurs before any network request.
            }
        }
    }
}

