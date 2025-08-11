import Foundation

/// Errors that can occur in Bleu framework
public enum BleuError: Error, Codable, LocalizedError {
    case bluetoothUnavailable
    case bluetoothUnauthorized
    case bluetoothPoweredOff
    case peripheralNotFound(UUID)
    case serviceNotFound(UUID)
    case characteristicNotFound(UUID)
    case connectionTimeout
    case connectionFailed(String)
    case disconnected
    case incompatibleVersion(detected: Int, required: Int)
    case invalidData
    case quotaExceeded
    case operationNotSupported
    case methodNotSupported(String)
    case actorNotFound(UUID)
    case rpcFailed(String)
    
    public var errorDescription: String? {
        switch self {
        case .bluetoothUnavailable:
            return "Bluetooth is not available on this device"
        case .bluetoothUnauthorized:
            return "Bluetooth access is not authorized"
        case .bluetoothPoweredOff:
            return "Bluetooth is powered off"
        case .peripheralNotFound(let uuid):
            return "Peripheral with ID \(uuid) not found"
        case .serviceNotFound(let uuid):
            return "Service with UUID \(uuid) not found"
        case .characteristicNotFound(let uuid):
            return "Characteristic with UUID \(uuid) not found"
        case .connectionTimeout:
            return "Connection timed out"
        case .connectionFailed(let reason):
            return "Connection failed: \(reason)"
        case .disconnected:
            return "Peripheral disconnected"
        case .incompatibleVersion(let detected, let required):
            return "Incompatible version: detected \(detected), required \(required)"
        case .invalidData:
            return "Invalid data received"
        case .quotaExceeded:
            return "Operation quota exceeded"
        case .operationNotSupported:
            return "Operation not supported"
        case .methodNotSupported(let method):
            return "Method '\(method)' not supported"
        case .actorNotFound(let uuid):
            return "Actor with ID \(uuid) not found"
        case .rpcFailed(let reason):
            return "RPC failed: \(reason)"
        }
    }
    
    // Codable conformance
    private enum CodingKeys: String, CodingKey {
        case type
        case uuid
        case string
        case detected
        case required
    }
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        
        switch type {
        case "bluetoothUnavailable":
            self = .bluetoothUnavailable
        case "bluetoothUnauthorized":
            self = .bluetoothUnauthorized
        case "bluetoothPoweredOff":
            self = .bluetoothPoweredOff
        case "peripheralNotFound":
            let uuid = try container.decode(UUID.self, forKey: .uuid)
            self = .peripheralNotFound(uuid)
        case "serviceNotFound":
            let uuid = try container.decode(UUID.self, forKey: .uuid)
            self = .serviceNotFound(uuid)
        case "characteristicNotFound":
            let uuid = try container.decode(UUID.self, forKey: .uuid)
            self = .characteristicNotFound(uuid)
        case "connectionTimeout":
            self = .connectionTimeout
        case "connectionFailed":
            let reason = try container.decode(String.self, forKey: .string)
            self = .connectionFailed(reason)
        case "disconnected":
            self = .disconnected
        case "incompatibleVersion":
            let detected = try container.decode(Int.self, forKey: .detected)
            let required = try container.decode(Int.self, forKey: .required)
            self = .incompatibleVersion(detected: detected, required: required)
        case "invalidData":
            self = .invalidData
        case "quotaExceeded":
            self = .quotaExceeded
        case "operationNotSupported":
            self = .operationNotSupported
        case "methodNotSupported":
            let method = try container.decode(String.self, forKey: .string)
            self = .methodNotSupported(method)
        case "actorNotFound":
            let uuid = try container.decode(UUID.self, forKey: .uuid)
            self = .actorNotFound(uuid)
        case "rpcFailed":
            let reason = try container.decode(String.self, forKey: .string)
            self = .rpcFailed(reason)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unknown error type")
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        
        switch self {
        case .bluetoothUnavailable:
            try container.encode("bluetoothUnavailable", forKey: .type)
        case .bluetoothUnauthorized:
            try container.encode("bluetoothUnauthorized", forKey: .type)
        case .bluetoothPoweredOff:
            try container.encode("bluetoothPoweredOff", forKey: .type)
        case .peripheralNotFound(let uuid):
            try container.encode("peripheralNotFound", forKey: .type)
            try container.encode(uuid, forKey: .uuid)
        case .serviceNotFound(let uuid):
            try container.encode("serviceNotFound", forKey: .type)
            try container.encode(uuid, forKey: .uuid)
        case .characteristicNotFound(let uuid):
            try container.encode("characteristicNotFound", forKey: .type)
            try container.encode(uuid, forKey: .uuid)
        case .connectionTimeout:
            try container.encode("connectionTimeout", forKey: .type)
        case .connectionFailed(let reason):
            try container.encode("connectionFailed", forKey: .type)
            try container.encode(reason, forKey: .string)
        case .disconnected:
            try container.encode("disconnected", forKey: .type)
        case .incompatibleVersion(let detected, let required):
            try container.encode("incompatibleVersion", forKey: .type)
            try container.encode(detected, forKey: .detected)
            try container.encode(required, forKey: .required)
        case .invalidData:
            try container.encode("invalidData", forKey: .type)
        case .quotaExceeded:
            try container.encode("quotaExceeded", forKey: .type)
        case .operationNotSupported:
            try container.encode("operationNotSupported", forKey: .type)
        case .methodNotSupported(let method):
            try container.encode("methodNotSupported", forKey: .type)
            try container.encode(method, forKey: .string)
        case .actorNotFound(let uuid):
            try container.encode("actorNotFound", forKey: .type)
            try container.encode(uuid, forKey: .uuid)
        case .rpcFailed(let reason):
            try container.encode("rpcFailed", forKey: .type)
            try container.encode(reason, forKey: .string)
        }
    }
}