import Foundation

/// Aggregated counters for diagnostic events.
public struct BleuDiagnosticMetrics: Sendable, Codable, Equatable {
    public var transportPacketsRejected: Int = 0
    public var responseEnvelopeDecodeFailures: Int = 0
    public var incomingInvocationDecodeFailures: Int = 0
    public var incomingRPCResponseEncodeFailures: Int = 0
    public var incomingRPCResponseSendFailures: Int = 0
    public var incomingRPCQueueDrops: Int = 0
    public var attErrorsMatched: Int = 0
    public var attErrorsUnmatched: Int = 0

    mutating func record(_ event: BleuDiagnosticEvent) {
        switch event.kind {
        case .transportPacketRejected:
            transportPacketsRejected += 1
        case .responseEnvelopeDecodeFailed:
            responseEnvelopeDecodeFailures += 1
        case .incomingInvocationDecodeFailed:
            incomingInvocationDecodeFailures += 1
        case .incomingRPCResponseEncodeFailed:
            incomingRPCResponseEncodeFailures += 1
        case .incomingRPCResponseSendFailed:
            incomingRPCResponseSendFailures += 1
        case .incomingRPCQueueFull:
            incomingRPCQueueDrops += 1
        case .attErrorMatched:
            attErrorsMatched += 1
        case .attErrorUnmatched:
            attErrorsUnmatched += 1
        }
    }
}
