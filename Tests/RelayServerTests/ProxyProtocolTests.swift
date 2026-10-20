import XCTest
import NIOCore
import NIOEmbedded
@testable import RelayServer
@testable import RelayCore

final class ProxyProtocolTests: XCTestCase {
    private func buf(_ bytes: [UInt8]) -> ByteBuffer { ByteBuffer(bytes: bytes) }

    private func v2(cmd: UInt8 = 0x21, fam: UInt8 = 0x11, payload: [UInt8]) -> [UInt8] {
        ProxyProtocol.v2Signature + [cmd, fam, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)] + payload
    }

    func testV2TCP4ExtractsSource() {
        let payload: [UInt8] = [100, 83, 137, 109, 100, 75, 201, 6, 0x30, 0x39, 0x11, 0x2F]
        XCTAssertEqual(ProxyProtocol.parse(buf(v2(payload: payload) + Array("GET".utf8))),
                       .header(sourceAddress: "100.83.137.109", consumed: 28))
    }

    func testV2TCP6ExtractsSource() {
        var payload = [UInt8](repeating: 0, count: 36)
        payload[0] = 0xFD; payload[1] = 0x7A; payload[15] = 0x01
        guard case .header(let src, _) = ProxyProtocol.parse(buf(v2(fam: 0x21, payload: payload))) else {
            return XCTFail("expected header")
        }
        XCTAssertEqual(src, "fd7a:0:0:0:0:0:0:1")
    }

    func testV2LocalHasNoSource() {
        XCTAssertEqual(ProxyProtocol.parse(buf(v2(cmd: 0x20, fam: 0, payload: []))),
                       .header(sourceAddress: nil, consumed: 16))
    }

    func testV2PartialNeedsMoreData() {
        XCTAssertEqual(ProxyProtocol.parse(buf(Array(ProxyProtocol.v2Signature.prefix(5)))), .needMoreData)
        XCTAssertEqual(ProxyProtocol.parse(buf(Array(v2(payload: [UInt8](repeating: 1, count: 12)).dropLast(3)))),
                       .needMoreData)
    }

    func testV2MalformedRejected() {
        XCTAssertEqual(ProxyProtocol.parse(buf(v2(cmd: 0x31, payload: [UInt8](repeating: 1, count: 12)))), .malformed)
        XCTAssertEqual(ProxyProtocol.parse(buf(v2(payload: [1, 2, 3]))), .malformed, "TCP4 payload too short")
        let huge = ProxyProtocol.v2Signature + [0x21, 0x11, 0xFF, 0xFF]
        XCTAssertEqual(ProxyProtocol.parse(buf(huge)), .malformed)
    }

    func testV1ParsesAndRejects() {
        XCTAssertEqual(ProxyProtocol.parse(buf(Array("PROXY TCP4 100.64.1.2 100.75.201.6 5000 4399\r\nGET".utf8))),
                       .header(sourceAddress: "100.64.1.2", consumed: 46))
        XCTAssertEqual(ProxyProtocol.parse(buf(Array("PROXY UNKNOWN\r\n".utf8))),
                       .header(sourceAddress: nil, consumed: 15))
        XCTAssertEqual(ProxyProtocol.parse(buf(Array("PROXY TCP4 nope 1.2.3.4 1 2\r\n".utf8))), .malformed)
        XCTAssertEqual(ProxyProtocol.parse(buf(Array("PROXY TCP6 1.2.3.4 1.2.3.5 1 2\r\n".utf8))), .malformed)
        XCTAssertEqual(ProxyProtocol.parse(buf(Array("PROXY TCP4 1.2.3.4".utf8))), .needMoreData)
        XCTAssertEqual(ProxyProtocol.parse(buf(Array("PROXY ".utf8 + [UInt8](repeating: 0x41, count: 120)))), .malformed)
    }

    func testPlainHTTPIsNoHeader() {
        XCTAssertEqual(ProxyProtocol.parse(buf(Array("GET /v1/health HTTP/1.1\r\n".utf8))), .noHeader)
        XCTAssertEqual(ProxyProtocol.parse(buf(Array("POST /".utf8))), .noHeader)
    }

    func testLoopbackOnlyTrust() throws {
        XCTAssertTrue(ProxyProtocol.isLoopback(try SocketAddress(ipAddress: "127.0.0.1", port: 1)))
        XCTAssertTrue(ProxyProtocol.isLoopback(try SocketAddress(ipAddress: "::1", port: 1)))
        XCTAssertFalse(ProxyProtocol.isLoopback(try SocketAddress(ipAddress: "100.83.137.109", port: 1)))
        XCTAssertFalse(ProxyProtocol.isLoopback(nil))
    }

    // MARK: - Decoder over a channel

    private func channel(remote: String) throws -> (EmbeddedChannel, ProxiedPeer) {
        let peer = ProxiedPeer()
        let ch = EmbeddedChannel()
        try ch.pipeline.syncOperations.addHandler(ByteToMessageHandler(ProxyProtocolDecoder(peer: peer)))
        try ch.connect(to: SocketAddress(ipAddress: remote, port: 40000)).wait()
        return (ch, peer)
    }

    func testDecoderTrustsLoopbackHeaderAndForwardsRest() throws {
        let (ch, peer) = try channel(remote: "127.0.0.1")
        try ch.writeInbound(buf(Array("PROXY TCP4 100.64.1.2 100.75.201.6 5000 4399\r\nGET / ".utf8)))
        XCTAssertEqual(peer.address, "100.64.1.2")
        XCTAssertTrue(ch.isActive)
        let rest: ByteBuffer? = try ch.readInbound()
        XCTAssertEqual(rest.map { String(buffer: $0) }, "GET / ")
    }

    func testDecoderClosesOnNonLoopbackHeader() throws {
        let (ch, peer) = try channel(remote: "100.83.137.109")
        try? ch.writeInbound(buf(Array("PROXY TCP4 1.2.3.4 100.75.201.6 5000 4399\r\n".utf8)))
        XCTAssertFalse(ch.isActive)
        XCTAssertNil(peer.address)
    }

    func testDecoderClosesOnMalformedHeader() throws {
        let (ch, peer) = try channel(remote: "127.0.0.1")
        try? ch.writeInbound(buf(Array("PROXY TCP4 bogus\r\n".utf8)))
        XCTAssertFalse(ch.isActive)
        XCTAssertNil(peer.address)
    }

    func testDecoderPassesPlainTrafficUnchanged() throws {
        let (ch, peer) = try channel(remote: "100.83.137.109")
        try ch.writeInbound(buf(Array("GET /v1/health HTTP/1.1\r\n".utf8)))
        XCTAssertTrue(ch.isActive)
        XCTAssertNil(peer.address)
        let out: ByteBuffer? = try ch.readInbound()
        XCTAssertEqual(out.map { String(buffer: $0) }, "GET /v1/health HTTP/1.1\r\n")
    }

    // MARK: - End to end through HTTPServer

    func testRegisterUsesProxySourceForWhois() async throws {
        let fx = try await HTTPServerFixture.make(peers: [
            "127.0.0.1": .init(loginName: "a@b", hostname: "loop", os: "x", nodeKey: "nk-loop"),
            "100.64.1.2": .init(loginName: "a@b", hostname: "phone", os: "ios", nodeKey: "nk-phone"),
        ])
        defer { Task { await fx.shutdown() } }
        let resp = try await fx.rawRequest(
            "PROXY TCP4 100.64.1.2 100.75.201.6 5000 4399\r\nPOST /v1/devices/me/register HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        )
        XCTAssertEqual(resp.statusCode, 200, resp.bodyString)
        XCTAssertEqual(fx.deviceStore.allDevices().map(\.hostname), ["phone"])
    }

    func testRegisterWithProxySourceNotOnTailnetIsForbidden() async throws {
        let fx = try await HTTPServerFixture.make()
        defer { Task { await fx.shutdown() } }
        let resp = try await fx.rawRequest(
            "PROXY TCP4 9.9.9.9 100.75.201.6 5000 4399\r\nPOST /v1/devices/me/register HTTP/1.1\r\nHost: x\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        )
        XCTAssertEqual(resp.statusCode, 403)
    }
}
