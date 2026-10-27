import Foundation
@preconcurrency import Citadel
@preconcurrency import NIO
@preconcurrency import NIOSSH

extension SSHFailure {
    /// Maps transport and engine errors raised while connecting to a specific
    /// failure. Unrecognized errors are returned unchanged.
    static func classify(_ error: Error) -> Error {
        if error is SSHFailure || error is CancellationError { return error }
        switch error {
        case let error as SSHClientError:
            switch error {
            case .allAuthenticationOptionsFailed: return SSHFailure.authenticationFailed
            case .unsupportedPasswordAuthentication, .unsupportedPrivateKeyAuthentication,
                 .unsupportedHostBasedAuthentication: return SSHFailure.authenticationMethodUnavailable
            // While connecting, only a jump's forwarded channel can fail to open.
            case .channelCreationFailed: return SSHFailure.jumpTargetUnreachable
            }
        case let error as NIOSSHError:
            if error.type == .channelSetupRejected { return SSHFailure.jumpTargetUnreachable }
            if error.type == .keyExchangeNegotiationFailure { return SSHFailure.noCommonAlgorithms }
            return error
        case let error as ChannelError:
            if case .connectTimeout = error { return SSHFailure.timedOut }
            return error
        case let error as NIOConnectionError:
            for attempt in error.connectionErrors {
                if let failure = classify(errno: attempt.error) { return failure }
            }
            if error.connectionErrors.isEmpty, error.dnsAError != nil || error.dnsAAAAError != nil {
                return SSHFailure.hostNotFound
            }
            return error
        default:
            return classify(errno: error) ?? error
        }
    }

    private static func classify(errno error: Error) -> SSHFailure? {
        if let error = error as? ChannelError, case .connectTimeout = error { return .timedOut }
        guard let error = error as? IOError else { return nil }
        switch error.errnoCode {
        case ECONNREFUSED: return .connectionRefused
        case ETIMEDOUT: return .timedOut
        case ENETUNREACH, EHOSTUNREACH, ENETDOWN, EHOSTDOWN: return .networkUnreachable
        default: return nil
        }
    }
}
