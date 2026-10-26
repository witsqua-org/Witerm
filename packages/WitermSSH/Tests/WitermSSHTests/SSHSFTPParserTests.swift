import XCTest
import NIO
import NIOEmbedded
@testable import Citadel

final class SSHSFTPParserTests: XCTestCase {
    func testZeroLengthFrameIsRejectedBeforeNegativeSlice() throws {
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(SFTPMessageParser()))
        defer { _ = try? channel.finish() }
        var bytes = ByteBuffer()
        bytes.writeInteger(UInt32(0))
        bytes.writeInteger(UInt8(2))
        XCTAssertThrowsError(try channel.writeInbound(bytes))
    }

    func testOversizedLengthIsRejectedWithoutWaitingForPayload() throws {
        for length: UInt32 in [1_048_577, .max] {
            let channel = EmbeddedChannel(handler: ByteToMessageHandler(SFTPMessageParser()))
            defer { _ = try? channel.finish() }
            var header = ByteBuffer()
            header.writeInteger(length)
            XCTAssertThrowsError(try channel.writeInbound(header))
        }
    }

    func testDirectoryMetadataBudgetAccumulatesAcrossPackets() throws {
        var budget = SFTPListingBudget()
        let large = String(repeating: "x", count: 1_048_576)
        let component = SFTPPathComponent(filename: "file", longname: large, attributes: .none)
        for _ in 0..<15 { try budget.consume([component]) }
        XCTAssertThrowsError(try budget.consume([component]))
        var emptyFields = SFTPFileAttributes()
        emptyFields.extended = [("", ""), ("", "")]
        var second = SFTPListingBudget()
        try second.consume([.init(filename: "中", longname: "", attributes: emptyFields)])
        XCTAssertEqual(second.remainingBytes, 16 * 1024 * 1024 - 128 - 3 - 2 * 64)
    }

    func testFragmentedValidVersionFrameStillDecodes() throws {
        let channel = EmbeddedChannel(handler: ByteToMessageHandler(SFTPMessageParser()))
        defer { _ = try? channel.finish() }
        var frame = ByteBuffer()
        frame.writeInteger(UInt32(5))
        frame.writeInteger(UInt8(2))
        frame.writeInteger(UInt32(3))
        XCTAssertTrue(try channel.writeInbound(frame.readSlice(length: 2)!).isEmpty)
        XCTAssertFalse(try channel.writeInbound(frame).isEmpty)
        let message: SFTPMessage? = try channel.readInbound()
        guard case .version(let version) = message else {
            return XCTFail("Fragmented SFTP version was not decoded")
        }
        XCTAssertEqual(version.version, .v3)
    }
}
