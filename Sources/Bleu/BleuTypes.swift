import Foundation
import CoreBluetooth
import Distributed

/// Sendable types for Actor communication
public struct DeviceIdentifier: Sendable, Hashable, Codable {
    public let uuid: UUID
    public let name: String?
    
    public init(uuid: UUID, name: String? = nil) {
        self.uuid = uuid
        self.name = name
    }
}

/// Service configuration
public struct ServiceConfiguration: Sendable, Codable {
    public let serviceUUID: UUID
    public let characteristicUUIDs: [UUID]
    public let isPrimary: Bool
    
    public init(serviceUUID: UUID, characteristicUUIDs: [UUID], isPrimary: Bool = true) {
        self.serviceUUID = serviceUUID
        self.characteristicUUIDs = characteristicUUIDs
        self.isPrimary = isPrimary
    }
}

/// Request/Response data structure
public struct BleuMessage: Sendable, Codable {
    public let id: UUID
    public let serviceUUID: UUID
    public let characteristicUUID: UUID
    public let data: Data?
    public let timestamp: Date
    public let method: RequestMethod
    
    public init(
        serviceUUID: UUID,
        characteristicUUID: UUID,
        data: Data? = nil,
        method: RequestMethod = .read
    ) {
        self.id = UUID()
        self.serviceUUID = serviceUUID
        self.characteristicUUID = characteristicUUID
        self.data = data
        self.timestamp = Date()
        self.method = method
    }
}

/// Communication methods
public enum RequestMethod: Sendable, Codable, CaseIterable {
    case read
    case write
    case writeWithoutResponse
    case notify
    case indicate
    
    public var properties: CBCharacteristicProperties {
        switch self {
        case .read:
            return .read
        case .write:
            return .write
        case .writeWithoutResponse:
            return .writeWithoutResponse
        case .notify:
            return .notify
        case .indicate:
            return .indicate
        }
    }
    
    public var permissions: CBAttributePermissions {
        switch self {
        case .read, .notify, .indicate:
            return .readable
        case .write, .writeWithoutResponse:
            return .writeable
        }
    }
}

/// Advertising data
public struct AdvertisementData: Sendable, Codable {
    public let localName: String?
    public let serviceUUIDs: [UUID]
    public let manufacturerData: Data?
    public let serviceData: [UUID: Data]
    public let txPowerLevel: Int?
    
    public init(
        localName: String? = nil,
        serviceUUIDs: [UUID] = [],
        manufacturerData: Data? = nil,
        serviceData: [UUID: Data] = [:],
        txPowerLevel: Int? = nil
    ) {
        self.localName = localName
        self.serviceUUIDs = serviceUUIDs
        self.manufacturerData = manufacturerData
        self.serviceData = serviceData
        self.txPowerLevel = txPowerLevel
    }
}

/// Connection options
public struct ConnectionOptions: Sendable, Codable {
    public let notifyOnConnection: Bool
    public let notifyOnDisconnection: Bool
    public let notifyOnNotification: Bool
    public let timeout: TimeInterval
    
    public init(
        notifyOnConnection: Bool = true,
        notifyOnDisconnection: Bool = true,
        notifyOnNotification: Bool = true,
        timeout: TimeInterval = 30.0
    ) {
        self.notifyOnConnection = notifyOnConnection
        self.notifyOnDisconnection = notifyOnDisconnection
        self.notifyOnNotification = notifyOnNotification
        self.timeout = timeout
    }
}

/// Device information
public struct DeviceInfo: Sendable, Codable {
    public let identifier: DeviceIdentifier
    public let rssi: Int?
    public let advertisementData: AdvertisementData
    public let isConnectable: Bool
    public let lastSeen: Date
    
    public init(
        identifier: DeviceIdentifier,
        rssi: Int? = nil,
        advertisementData: AdvertisementData,
        isConnectable: Bool = true,
        lastSeen: Date = Date()
    ) {
        self.identifier = identifier
        self.rssi = rssi
        self.advertisementData = advertisementData
        self.isConnectable = isConnectable
        self.lastSeen = lastSeen
    }
}