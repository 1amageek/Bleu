import Foundation

/// Severity for diagnostic events emitted by Bleu internals.
public enum BleuDiagnosticSeverity: String, Sendable, Codable, Equatable {
    case info
    case warning
    case error
}

/// Stable category for diagnostic events.
public enum BleuDiagnosticKind: String, Sendable, Codable, Equatable {
    case transportPacketRejected
    case responseEnvelopeDecodeFailed
    case incomingInvocationDecodeFailed
    case incomingRPCResponseEncodeFailed
    case incomingRPCResponseSendFailed
    case incomingRPCQueueFull
    case attErrorMatched
    case attErrorUnmatched
}

/// Structured diagnostic event for failures that must not be log-only.
public struct BleuDiagnosticEvent: Identifiable, Sendable, Codable, Equatable {
    public let id: UUID
    public let timestamp: Date
    public let severity: BleuDiagnosticSeverity
    public let kind: BleuDiagnosticKind
    public let message: String
    public let peripheralID: UUID?
    public let centralID: UUID?
    public let characteristicID: UUID?
    public let callID: String?
    public let underlyingError: String?

    public init(
        severity: BleuDiagnosticSeverity,
        kind: BleuDiagnosticKind,
        message: String,
        peripheralID: UUID? = nil,
        centralID: UUID? = nil,
        characteristicID: UUID? = nil,
        callID: String? = nil,
        underlyingError: String? = nil
    ) {
        self.id = UUID()
        self.timestamp = Date()
        self.severity = severity
        self.kind = kind
        self.message = message
        self.peripheralID = peripheralID
        self.centralID = centralID
        self.characteristicID = characteristicID
        self.callID = callID
        self.underlyingError = underlyingError
    }
}
