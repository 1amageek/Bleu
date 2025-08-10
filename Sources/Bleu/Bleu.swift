// MARK: - Bleu v2
//
// Modern Bluetooth Low Energy framework using Swift Concurrency and Distributed Actors
// 
// © 2024 Bleu Contributors
// Licensed under MIT License

import Foundation
import CoreBluetooth
import Distributed

/// Version information
public enum BleuVersion {
    public static let current = "2.0.0"
    public static let swiftRequirement = "6.1"
    public static let platforms = ["iOS 18.0+", "macOS 15.0+", "watchOS 11.0+", "tvOS 18.0+"]
}

/// Main namespace and convenience APIs
public enum Bleu {
    
    // MARK: - Quick Start APIs
    
    /// Create a BLE server (peripheral) with basic configuration
    public static func server(
        serviceUUID: UUID,
        characteristicUUIDs: [UUID],
        localName: String? = nil
    ) async throws -> BleuServer {
        return try await BleuServer(
            serviceUUID: serviceUUID,
            characteristicUUIDs: characteristicUUIDs,
            localName: localName
        )
    }
    
    /// Create a BLE client (central) with service filtering
    public static func client(serviceUUIDs: [UUID] = []) async throws -> BleuClient {
        return try await BleuClient(serviceUUIDs: serviceUUIDs)
    }
    
    /// Discover nearby BLE devices
    public static func discover(
        serviceUUIDs: [UUID] = [],
        timeout: TimeInterval = 10.0
    ) async throws -> [DeviceInfo] {
        return try await BluetoothActor.shared.discoverPeripherals(
            serviceUUIDs: serviceUUIDs,
            timeout: timeout
        )
    }
    
    /// Monitor Bluetooth state changes
    public static func monitorBluetoothState() -> AsyncStream<CBManagerState> {
        AsyncStream { continuation in
            Task {
                let observerId = await BluetoothActor.shared.addStateObserver { state in
                    continuation.yield(state)
                }
                
                continuation.onTermination = { _ in
                    Task {
                        await BluetoothActor.shared.removeStateObserver(id: observerId)
                    }
                }
            }
        }
    }
    
    /// Check if Bluetooth is available
    public static var isBluetoothAvailable: Bool {
        get async {
            return await BluetoothActor.shared.isBluetoothAvailable
        }
    }
}

// MARK: - Global convenience functions

/// Create a simple BLE server
public func createBleuServer(
    serviceUUID: UUID,
    characteristicUUIDs: [UUID],
    localName: String? = nil
) async throws -> BleuServer {
    return try await Bleu.server(
        serviceUUID: serviceUUID,
        characteristicUUIDs: characteristicUUIDs,
        localName: localName
    )
}

/// Create a simple BLE client  
public func createBleuClient(serviceUUIDs: [UUID] = []) async throws -> BleuClient {
    return try await Bleu.client(serviceUUIDs: serviceUUIDs)
}

/// Discover BLE devices with timeout
public func discoverBleuDevices(
    serviceUUIDs: [UUID] = [],
    timeout: TimeInterval = 10.0
) async throws -> [DeviceInfo] {
    return try await Bleu.discover(serviceUUIDs: serviceUUIDs, timeout: timeout)
}

// MARK: - Actor System Access

extension BluetoothActor {
    /// Access the underlying distributed actor system
    public var actorSystem: BLEActorSystem {
        return distributedActorSystem
    }
}

// MARK: - Backward Compatibility Shims (if needed)

#if DEBUG
extension Bleu {
    /// Debug information about active actors
    public static func debugInfo() async -> String {
        let peripherals = await BluetoothActor.shared.getAllActivePeripheralActors()
        let centrals = await BluetoothActor.shared.getAllActiveCentralActors()
        let bluetoothState = await BluetoothActor.shared.currentBluetoothState
        
        return """
        Bleu Debug Info:
        - Active Peripheral Actors: \(peripherals.count)
        - Active Central Actors: \(centrals.count)
        - Bluetooth State: \(bluetoothState)
        - Version: \(BleuVersion.current)
        """
    }
}
#endif

// MARK: - Type-safe Remote Procedure Call Support

/// Protocol for type-safe remote procedure calls
public protocol RemoteProcedure: Sendable, Codable {
    associatedtype Response: Sendable, Codable
    
    var serviceUUID: UUID { get }
    var characteristicUUID: UUID { get }
    var method: RequestMethod { get }
}

/// Extension to provide default implementations
extension RemoteProcedure {
    public var method: RequestMethod { .write }
}

// MARK: - High-level Communication Patterns

