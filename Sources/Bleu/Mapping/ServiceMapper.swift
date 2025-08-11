import Foundation
import CoreBluetooth

/// Maps distributed actor methods to BLE services and characteristics
public struct ServiceMapper {
    
    /// Method information extracted from distributed actor
    public struct MethodInfo {
        public let name: String
        public let characteristicUUID: UUID
        public let properties: CharacteristicProperties
        public let permissions: CharacteristicPermissions
    }
    
    /// Create service metadata from a PeripheralActor type
    public static func createServiceMetadata<T: PeripheralActor>(from type: T.Type) -> ServiceMetadata {
        let serviceUUID = UUID.serviceUUID(for: type)
        let methods = extractDistributedMethods(from: type)
        
        let characteristics = methods.map { method in
            CharacteristicMetadata(
                uuid: method.characteristicUUID,
                properties: method.properties,
                permissions: method.permissions
            )
        }
        
        // Add a special RPC characteristic for general method calls
        let rpcCharacteristic = CharacteristicMetadata(
            uuid: UUID.characteristicUUID(for: "__rpc__", in: type),
            properties: [.write, .notify],
            permissions: [.writeable, .readable]
        )
        
        return ServiceMetadata(
            uuid: serviceUUID,
            isPrimary: true,
            characteristics: characteristics + [rpcCharacteristic]
        )
    }
    
    /// Extract distributed methods from an actor type using Mirror
    public static func extractDistributedMethods<T: PeripheralActor>(from type: T.Type) -> [MethodInfo] {
        var methods: [MethodInfo] = []
        
        // Use Mirror to inspect the type
        // Note: In a real implementation, we would need to use more sophisticated
        // reflection or code generation to extract distributed methods
        
        // For now, we'll define a standard set of characteristics based on common patterns
        
        // Standard read characteristic (for getter-like methods)
        methods.append(MethodInfo(
            name: "read",
            characteristicUUID: UUID.characteristicUUID(for: "read", in: type),
            properties: [.read, .notify],
            permissions: [.readable]
        ))
        
        // Standard write characteristic (for setter-like methods)
        methods.append(MethodInfo(
            name: "write",
            characteristicUUID: UUID.characteristicUUID(for: "write", in: type),
            properties: [.write, .writeWithoutResponse],
            permissions: [.writeable]
        ))
        
        // Standard command characteristic (for action methods)
        methods.append(MethodInfo(
            name: "command",
            characteristicUUID: UUID.characteristicUUID(for: "command", in: type),
            properties: [.write],
            permissions: [.writeable]
        ))
        
        // Standard subscription characteristic (for AsyncStream methods)
        methods.append(MethodInfo(
            name: "subscribe",
            characteristicUUID: UUID.characteristicUUID(for: "subscribe", in: type),
            properties: [.notify, .indicate],
            permissions: [.readable]
        ))
        
        return methods
    }
    
    /// Determine BLE properties from method signature
    public static func determineProperties(for method: String) -> CharacteristicProperties {
        // Analyze method name to determine appropriate BLE properties
        let lowercased = method.lowercased()
        
        if lowercased.contains("subscribe") || lowercased.contains("notify") {
            return [.notify, .indicate]
        } else if lowercased.contains("read") || lowercased.contains("get") {
            return [.read, .notify]
        } else if lowercased.contains("write") || lowercased.contains("set") {
            return [.write, .writeWithoutResponse]
        } else if lowercased.contains("command") || lowercased.contains("execute") {
            return [.write]
        } else {
            // Default to read/write
            return [.read, .write, .notify]
        }
    }
    
    /// Determine BLE permissions from method signature
    public static func determinePermissions(for method: String) -> CharacteristicPermissions {
        let properties = determineProperties(for: method)
        var permissions: CharacteristicPermissions = []
        
        if properties.contains(.read) {
            permissions.insert(.readable)
        }
        if properties.contains(.write) || properties.contains(.writeWithoutResponse) {
            permissions.insert(.writeable)
        }
        
        return permissions
    }
    
    /// Map a method call to the appropriate characteristic UUID
    public static func characteristicUUID<T: PeripheralActor>(
        for method: String,
        in type: T.Type
    ) -> UUID {
        // Special handling for common method patterns
        let normalized = normalizeMethodName(method)
        return UUID.characteristicUUID(for: normalized, in: type)
    }
    
    /// Normalize method names for consistent UUID generation
    private static func normalizeMethodName(_ method: String) -> String {
        // Remove common prefixes/suffixes and parameter info
        var normalized = method
        
        // Remove parameter information (everything after first parenthesis)
        if let parenIndex = normalized.firstIndex(of: "(") {
            normalized = String(normalized[..<parenIndex])
        }
        
        // Remove common async suffixes
        normalized = normalized.replacingOccurrences(of: "Async", with: "")
        
        // Map to standard characteristic types
        let lowercased = normalized.lowercased()
        if lowercased.contains("subscribe") {
            return "subscribe"
        } else if lowercased.contains("read") || lowercased.contains("get") {
            return "read"
        } else if lowercased.contains("write") || lowercased.contains("set") {
            return "write"
        } else if lowercased.contains("command") || lowercased.contains("execute") {
            return "command"
        }
        
        return normalized
    }
}