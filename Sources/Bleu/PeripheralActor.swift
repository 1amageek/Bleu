import Foundation
import CoreBluetooth
import Distributed

/// Distributed actor representing a BLE Peripheral (Server)
public distributed actor PeripheralActor {
    public typealias ActorSystem = BLEActorSystem
    
    private let configuration: ServiceConfiguration
    private let advertisementData: AdvertisementData
    private var peripheralManager: CBPeripheralManager?
    private var delegate: PeripheralDelegate?
    
    // Request handlers
    private var requestHandlers: [UUID: @Sendable (BleuMessage) async throws -> Data?] = [:]
    private var notificationSubscribers: [UUID: Set<CBCentral>] = [:]
    
    // State management
    private var isAdvertising: Bool = false
    private var connectedCentrals: Set<CBCentral> = []
    
    public init(
        actorSystem: ActorSystem,
        configuration: ServiceConfiguration,
        advertisementData: AdvertisementData
    ) {
        self.configuration = configuration
        self.advertisementData = advertisementData
        self.actorSystem = actorSystem
        
        Task { @BluetoothActor in
            await setupPeripheral()
        }
    }
    
    // MARK: - Setup
    
    @BluetoothActor
    private func setupPeripheral() async {
        delegate = PeripheralDelegate(actor: self)
        peripheralManager = CBPeripheralManager(
            delegate: delegate,
            queue: DispatchQueue(label: "com.bleu.peripheral.\(id)")
        )
    }
    
    // MARK: - Distributed Methods
    
    /// Start advertising this peripheral
    public distributed func startAdvertising() async throws {
        guard let peripheralManager = peripheralManager,
              peripheralManager.state == .poweredOn else {
            throw BleuError.bluetoothUnavailable
        }
        
        // Setup services
        try await setupServices()
        
        // Create advertisement data
        var advData: [String: Any] = [:]
        
        if !advertisementData.serviceUUIDs.isEmpty {
            advData[CBAdvertisementDataServiceUUIDsKey] = advertisementData.serviceUUIDs.map { CBUUID(nsuuid: $0) }
        }
        
        if let localName = advertisementData.localName {
            advData[CBAdvertisementDataLocalNameKey] = localName
        }
        
        if let manufacturerData = advertisementData.manufacturerData {
            advData[CBAdvertisementDataManufacturerDataKey] = manufacturerData
        }
        
        // Start advertising
        peripheralManager.startAdvertising(advData)
        isAdvertising = true
    }
    
    /// Stop advertising
    public distributed func stopAdvertising() async throws {
        peripheralManager?.stopAdvertising()
        isAdvertising = false
    }
    
    /// Get current advertising status
    public distributed var advertisingStatus: Bool { get async
        return isAdvertising
    }
    
    /// Get connected centrals
    public distributed var connectedCentrals: [DeviceIdentifier] { get async
        return connectedCentrals.map { central in
            DeviceIdentifier(
                uuid: central.identifier,
                name: nil // CBCentral doesn't provide name
            )
        }
    }
    
    /// Send notification to subscribed centrals
    public distributed func sendNotification(
        characteristicUUID: UUID,
        data: Data,
        to centrals: [DeviceIdentifier]? = nil
    ) async throws {
        guard let peripheralManager = peripheralManager else {
            throw BleuError.bluetoothUnavailable
        }
        
        // Find the characteristic
        guard let characteristic = findCharacteristic(uuid: characteristicUUID) else {
            throw BleuError.characteristicNotFound(characteristicUUID)
        }
        
        // Determine target centrals
        let targetCentrals: [CBCentral]
        if let specificCentrals = centrals {
            let centralIDs = specificCentrals.map { $0.uuid }
            targetCentrals = connectedCentrals.filter { centralIDs.contains($0.identifier) }
        } else {
            targetCentrals = notificationSubscribers[characteristicUUID]?.compactMap { $0 } ?? []
        }
        
        // Send notification
        let success = peripheralManager.updateValue(
            data,
            for: characteristic,
            onSubscribedCentrals: targetCentrals.isEmpty ? nil : targetCentrals
        )
        
        if !success {
            throw BleuError.communicationTimeout
        }
    }
    
    // MARK: - Request Handling
    
    /// Register a handler for incoming requests to a specific characteristic
    public func setRequestHandler(
        characteristicUUID: UUID,
        handler: @escaping @Sendable (BleuMessage) async throws -> Data?
    ) async {
        requestHandlers[characteristicUUID] = handler
    }
    
    /// Remove request handler
    public func removeRequestHandler(characteristicUUID: UUID) async {
        requestHandlers.removeValue(forKey: characteristicUUID)
    }
    
    // MARK: - Internal Methods
    
    private func setupServices() async throws {
        guard let peripheralManager = peripheralManager else {
            throw BleuError.bluetoothUnavailable
        }
        
        // Remove existing services
        peripheralManager.removeAllServices()
        
        // Create service
        let service = CBMutableService(
            type: CBUUID(nsuuid: configuration.serviceUUID),
            primary: configuration.isPrimary
        )
        
        // Create characteristics
        var characteristics: [CBMutableCharacteristic] = []
        for characteristicUUID in configuration.characteristicUUIDs {
            let characteristic = CBMutableCharacteristic(
                type: CBUUID(nsuuid: characteristicUUID),
                properties: [.read, .write, .notify],
                value: nil,
                permissions: [.readable, .writeable]
            )
            characteristics.append(characteristic)
        }
        
        service.characteristics = characteristics
        
        // Add service
        peripheralManager.add(service)
        
        // Wait for service to be added (this would need proper async handling in real implementation)
        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 second
    }
    
    private func findCharacteristic(uuid: UUID) -> CBMutableCharacteristic? {
        guard let peripheralManager = peripheralManager else { return nil }
        
        for service in peripheralManager.services ?? [] {
            guard let characteristics = service.characteristics else { continue }
            for characteristic in characteristics {
                if characteristic.uuid.uuidString == uuid.uuidString {
                    return characteristic as? CBMutableCharacteristic
                }
            }
        }
        return nil
    }
    
    // MARK: - Delegate Communication
    
    internal func handleReadRequest(_ request: CBATTRequest) async {
        guard let characteristicUUID = UUID(uuidString: request.characteristic.uuid.uuidString),
              let handler = requestHandlers[characteristicUUID] else {
            request.value = nil
            peripheralManager?.respond(to: request, withResult: .requestNotSupported)
            return
        }
        
        do {
            let message = BleuMessage(
                serviceUUID: configuration.serviceUUID,
                characteristicUUID: characteristicUUID,
                data: nil,
                method: .read
            )
            
            let responseData = try await handler(message)
            request.value = responseData
            peripheralManager?.respond(to: request, withResult: .success)
        } catch {
            peripheralManager?.respond(to: request, withResult: .unlikelyError)
        }
    }
    
    internal func handleWriteRequests(_ requests: [CBATTRequest]) async {
        for request in requests {
            guard let characteristicUUID = UUID(uuidString: request.characteristic.uuid.uuidString),
                  let handler = requestHandlers[characteristicUUID] else {
                peripheralManager?.respond(to: request, withResult: .requestNotSupported)
                continue
            }
            
            do {
                let message = BleuMessage(
                    serviceUUID: configuration.serviceUUID,
                    characteristicUUID: characteristicUUID,
                    data: request.value,
                    method: .write
                )
                
                _ = try await handler(message)
                peripheralManager?.respond(to: request, withResult: .success)
            } catch {
                peripheralManager?.respond(to: request, withResult: .unlikelyError)
            }
        }
    }
    
    internal func handleSubscription(central: CBCentral, characteristic: CBCharacteristic) async {
        guard let characteristicUUID = UUID(uuidString: characteristic.uuid.uuidString) else {
            return
        }
        
        if notificationSubscribers[characteristicUUID] == nil {
            notificationSubscribers[characteristicUUID] = Set()
        }
        notificationSubscribers[characteristicUUID]?.insert(central)
        connectedCentrals.insert(central)
    }
    
    internal func handleUnsubscription(central: CBCentral, characteristic: CBCharacteristic) async {
        guard let characteristicUUID = UUID(uuidString: characteristic.uuid.uuidString) else {
            return
        }
        
        notificationSubscribers[characteristicUUID]?.remove(central)
        
        // Check if central has any active subscriptions
        let hasActiveSubscriptions = notificationSubscribers.values.contains { subscribers in
            subscribers.contains(central)
        }
        
        if !hasActiveSubscriptions {
            connectedCentrals.remove(central)
        }
    }
    
    internal func handleServiceAdded(service: CBService, error: Error?) async {
        if let error = error {
            print("Failed to add service \(service.uuid): \(error)")
        } else {
            print("Successfully added service: \(service.uuid)")
        }
    }
    
    internal func handleAdvertisingStarted(error: Error?) async {
        if let error = error {
            print("Failed to start advertising: \(error)")
            isAdvertising = false
        } else {
            print("Started advertising successfully")
            isAdvertising = true
        }
    }
    
    // MARK: - Lifecycle
    
    public distributed func shutdown() async {
        await stopAdvertising()
        peripheralManager?.removeAllServices()
        peripheralManager = nil
        delegate = nil
        requestHandlers.removeAll()
        notificationSubscribers.removeAll()
        connectedCentrals.removeAll()
    }
}

// MARK: - Peripheral Delegate

private class PeripheralDelegate: NSObject, CBPeripheralManagerDelegate {
    weak var actor: PeripheralActor?
    
    init(actor: PeripheralActor) {
        self.actor = actor
    }
    
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        Task { @BluetoothActor in
            await BluetoothActor.shared.updateBluetoothState(peripheral.state)
        }
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        guard let actor = actor else { return }
        Task {
            await actor.handleServiceAdded(service: service, error: error)
        }
    }
    
    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        guard let actor = actor else { return }
        Task {
            await actor.handleAdvertisingStarted(error: error)
        }
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard let actor = actor else { return }
        Task {
            await actor.handleReadRequest(request)
        }
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        guard let actor = actor else { return }
        Task {
            await actor.handleWriteRequests(requests)
        }
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        guard let actor = actor else { return }
        Task {
            await actor.handleSubscription(central: central, characteristic: characteristic)
        }
    }
    
    func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        guard let actor = actor else { return }
        Task {
            await actor.handleUnsubscription(central: central, characteristic: characteristic)
        }
    }
}