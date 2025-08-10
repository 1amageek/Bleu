import Foundation
import CoreBluetooth

/// Bleu v2 Error types for distributed actor system
public enum BleuError: Error, Sendable {
    // Connection errors
    case bluetoothUnavailable
    case bluetoothPoweredOff
    case bluetoothUnauthorized
    case deviceNotFound
    case connectionFailed(String)
    case connectionLost
    case communicationTimeout
    case scanningFailed(String)
    
    // Data errors
    case serializationFailed
    case deserializationFailed
    case dataCorrupted
    case invalidDataFormat
    case dataTooLarge(Int, Int) // actual size, max size
    
    // Security errors
    case authenticationFailed
    case encryptionFailed
    case decryptionFailed
    case certificateInvalid
    case permissionDenied
    case securityViolation(String)
    
    // Actor system errors
    case remoteActorUnavailable
    case actorSystemFailure(String)
    case distributedCallFailed(String)
    
    // Request/Response errors
    case invalidRequest
    case requestFailed(String)
    case responseTimeout
    case unexpectedResponse
    
    // Service/Characteristic errors
    case serviceNotFound(UUID)
    case characteristicNotFound(UUID)
    case serviceDiscoveryFailed(UUID)
    case characteristicDiscoveryFailed(UUID)
    case characteristicNotReadable(UUID)
    case characteristicNotWritable(UUID)
    case characteristicNotNotifiable(UUID)
    
    // Resource errors
    case resourceExhausted(String)
    case memoryPressure
    case queueOverflow
    
    // Platform errors
    case platformNotSupported
    case osVersionNotSupported(String)
    case hardwareNotSupported
    
    public var localizedDescription: String {
        switch self {
        // Connection errors
        case .bluetoothUnavailable:
            return "Bluetooth is not available"
        case .bluetoothPoweredOff:
            return "Bluetooth is powered off"
        case .bluetoothUnauthorized:
            return "Bluetooth access is not authorized"
        case .deviceNotFound:
            return "Target device not found"
        case .connectionFailed(let reason):
            return "Connection failed: \(reason)"
        case .connectionLost:
            return "Connection was lost"
        case .communicationTimeout:
            return "Communication timeout"
        case .scanningFailed(let reason):
            return "Scanning failed: \(reason)"
            
        // Data errors
        case .serializationFailed:
            return "Failed to serialize data"
        case .deserializationFailed:
            return "Failed to deserialize data"
        case .dataCorrupted:
            return "Data is corrupted"
        case .invalidDataFormat:
            return "Invalid data format"
        case .dataTooLarge(let actual, let max):
            return "Data too large: \(actual) bytes (max: \(max) bytes)"
            
        // Security errors
        case .authenticationFailed:
            return "Authentication failed"
        case .encryptionFailed:
            return "Encryption failed"
        case .decryptionFailed:
            return "Decryption failed"
        case .certificateInvalid:
            return "Certificate is invalid"
        case .permissionDenied:
            return "Permission denied"
        case .securityViolation(let reason):
            return "Security violation: \(reason)"
            
        // Actor system errors
        case .remoteActorUnavailable:
            return "Remote actor is unavailable"
        case .actorSystemFailure(let reason):
            return "Actor system failure: \(reason)"
        case .distributedCallFailed(let reason):
            return "Distributed call failed: \(reason)"
            
        // Request/Response errors
        case .invalidRequest:
            return "Invalid request"
        case .requestFailed(let reason):
            return "Request failed: \(reason)"
        case .responseTimeout:
            return "Response timeout"
        case .unexpectedResponse:
            return "Unexpected response"
            
        // Service/Characteristic errors
        case .serviceNotFound(let uuid):
            return "Service not found: \(uuid)"
        case .characteristicNotFound(let uuid):
            return "Characteristic not found: \(uuid)"
        case .serviceDiscoveryFailed(let uuid):
            return "Service discovery failed: \(uuid)"
        case .characteristicDiscoveryFailed(let uuid):
            return "Characteristic discovery failed: \(uuid)"
        case .characteristicNotReadable(let uuid):
            return "Characteristic is not readable: \(uuid)"
        case .characteristicNotWritable(let uuid):
            return "Characteristic is not writable: \(uuid)"
        case .characteristicNotNotifiable(let uuid):
            return "Characteristic is not notifiable: \(uuid)"
            
        // Resource errors
        case .resourceExhausted(let reason):
            return "Resource exhausted: \(reason)"
        case .memoryPressure:
            return "Memory pressure detected"
        case .queueOverflow:
            return "Queue overflow"
            
        // Platform errors
        case .platformNotSupported:
            return "Platform not supported"
        case .osVersionNotSupported(let version):
            return "OS version not supported: \(version)"
        case .hardwareNotSupported:
            return "Hardware not supported"
        }
    }
    
