import Foundation
import CoreBluetooth
import ActorRuntime

// MARK: - Core Types

/// Represents a discovered BLE peripheral
public struct DiscoveredPeripheral: Sendable, Codable {
    public let id: UUID
    public let name: String?
    public let rssi: Int
    public let advertisementData: AdvertisementData
    public let discoveredAt: Date
    
    public init(id: UUID, name: String?, rssi: Int, advertisementData: AdvertisementData) {
        self.id = id
        self.name = name
        self.rssi = rssi
        self.advertisementData = advertisementData
        self.discoveredAt = Date()
    }
}

/// Advertisement data from a peripheral
public struct AdvertisementData: Sendable, Codable {
    public let localName: String?
    public let manufacturerData: Data?
    public let serviceUUIDs: [UUID]
    public let serviceData: [UUID: Data]
    public let txPowerLevel: Int?
    public let isConnectable: Bool
    
    public init(
        localName: String? = nil,
        manufacturerData: Data? = nil,
        serviceUUIDs: [UUID] = [],
        serviceData: [UUID: Data] = [:],
        txPowerLevel: Int? = nil,
        isConnectable: Bool = true
    ) {
        self.localName = localName
        self.manufacturerData = manufacturerData
        self.serviceUUIDs = serviceUUIDs
        self.serviceData = serviceData
        self.txPowerLevel = txPowerLevel
        self.isConnectable = isConnectable
    }
    
    // Convert from CoreBluetooth advertisement dictionary
    public init(from dictionary: [String: Any]) {
        self.localName = dictionary[CBAdvertisementDataLocalNameKey] as? String
        self.manufacturerData = dictionary[CBAdvertisementDataManufacturerDataKey] as? Data
        
        if let cbUUIDs = dictionary[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] {
            // Convert CBUUID to UUID safely, using deterministic UUID for short UUIDs
            self.serviceUUIDs = cbUUIDs.map { cbUUID in
                UUID(uuidString: cbUUID.uuidString) ?? UUID.deterministic(from: cbUUID.uuidString)
            }
        } else {
            self.serviceUUIDs = []
        }
        
        if let cbServiceData = dictionary[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] {
            var serviceDataDict: [UUID: Data] = [:]
            for (cbUUID, data) in cbServiceData {
                // Convert CBUUID to UUID safely
                let uuid = UUID(uuidString: cbUUID.uuidString) ?? UUID.deterministic(from: cbUUID.uuidString)
                serviceDataDict[uuid] = data
            }
            self.serviceData = serviceDataDict
        } else {
            self.serviceData = [:]
        }
        
        self.txPowerLevel = dictionary[CBAdvertisementDataTxPowerLevelKey] as? Int
        self.isConnectable = (dictionary[CBAdvertisementDataIsConnectable] as? Bool) ?? true
    }
}

/// Service metadata for BLE service creation
public struct ServiceMetadata: Sendable, Codable {
    public let uuid: UUID
    public let isPrimary: Bool
    public let characteristics: [CharacteristicMetadata]
    
    public init(uuid: UUID, isPrimary: Bool = true, characteristics: [CharacteristicMetadata]) {
        self.uuid = uuid
        self.isPrimary = isPrimary
        self.characteristics = characteristics
    }
}

/// Characteristic metadata for BLE characteristic creation
public struct CharacteristicMetadata: Sendable, Codable {
    public let uuid: UUID
    public let properties: CharacteristicProperties
    public let permissions: CharacteristicPermissions
    public let descriptors: [DescriptorMetadata]
    
    public init(
        uuid: UUID,
        properties: CharacteristicProperties,
        permissions: CharacteristicPermissions,
        descriptors: [DescriptorMetadata] = []
    ) {
        self.uuid = uuid
        self.properties = properties
        self.permissions = permissions
        self.descriptors = descriptors
    }
}

/// Descriptor metadata for BLE descriptor creation
public struct DescriptorMetadata: Sendable, Codable {
    public let uuid: UUID
    public let value: Data?
    
    public init(uuid: UUID, value: Data? = nil) {
        self.uuid = uuid
        self.value = value
    }
}

/// Characteristic properties
public struct CharacteristicProperties: OptionSet, Sendable, Codable {
    public let rawValue: UInt
    
