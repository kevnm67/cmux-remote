import NIOCore

public final class LineFrameDecoder: ChannelInboundHandler {
    public typealias InboundIn = ByteBuffer
    public typealias InboundOut = ByteBuffer

    private var buffer = ByteBuffer()

    public init() {}

    public func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = self.unwrapInboundIn(data)
        buffer.writeBuffer(&incoming)
        while let nl = buffer.readableBytesView.firstIndex(of: UInt8(ascii: "\n")) {
            let lineLength = nl - buffer.readerIndex
            if let line = buffer.readSlice(length: lineLength) {
                _ = buffer.readInteger(as: UInt8.self) // discard \n
                context.fireChannelRead(self.wrapInboundOut(line))
            }
        }
        if buffer.readableBytes == 0 { buffer.clear() }
    }
}

public final class LineFrameEncoder: ChannelOutboundHandler {
    public typealias OutboundIn = ByteBuffer
    public typealias OutboundOut = ByteBuffer

    /// cmux `cmuxOnly` capability token. When set, every line is prefixed
    /// with `_cmux_capability_v1 <token> ` (the same envelope cmux's shell
    /// integration uses), which authorizes processes whose ancestry cmux
    /// cannot see, e.g. children of a tmux server reparented to launchd.
    private let capabilityPrefix: [UInt8]?

    public init(capability: String? = nil) {
        self.capabilityPrefix = capability.map { Array("_cmux_capability_v1 \($0) ".utf8) }
    }

    public func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        var buf = self.unwrapOutboundIn(data)
        if let capabilityPrefix {
            var framed = context.channel.allocator.buffer(capacity: capabilityPrefix.count + buf.readableBytes + 1)
            framed.writeBytes(capabilityPrefix)
            framed.writeBuffer(&buf)
            buf = framed
        }
        buf.writeInteger(UInt8(ascii: "\n"))
        context.write(self.wrapOutboundOut(buf), promise: promise)
    }
}
