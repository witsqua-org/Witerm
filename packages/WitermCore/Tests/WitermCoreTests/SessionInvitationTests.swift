import Foundation
import XCTest
@testable import WitermCore

final class SessionInvitationTests: XCTestCase {
  private let hostKey = Data(repeating: 1, count: 32).base64EncodedString()
  private let clientKey = Data(repeating: 2, count: 32).base64EncodedString()

  private func invitation(until: Date = Date().addingTimeInterval(3600)) -> SessionInvitation {
    let pairing = PairingInvitation.make(
      server: "https://witerm.example:37429", pairingID: "11111111-1111-4111-8111-111111111111",
      hostKey: hostKey, secret: PairingEncoding.base64URL(Data(repeating: 3, count: 32)))
    return SessionInvitation.make(
      pairing: pairing, permission: .view, expiresAt: until, proofKey: Data(repeating: 4, count: 32))
  }

  func testLinkRoundTripsAndCarriesThePairingJoin() throws {
    let made = invitation()
    let parsed = try SessionInvitation(urlString: made.urlString)
    XCTAssertEqual(parsed, made)
    XCTAssertEqual(parsed.permission, .view)
    XCTAssertEqual(parsed.server, "https://witerm.example:37429")
    let join = parsed.pairingInvitation()
    XCTAssertEqual(join.pairingID, made.pairingID)
    XCTAssertEqual(join.hostPublicKey, hostKey)
    XCTAssertEqual(try PairingInvitation(urlString: join.urlString, expectedServer: parsed.server), join)
  }

  func testProofBindsKeyPairingAndRecipientKey() {
    let made = invitation()
    let proof = made.proof(clientPublicKey: clientKey)
    XCTAssertTrue(SessionInvitation.verify(proof: proof, key: made.proofKey, pairingID: made.pairingID, clientPublicKey: clientKey))
    XCTAssertFalse(SessionInvitation.verify(proof: proof, key: made.proofKey, pairingID: made.pairingID, clientPublicKey: hostKey))
    XCTAssertFalse(SessionInvitation.verify(
      proof: proof, key: made.proofKey, pairingID: "22222222-2222-4222-8222-222222222222", clientPublicKey: clientKey))
    XCTAssertFalse(SessionInvitation.verify(
      proof: proof, key: Data(repeating: 5, count: 32), pairingID: made.pairingID, clientPublicKey: clientKey))
  }

  func testRejectsExpiredOverlongAndAlteredLinks() {
    XCTAssertThrowsError(try SessionInvitation(urlString: invitation(until: Date().addingTimeInterval(-1)).urlString))
    XCTAssertThrowsError(try SessionInvitation(urlString: invitation(until: Date().addingTimeInterval(3 * 86_400)).urlString))
    let made = invitation().urlString
    for altered in [
      made.replacingOccurrences(of: "witerm://share", with: "witerm://pair"),
      made.replacingOccurrences(of: "access=view", with: "access=admin"),
      made + "&extra=1",
      made + "#fragment",
      made.replacingOccurrences(of: "&key=", with: "&key=x"),
    ] {
      XCTAssertThrowsError(try SessionInvitation(urlString: altered), altered)
    }
  }
}