    public init(rawValue: UInt) {
        self.rawValue = rawValue
    }
    
    public static let broadcast = CharacteristicProperties(rawValue: 1 << 0)
    public static let read = CharacteristicProperties(rawValue: 1 << 1)
    public static let writeWithoutResponse = CharacteristicProperties(rawValue: 1 << 2)
    public static let write = CharacteristicProperties(rawValue: 1 << 3)
    public static let notify = CharacteristicProperties(rawValue: 1 << 4)
    public static let indicate = CharacteristicProperties(rawValue: 1 << 5)
    public static let authenticatedSignedWrites = CharacteristicProperties(rawValue: 1 << 6)
    public static let extendedProperties = CharacteristicProperties(rawValue: 1 << 7)
    
    // Convert to CoreBluetooth properties
    public var cbProperties: CBCharacteristicProperties {
        var props = CBCharacteristicProperties()
        if contains(.broadcast) { props.insert(.broadcast) }
        if contains(.read) { props.insert(.read) }
        if contains(.writeWithoutResponse) { props.insert(.writeWithoutResponse) }
        if contains(.write) { props.insert(.write) }
        if contains(.notify) { props.insert(.notify) }
        if contains(.indicate) { props.insert(.indicate) }
        if contains(.authenticatedSignedWrites) { props.insert(.authenticatedSignedWrites) }
        if contains(.extendedProperties) { props.insert(.extendedProperties) }
        return props
    }
}

/// Characteristic permissions
public struct CharacteristicPermissions: OptionSet, Sendable, Codable {
    public let rawValue: UInt
    
    public init(rawValue: UInt) {
        self.rawValue = rawValue
    }
    
    public static let readable = CharacteristicPermissions(rawValue: 1 << 0)
    public static let writeable = CharacteristicPermissions(rawValue: 1 << 1)
    public static let readEncryptionRequired = CharacteristicPermissions(rawValue: 1 << 2)
    public static let writeEncryptionRequired = CharacteristicPermissions(rawValue: 1 << 3)
    
    // Convert to CoreBluetooth permissions
    public var cbPermissions: CBAttributePermissions {
        var perms = CBAttributePermissions()
        if contains(.readable) { perms.insert(.readable) }
        if contains(.writeable) { perms.insert(.writeable) }
        if contains(.readEncryptionRequired) { perms.insert(.readEncryptionRequired) }
        if contains(.writeEncryptionRequired) { perms.insert(.writeEncryptionRequired) }
        return perms
    }
}

/// Connection state
public enum ConnectionState: String, Sendable, Codable {
    case disconnected
    case connecting
    case connected
    case disconnecting
}

/// BLE event types for internal communication
public enum BLEEvent: Sendable {
    case stateChanged(CBManagerState)
    case peripheralDiscovered(DiscoveredPeripheral)
    case peripheralConnected(UUID)
    case peripheralDisconnected(UUID, Error?)
    case serviceDiscovered(UUID, [ServiceMetadata])
    case characteristicDiscovered(UUID, UUID, [CharacteristicMetadata])
    case characteristicValueUpdated(UUID, UUID, UUID, Data?)
    case characteristicWriteCompleted(UUID, UUID, UUID, Error?)
    case notificationStateChanged(UUID, UUID, UUID, Bool)
    case centralSubscribed(UUID, UUID, UUID)
    case centralUnsubscribed(UUID, UUID, UUID)
    case readRequestReceived(UUID, UUID, UUID)
    case writeRequestReceived(UUID, UUID, UUID, Data)
}

/// Connection options
public struct ConnectionOptions: Sendable, Codable {
    public let autoReconnect: Bool
    public let connectionTimeout: TimeInterval
    public let maxRetries: Int
    public let retryDelay: TimeInterval
    
    public init(
        autoReconnect: Bool = true,
        connectionTimeout: TimeInterval = 10.0,
        maxRetries: Int = 3,
        retryDelay: TimeInterval = 1.0
    ) {
        self.autoReconnect = autoReconnect
        self.connectionTimeout = connectionTimeout
        self.maxRetries = maxRetries
        self.retryDelay = retryDelay
    }
}

// MARK: - Invocation Envelopes
// Note: InvocationEnvelope and ResponseEnvelope are now provided by ActorRuntime
// Import ActorRuntime to use these types

