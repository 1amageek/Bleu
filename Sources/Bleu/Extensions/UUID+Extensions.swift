import Foundation
import CryptoKit

extension UUID {
    /// Bleu namespace for UUID generation
    public static let bleuNamespace: UUID = {
        // This is a constant UUID, so it's safe to use a fallback
        UUID(uuidString: "6E400001-B5A3-F393-E0A9-E50E24DCCA9E") ?? UUID()
    }()
    
    /// Generate a deterministic UUID from a string and namespace
    public static func deterministic(from string: String, namespace: UUID = bleuNamespace) -> UUID {
        // Create name data
        let nameData = string.data(using: .utf8)!
        
        // Combine namespace and name
        var data = Data()
        data.append(contentsOf: withUnsafeBytes(of: namespace.uuid) { Data($0) })
        data.append(nameData)
        
        // Generate SHA1 hash
        let hash = Insecure.SHA1.hash(data: data)
        let hashData = Data(hash)
        
        // Create UUID from hash (UUID version 5)
        var uuid = uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        hashData.withUnsafeBytes { bytes in
            let buffer = bytes.bindMemory(to: UInt8.self)
            for i in 0..<16 {
                withUnsafeMutableBytes(of: &uuid) { uuidBytes in
                    uuidBytes[i] = buffer[i]
                }
            }
        }
        
        // Set version (5) and variant bits
        uuid.6 = (uuid.6 & 0x0F) | 0x50  // Version 5
        uuid.8 = (uuid.8 & 0x3F) | 0x80  // Variant 10
        
        return UUID(uuid: uuid)
    }
    
    /// Generate a service UUID for a given actor type
    public static func serviceUUID<T>(for type: T.Type) -> UUID {
        let typeName = String(describing: type)
        return deterministic(from: "\(typeName).BLEService")
    }
    
    /// Generate a characteristic UUID for a given method in an actor type
    public static func characteristicUUID<T>(for method: String, in type: T.Type) -> UUID {
        let typeName = String(describing: type)
        let serviceUUID = self.serviceUUID(for: type)
        return deterministic(from: "\(typeName).\(method)", namespace: serviceUUID)
    }
    
    /// Convert to/from Data
    public var data: Data {
        return withUnsafeBytes(of: self.uuid) { Data($0) }
    }
    
    public init?(data: Data) {
        guard data.count == 16 else { return nil }
        
        var uuid = uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
        data.withUnsafeBytes { bytes in
            let buffer = bytes.bindMemory(to: UInt8.self)
            for i in 0..<16 {
                withUnsafeMutableBytes(of: &uuid) { uuidBytes in
                    uuidBytes[i] = buffer[i]
                }
            }
        }
        
        self.init(uuid: uuid)
    }
}