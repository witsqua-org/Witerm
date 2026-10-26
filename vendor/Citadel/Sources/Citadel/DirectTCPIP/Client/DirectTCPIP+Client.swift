import NIO
import NIOSSH

internal final class DataToBufferCodec: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias InboundOut = ByteBuffer
    typealias OutboundIn = ByteBuffer
    typealias OutboundOut = SSHChannelData

    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { error in
            context.fireErrorCaught(error)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let data = self.unwrapInboundIn(data)

        guard case .byteBuffer(let bytes) = data.data else {
            context.fireErrorCaught(SSHChannelError.invalidDataType)
            context.close(promise: nil)
            return
        }

        guard case .channel = data.type else {
            context.fireErrorCaught(SSHChannelError.invalidDataType)
            return
        }

        context.fireChannelRead(self.wrapInboundOut(bytes))
    }

    func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
        let data = self.unwrapOutboundIn(data)
        context.write(self.wrapOutboundOut(SSHChannelData(type: .channel, data: .byteBuffer(data))), promise: promise)
    }
}

extension SSHClient {
    /// Creates a new direct TCP/IP channel. This channel type is used to open a TCP/IP connection to a remote host, through the remote SSH server.
    public func createDirectTCPIPChannel(
        using settings: SSHChannelType.DirectTCPIP,
        initialize: @escaping @Sendable (Channel) -> EventLoopFuture<Void>
    ) async throws -> Channel {
        let transport = session.channel
        return try await withTaskCancellationHandler {
          try await eventLoop.flatSubmit { [eventLoop, sshHandler = self.session.sshHandler] in
            let createdChannel = eventLoop.makePromise(of: Channel.self)
            let result = eventLoop.makePromise(of: Channel.self)
            var resolved = false
            let timeout = eventLoop.scheduleTask(in: .seconds(10)) {
                guard !resolved else { return }
                resolved = true
                result.fail(SSHClientError.channelCreationFailed)
                transport.close(promise: nil)
            }
            createdChannel.futureResult.whenComplete { outcome in
                guard !resolved else {
                    if case .success(let channel) = outcome { channel.close(promise: nil) }
                    return
                }
                resolved = true
                timeout.cancel()
                result.completeWith(outcome)
            }
            sshHandler.value.createChannel(
                createdChannel,
                channelType: .directTCPIP(settings)
            ) { channel, type in
                guard case .directTCPIP = type else {
                    return channel.eventLoop.makeFailedFuture(SSHClientError.channelCreationFailed)
                }
                
                do {
                    try channel.pipeline.syncOperations.addHandler(DataToBufferCodec())
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }

                return initialize(channel)
            }
            
            return result.futureResult
          }.get()
        } onCancel: {
            transport.close(promise: nil)
        }
    }
}
