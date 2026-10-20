import Foundation
import NIOCore

/// PROXY protocol (v1 text and v2 binary) header parsing. `tailscale serve
/// --proxy-protocol` fronts the loopback listener, so the TCP peer is always
/// 127.0.0.1 and the real tailnet source address only travels in this header.
enum ProxyProtocol {
    enum ParseResult: Equatable {
        case needMoreData
        /// First bytes are neither PROXY signature — plain connection.
        case noHeader
        /// `sourceAddress` is nil for v2 LOCAL and v1 UNKNOWN.
        case header(sourceAddress: String?, consumed: Int)
        case malformed
    }

    static let v2Signature: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A, 0x00, 0x0D, 0x0A, 0x51, 0x55, 0x49, 0x54, 0x0A]
    static let v1Prefix: [UInt8] = Array("PROXY ".utf8)
    static let v1MaxLength = 107
    static let v2MaxPayload = 536

    static func parse(_ buffer: ByteBuffer) -> ParseResult {
        let bytes = buffer.readableBytesView
        let head = Array(bytes.prefix(v2Signature.count))
        let isV2 = head == Array(v2Signature.prefix(head.count))
        let v1Head = head.prefix(v1Prefix.count)
        let isV1 = Array(v1Head) == Array(v1Prefix.prefix(v1Head.count))
        guard isV2 || isV1 else { return .noHeader }
        if isV2 {
            if head.count < v2Signature.count { return .needMoreData }
            return parseV2(Array(bytes))
        }
        if head.count < v1Prefix.count { return .needMoreData }
        return parseV1(Array(bytes))
    }

    private static func parseV2(_ b: [UInt8]) -> ParseResult {
        guard b.count >= 16 else { return .needMoreData }
        let verCmd = b[12], fam = b[13]
        let length = Int(b[14]) << 8 | Int(b[15])
        guard verCmd >> 4 == 2, verCmd & 0x0F <= 1, length <= v2MaxPayload else { return .malformed }
        guard b.count >= 16 + length else { return .needMoreData }
        let consumed = 16 + length
        if verCmd & 0x0F == 0 { return .header(sourceAddress: nil, consumed: consumed) }
        let p = Array(b[16..<consumed])
        switch fam >> 4 {
        case 1:
            guard fam & 0x0F == 1 else { return .header(sourceAddress: nil, consumed: consumed) }
            guard length >= 12 else { return .malformed }
            return .header(sourceAddress: p[0..<4].map(String.init).joined(separator: "."), consumed: consumed)
        case 2:
            guard fam & 0x0F == 1 else { return .header(sourceAddress: nil, consumed: consumed) }
            guard length >= 36 else { return .malformed }
            var groups: [String] = []
            for i in stride(from: 0, to: 16, by: 2) {
                groups.append(String(UInt16(p[i]) << 8 | UInt16(p[i + 1]), radix: 16))
            }
            return .header(sourceAddress: groups.joined(separator: ":"), consumed: consumed)
        case 0 where fam == 0:
            return .header(sourceAddress: nil, consumed: consumed)
        default:
            // AF_UNIX or unknown family: no usable IP.
            return .header(sourceAddress: nil, consumed: consumed)
        }
    }

    private static func parseV1(_ b: [UInt8]) -> ParseResult {
        let limit = min(b.count, v1MaxLength)
        guard let cr = (0..<limit).first(where: { b[$0] == 0x0D }) else {
            return b.count >= v1MaxLength ? .malformed : .needMoreData
        }
        guard cr + 1 < b.count else { return .needMoreData }
        guard b[cr + 1] == 0x0A, let line = String(bytes: b[0..<cr], encoding: .ascii) else { return .malformed }
        let consumed = cr + 2
        let parts = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        switch parts.count >= 2 ? parts[1] : "" {
        case "UNKNOWN":
            return .header(sourceAddress: nil, consumed: consumed)
        case "TCP4", "TCP6":
            guard parts.count == 6,
                  let src = try? SocketAddress(ipAddress: parts[2], port: 0),
                  (try? SocketAddress(ipAddress: parts[3], port: 0)) != nil,
                  parts[4].allSatisfy(\.isNumber), parts[5].allSatisfy(\.isNumber),
                  (parts[1] == "TCP4") == (src.protocol == .inet)
            else { return .malformed }
            return .header(sourceAddress: src.ipAddress, consumed: consumed)
        default:
            return .malformed
        }
    }

    static func isLoopback(_ address: SocketAddress?) -> Bool {
        guard let ip = address?.ipAddress else { return false }
        return ip == "::1" || ip.hasPrefix("127.")
    }
}

/// Per-connection holder for the PROXY source address. Written once by
/// `ProxyProtocolDecoder` and read by `HTTPHandler`, both on the channel's
/// event loop.
final class ProxiedPeer: @unchecked Sendable {
    var address: String?
}

/// Consumes an optional PROXY header at the start of a connection, then
/// removes itself. Fail closed: a header from a non-loopback TCP peer or a
/// malformed header closes the connection. No header leaves behavior as-is.
struct ProxyProtocolDecoder: ByteToMessageDecoder {
    typealias InboundOut = ByteBuffer
    let peer: ProxiedPeer
    private var finished = false

    init(peer: ProxiedPeer) { self.peer = peer }

    mutating func decode(context: ChannelHandlerContext, buffer: inout ByteBuffer) throws -> DecodingState {
        if !finished {
            switch ProxyProtocol.parse(buffer) {
            case .needMoreData:
                return .needMoreData
            case .malformed:
                context.close(promise: nil)
                return .needMoreData
            case .noHeader:
                finish(context)
            case .header(let source, let consumed):
                guard ProxyProtocol.isLoopback(context.remoteAddress) else {
                    context.close(promise: nil)
                    return .needMoreData
                }
                buffer.moveReaderIndex(forwardBy: consumed)
                peer.address = source
                finish(context)
            }
        }
        // Hand any bytes after the header (or all of them, with no header)
        // to the HTTP pipeline ourselves; removal alone does not guarantee it.
        if buffer.readableBytes > 0 {
            context.fireChannelRead(wrapInboundOut(buffer.readSlice(length: buffer.readableBytes)!))
        }
        return .needMoreData
    }

    private mutating func finish(_ context: ChannelHandlerContext) {
        finished = true
        context.pipeline.removeHandler(context: context, promise: nil)
    }

    mutating func decodeLast(context: ChannelHandlerContext, buffer: inout ByteBuffer, seenEOF: Bool) throws -> DecodingState {
        .needMoreData
    }
}