/// Server-side communication helper
public actor BleuServer {
    private let peripheralActor: PeripheralActor
    
    public init(
        serviceUUID: UUID,
        characteristicUUIDs: [UUID],
        localName: String? = nil
    ) async throws {
        self.peripheralActor = try await BluetoothActor.shared.quickPeripheral(
            serviceUUID: serviceUUID,
            characteristicUUIDs: characteristicUUIDs,
            localName: localName
        )
        
        try await peripheralActor.startAdvertising()
    }
    
    public func handleRequests<T: RemoteProcedure>(
        ofType type: T.Type,
        handler: @escaping @Sendable (T) async throws -> T.Response
    ) async {
        await peripheralActor.setRequestHandler(characteristicUUID: T().characteristicUUID) { message in
            guard let requestData = message.data,
                  let request = try? JSONDecoder().decode(T.self, from: requestData) else {
                throw BleuError.deserializationFailed
            }
            
            let response = try await handler(request)
            return try JSONEncoder().encode(response)
        }
    }
    
    public func broadcast<T: Sendable & Codable>(
        _ notification: T,
        characteristicUUID: UUID
    ) async throws {
        let data = try JSONEncoder().encode(notification)
        try await peripheralActor.sendNotification(
            characteristicUUID: characteristicUUID,
            data: data
        )
    }
    
    public func shutdown() async {
        try? await peripheralActor.shutdown()
    }
}

/// Client-side communication helper
public actor BleuClient {
    private let centralActor: CentralActor
    private var connectedDevices: [DeviceIdentifier: PeripheralActor] = [:]
    
    public init(serviceUUIDs: [UUID] = []) async throws {
        self.centralActor = try await BluetoothActor.shared.quickCentral(serviceUUIDs: serviceUUIDs)
    }
    
    public func discover(timeout: TimeInterval = 10.0) async throws -> [DeviceInfo] {
        return try await centralActor.scanForPeripherals(timeout: timeout)
    }
    
    public func connect(to device: DeviceInfo) async throws -> PeripheralActor {
        let peripheralActor = try await centralActor.connect(to: device.identifier)
        connectedDevices[device.identifier] = peripheralActor
        return peripheralActor
    }
    
    public func sendRequest<T: RemoteProcedure>(
        _ request: T,
        to deviceId: DeviceIdentifier
    ) async throws -> T.Response {
        let requestData = try JSONEncoder().encode(request)
        let message = BleuMessage(
            serviceUUID: request.serviceUUID,
            characteristicUUID: request.characteristicUUID,
            data: requestData,
            method: request.method
        )
        
        guard let responseData = try await centralActor.sendRequest(to: deviceId, message: message) else {
            throw BleuError.invalidRequest
        }
        
        return try JSONDecoder().decode(T.Response.self, from: responseData)
    }
    
    public func subscribe<T: Sendable & Codable>(
        to type: T.Type,
        from deviceId: DeviceIdentifier,
        characteristicUUID: UUID
    ) async throws -> AsyncStream<T> {
        let dataStream = try await centralActor.subscribeToNotifications(
            from: deviceId,
            characteristicUUID: characteristicUUID
        )
        
        return AsyncStream { continuation in
            Task {
                for await data in dataStream {
                    if let decoded = try? JSONDecoder().decode(T.self, from: data) {
                        continuation.yield(decoded)
                    }
                }
                continuation.finish()
            }
        }
    }
    
    public func disconnect(from deviceId: DeviceIdentifier) async throws {
        try await centralActor.disconnect(from: deviceId)
        connectedDevices.removeValue(forKey: deviceId)
    }
    
    public func shutdown() async {
        for deviceId in connectedDevices.keys {
            try? await disconnect(from: deviceId)
        }
        try? await centralActor.shutdown()
    }
}

// MARK: - Example Remote Procedures

/// Example: Get device information request
public struct GetDeviceInfoRequest: RemoteProcedure {
    public let serviceUUID = UUID(uuidString: "12345678-1234-5678-9ABC-123456789ABC")!
    public let characteristicUUID = UUID(uuidString: "87654321-4321-8765-CBA9-987654321CBA")!
    
    public struct Response: Sendable, Codable {
        public let deviceName: String
        public let firmwareVersion: String
        public let batteryLevel: Int
        
        public init(deviceName: String, firmwareVersion: String, batteryLevel: Int) {
            self.deviceName = deviceName
            self.firmwareVersion = firmwareVersion
            self.batteryLevel = batteryLevel
        }
    }
    
    public init() {}
}

/// Example: Send data request
public struct SendDataRequest: RemoteProcedure {
    public let serviceUUID = UUID(uuidString: "12345678-1234-5678-9ABC-123456789ABC")!
    public let characteristicUUID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    
    public let data: Data
    
    public struct Response: Sendable, Codable {
        public let success: Bool
        public let message: String
        
        public init(success: Bool, message: String) {
            self.success = success
            self.message = message
        }
    }
    
    public init(data: Data) {
        self.data = data
    }
}

/// Example: Sensor data notification
public struct SensorDataNotification: Sendable, Codable {
    public let temperature: Double
    public let humidity: Double
    public let timestamp: Date
    
    public init(temperature: Double, humidity: Double, timestamp: Date = Date()) {
        self.temperature = temperature
        self.humidity = humidity
        self.timestamp = timestamp
    }
}