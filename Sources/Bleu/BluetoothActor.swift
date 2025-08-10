import Foundation
import CoreBluetooth
import Distributed

/// Global actor for managing Bluetooth state and coordination
@globalActor
public actor BluetoothActor: GlobalActor {
    public static let shared = BluetoothActor()
    
    private let _actorSystem = BLEActorSystem()
    private var peripheralActors: [UUID: PeripheralActor] = [:]
    private var centralActors: [UUID: CentralActor] = [:]
    
    // Bluetooth state management
    private var bluetoothState: CBManagerState = .unknown
    private var stateObservers: [UUID: (CBManagerState) -> Void] = [:]
    
    private init() {}
    
    // MARK: - Actor System Management
    
    public var distributedActorSystem: BLEActorSystem {
        return _actorSystem
    }
    
    // MARK: - Bluetooth State Management
    
    public func addStateObserver(id: UUID = UUID(), callback: @escaping (CBManagerState) -> Void) -> UUID {
        stateObservers[id] = callback
        // Immediately call with current state
        callback(bluetoothState)
        return id
    }
    
    public func removeStateObserver(id: UUID) {
        stateObservers.removeValue(forKey: id)
    }
    
    internal func updateBluetoothState(_ state: CBManagerState) {
        bluetoothState = state
        for observer in stateObservers.values {
            observer(state)
        }
    }
    
    public var currentBluetoothState: CBManagerState {
        return bluetoothState
    }
    
    public var isBluetoothAvailable: Bool {
        return bluetoothState == .poweredOn
    }
    
    // MARK: - Actor Management
    
    public func createPeripheralActor(
        configuration: ServiceConfiguration,
        advertisementData: AdvertisementData = AdvertisementData()
    ) async throws -> PeripheralActor {
        guard isBluetoothAvailable else {
            throw BleuError.bluetoothUnavailable
        }
        
        let actor = PeripheralActor(
            actorSystem: _actorSystem,
            configuration: configuration,
            advertisementData: advertisementData
        )
        
        peripheralActors[actor.id] = actor
        return actor
    }
    
    public func createCentralActor(
        serviceUUIDs: [UUID] = [],
        options: ConnectionOptions = ConnectionOptions()
    ) async throws -> CentralActor {
        guard isBluetoothAvailable else {
            throw BleuError.bluetoothUnavailable
        }
        
        let actor = CentralActor(
            actorSystem: _actorSystem,
            serviceUUIDs: serviceUUIDs,
            options: options
        )
        
        centralActors[actor.id] = actor
        return actor
    }
    
    public func destroyPeripheralActor(id: UUID) async {
        if let actor = peripheralActors[id] {
            await actor.shutdown()
            peripheralActors.removeValue(forKey: id)
        }
    }
    
    public func destroyCentralActor(id: UUID) async {
        if let actor = centralActors[id] {
            await actor.shutdown()
            centralActors.removeValue(forKey: id)
        }
    }
    
    // MARK: - Discovery
    
    public func discoverPeripherals(
        serviceUUIDs: [UUID] = [],
        timeout: TimeInterval = 10.0
    ) async throws -> [DeviceInfo] {
        // Create temporary central actor for discovery
        let centralActor = try await createCentralActor(serviceUUIDs: serviceUUIDs)
        defer {
            Task { await destroyCentralActor(id: centralActor.id) }
        }
        
        return try await centralActor.scanForPeripherals(timeout: timeout)
    }
    
    // MARK: - Utility
    
    public var allActivePeripheralActors: [PeripheralActor] {
        return Array(peripheralActors.values)
    }
    
    public var allActiveCentralActors: [CentralActor] {
        return Array(centralActors.values)
    }
    
    // MARK: - Cleanup
    
    public func shutdown() async {
        // Shutdown all actors
        for actor in peripheralActors.values {
            await actor.shutdown()
        }
        for actor in centralActors.values {
            await actor.shutdown()
        }
        
        peripheralActors.removeAll()
        centralActors.removeAll()
        stateObservers.removeAll()
    }
}

// MARK: - Convenience Extensions

extension BluetoothActor {
    
    /// Quick peripheral setup for simple use cases
    public func quickPeripheral(
        serviceUUID: UUID,
        characteristicUUIDs: [UUID],
        localName: String? = nil
    ) async throws -> PeripheralActor {
        let config = ServiceConfiguration(
            serviceUUID: serviceUUID,
            characteristicUUIDs: characteristicUUIDs
        )
        let adData = AdvertisementData(
            localName: localName,
            serviceUUIDs: [serviceUUID]
        )
        return try await createPeripheralActor(
            configuration: config,
            advertisementData: adData
        )
    }
    
    /// Quick central setup for simple use cases
    public func quickCentral(serviceUUIDs: [UUID] = []) async throws -> CentralActor {
        return try await createCentralActor(serviceUUIDs: serviceUUIDs)
    }
}