    /// Error severity level
    public var severity: ErrorSeverity {
        switch self {
        case .bluetoothUnavailable, .bluetoothPoweredOff, .platformNotSupported, .osVersionNotSupported, .hardwareNotSupported:
            return .critical
        case .authenticationFailed, .encryptionFailed, .decryptionFailed, .securityViolation, .permissionDenied:
            return .high
        case .connectionFailed, .connectionLost, .deviceNotFound, .serviceNotFound, .characteristicNotFound:
            return .medium
        case .communicationTimeout, .responseTimeout, .dataCorrupted, .invalidDataFormat:
            return .medium
        case .serializationFailed, .deserializationFailed, .invalidRequest, .unexpectedResponse:
            return .low
        case .scanningFailed, .dataTooLarge, .requestFailed, .resourceExhausted, .memoryPressure, .queueOverflow:
            return .low
        case .remoteActorUnavailable, .actorSystemFailure, .distributedCallFailed:
            return .medium
        case .serviceDiscoveryFailed, .characteristicDiscoveryFailed:
            return .low
        case .characteristicNotReadable, .characteristicNotWritable, .characteristicNotNotifiable:
            return .low
        case .bluetoothUnauthorized, .certificateInvalid:
            return .high
        }
    }
    
    /// Whether this error is recoverable
    public var isRecoverable: Bool {
        switch self {
        case .bluetoothUnavailable, .platformNotSupported, .osVersionNotSupported, .hardwareNotSupported:
            return false
        case .bluetoothPoweredOff, .bluetoothUnauthorized:
            return true // User can fix these
        case .connectionFailed, .connectionLost, .deviceNotFound, .communicationTimeout:
            return true // Can retry
        case .authenticationFailed, .encryptionFailed, .decryptionFailed:
            return true // Can re-authenticate
        case .serializationFailed, .deserializationFailed, .dataCorrupted, .invalidDataFormat:
            return false // Data issues
        case .serviceNotFound, .characteristicNotFound:
            return false // Device capabilities
        default:
            return true // Most errors are recoverable
        }
    }
    
    /// Suggested recovery actions
    public var recoveryActions: [RecoveryAction] {
        switch self {
        case .bluetoothPoweredOff:
            return [.enableBluetooth]
        case .bluetoothUnauthorized:
            return [.requestPermission]
        case .connectionFailed, .connectionLost:
            return [.retry, .reconnect]
        case .deviceNotFound:
            return [.scan, .retry]
        case .communicationTimeout, .responseTimeout:
            return [.retry, .increaseTimeout]
        case .authenticationFailed:
            return [.reauthenticate, .checkCredentials]
        case .memoryPressure:
            return [.releaseResources, .restartApp]
        case .queueOverflow:
            return [.reduceThroughput, .increaseBufferSize]
        default:
            return [.retry]
        }
    }
}

/// Error severity levels
public enum ErrorSeverity: Sendable, Codable, CaseIterable {
    case low
    case medium
    case high
    case critical
    
    public var description: String {
        switch self {
        case .low:
            return "Low"
        case .medium:
            return "Medium"
        case .high:
            return "High"
        case .critical:
            return "Critical"
        }
    }
}

/// Suggested recovery actions
public enum RecoveryAction: Sendable, Codable, CaseIterable {
    case retry
    case reconnect
    case scan
    case enableBluetooth
    case requestPermission
    case reauthenticate
    case checkCredentials
    case releaseResources
    case restartApp
    case increaseTimeout
    case reduceThroughput
    case increaseBufferSize
    case contactSupport
    
    public var description: String {
        switch self {
        case .retry:
            return "Retry the operation"
        case .reconnect:
            return "Reconnect to the device"
        case .scan:
            return "Scan for devices again"
        case .enableBluetooth:
            return "Enable Bluetooth"
        case .requestPermission:
            return "Request Bluetooth permission"
        case .reauthenticate:
            return "Re-authenticate with the device"
        case .checkCredentials:
            return "Check authentication credentials"
        case .releaseResources:
            return "Release unused resources"
        case .restartApp:
            return "Restart the application"
        case .increaseTimeout:
            return "Increase timeout duration"
        case .reduceThroughput:
            return "Reduce data throughput"
        case .increaseBufferSize:
            return "Increase buffer size"
        case .contactSupport:
            return "Contact support"
        }
    }
}

/// Error context for better debugging
public struct ErrorContext: Sendable, Codable {
    public let timestamp: Date
    public let operation: String
    public let deviceId: String?
    public let additionalInfo: [String: String]
    
    public init(
        operation: String,
        deviceId: String? = nil,
        additionalInfo: [String: String] = [:]
    ) {
        self.timestamp = Date()
        self.operation = operation
        self.deviceId = deviceId
        self.additionalInfo = additionalInfo
    }
}

/// Enhanced error with context
public struct BleuErrorWithContext: Error, Sendable {
    public let error: BleuError
    public let context: ErrorContext
    public let underlyingError: Error?
    
    public init(
        error: BleuError,
        context: ErrorContext,
        underlyingError: Error? = nil
    ) {
        self.error = error
        self.context = context
        self.underlyingError = underlyingError
    }
    
    public var localizedDescription: String {
        var description = error.localizedDescription
        description += " (Operation: \(context.operation)"
        
        if let deviceId = context.deviceId {
            description += ", Device: \(deviceId)"
        }
        
        if let underlying = underlyingError {
            description += ", Underlying: \(underlying.localizedDescription)"
        }
        
        description += ")"
        return description
    }
}

/// Actor isolation errors
public enum ActorIsolationError: Error, Sendable {
    case isolationViolation
    case deadlock
    case stateCorruption
    
    public var localizedDescription: String {
        switch self {
        case .isolationViolation:
            return "Actor isolation violation detected"
        case .deadlock:
            return "Potential deadlock detected"
        case .stateCorruption:
            return "Actor state corruption detected"
        }
    }
}