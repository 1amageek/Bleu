import Foundation
@preconcurrency import CoreBluetooth

/// Local actor that wraps CBCentralManager for BLE central operations
public actor LocalCentralActor {
    private var centralManager: CBCentralManager?
    private var delegateProxy: CentralManagerDelegateProxy?
    private let messageChannel = AsyncChannel<BLEEvent>()
    
    // Peripheral management
    private var discoveredPeripherals: [UUID: CBPeripheral] = [:]
    private var connectedPeripherals: [UUID: CBPeripheral] = [:]
    private var peripheralDelegates: [UUID: PeripheralDelegate] = [:]
    
    // Scanning state
    private var isScanning = false
    private var scanContinuation: AsyncStream<DiscoveredPeripheral>.Continuation?
    
    // Connection continuations
    private var connectionContinuations: [UUID: CheckedContinuation<Void, Error>] = [:]
    private var disconnectionContinuations: [UUID: CheckedContinuation<Void, Error>] = [:]
    
    // Service discovery continuations
    private var serviceDiscoveryContinuations: [UUID: CheckedContinuation<[ServiceMetadata], Error>] = [:]
    private var characteristicDiscoveryContinuations: [UUID: CheckedContinuation<[CharacteristicMetadata], Error>] = [:]
    
    // State continuation
    private var stateContinuation: CheckedContinuation<CBManagerState, Never>?
    
    init() {}
    
    /// Initialize the central manager
    public func initialize() {
        delegateProxy = CentralManagerDelegateProxy(actor: self)
        centralManager = CBCentralManager(delegate: delegateProxy, queue: nil)
    }
    
    /// Scan for peripherals with specified services
    public func scan(for services: [CBUUID], timeout: TimeInterval = 10.0) -> AsyncStream<DiscoveredPeripheral> {
        AsyncStream { continuation in
            Task {
                self.startScanning(for: services, continuation: continuation)
                
                // Set timeout
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                self.stopScanning()
                continuation.finish()
            }
        }
    }
    
    private func startScanning(for services: [CBUUID], continuation: AsyncStream<DiscoveredPeripheral>.Continuation) {
        guard !isScanning else { return }
        
        scanContinuation = continuation
        isScanning = true
        
        centralManager?.scanForPeripherals(
            withServices: services.isEmpty ? nil : services,
            options: [
                CBCentralManagerScanOptionAllowDuplicatesKey: false
            ]
        )
    }
    
    /// Stop scanning
    public func stopScanning() {
        guard isScanning else { return }
        
        isScanning = false
        scanContinuation?.finish()
        scanContinuation = nil
        centralManager?.stopScan()
    }
    
    /// Connect to a peripheral
    public func connect(to peripheralID: UUID, timeout: TimeInterval = 10.0) async throws {
        // Check if already connected
        if connectedPeripherals[peripheralID] != nil {
            return
        }
        
        // Find the peripheral
        guard let peripheral = discoveredPeripherals[peripheralID] ?? retrievePeripheral(with: peripheralID) else {
            throw BleuError.peripheralNotFound(peripheralID)
        }
        
        // Wait for powered on state
        let state = await waitForPoweredOn()
        guard state == .poweredOn else {
            throw BleuError.bluetoothPoweredOff
        }
        
        // Connect with timeout
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await self.performConnection(to: peripheral)
            }
            
            group.addTask { [weak self] in
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                // Cancel the connection attempt before throwing timeout
                await self?.cancelConnection(peripheral)
                throw BleuError.connectionTimeout
            }
            
            try await group.next()
            group.cancelAll()
        }
    }
    
    private func performConnection(to peripheral: CBPeripheral) async throws {
        try await withCheckedThrowingContinuation { continuation in
            connectionContinuations[peripheral.identifier] = continuation
            
            // Setup peripheral delegate
            let delegate = PeripheralDelegate(peripheralID: peripheral.identifier, actor: self)
            peripheralDelegates[peripheral.identifier] = delegate
            peripheral.delegate = delegate
            
            centralManager?.connect(peripheral, options: nil)
        }
    }
    
    /// Disconnect from a peripheral
    public func disconnect(from peripheralID: UUID) async throws {
        guard let peripheral = connectedPeripherals[peripheralID] else {
            return  // Already disconnected
        }
        
        try await withCheckedThrowingContinuation { continuation in
            disconnectionContinuations[peripheralID] = continuation
            centralManager?.cancelPeripheralConnection(peripheral)
        }
    }
    
    /// Discover services for a peripheral
    public func discoverServices(for peripheralID: UUID, serviceUUIDs: [CBUUID]? = nil) async throws -> [ServiceMetadata] {
        guard let peripheral = connectedPeripherals[peripheralID] else {
            throw BleuError.peripheralNotFound(peripheralID)
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            serviceDiscoveryContinuations[peripheralID] = continuation
            peripheral.discoverServices(serviceUUIDs)
        }
    }
    
    /// Discover characteristics for a service
    public func discoverCharacteristics(
        for serviceUUID: CBUUID,
        in peripheralID: UUID,
        characteristicUUIDs: [CBUUID]? = nil
    ) async throws -> [CharacteristicMetadata] {
        guard let peripheral = connectedPeripherals[peripheralID] else {
            throw BleuError.peripheralNotFound(peripheralID)
        }
        
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            // Use deterministic UUID for short UUIDs that can't be parsed as standard UUID
            let uuid = UUID(uuidString: serviceUUID.uuidString) ?? UUID.deterministic(from: serviceUUID.uuidString)
            throw BleuError.serviceNotFound(uuid)
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            characteristicDiscoveryContinuations[peripheralID] = continuation
            peripheral.discoverCharacteristics(characteristicUUIDs, for: service)
        }
    }
    
    /// Read a characteristic value
    public func readValue(for characteristicUUID: CBUUID, in peripheralID: UUID) async throws -> Data {
        guard let peripheral = connectedPeripherals[peripheralID] else {
            throw BleuError.peripheralNotFound(peripheralID)
        }
        
        guard let characteristic = findCharacteristic(uuid: characteristicUUID, in: peripheral) else {
            let uuid = UUID(uuidString: characteristicUUID.uuidString) ?? UUID()
            throw BleuError.characteristicNotFound(uuid)
        }
        
        guard let delegate = peripheralDelegates[peripheralID] else {
            throw BleuError.peripheralNotFound(peripheralID)
        }
        
        return try await delegate.readValue(for: characteristic, peripheral: peripheral)
    }
    
    /// Write a value to a characteristic
    public func writeValue(
        _ data: Data,
        for characteristicUUID: CBUUID,
        in peripheralID: UUID,
        type: CBCharacteristicWriteType
    ) async throws {
        guard let peripheral = connectedPeripherals[peripheralID] else {
            throw BleuError.peripheralNotFound(peripheralID)
        }
        
        guard let characteristic = findCharacteristic(uuid: characteristicUUID, in: peripheral) else {
            let uuid = UUID(uuidString: characteristicUUID.uuidString) ?? UUID()
            throw BleuError.characteristicNotFound(uuid)
        }
        
        if type == .withResponse {
            guard let delegate = peripheralDelegates[peripheralID] else {
                throw BleuError.peripheralNotFound(peripheralID)
            }
            try await delegate.writeValue(data, for: characteristic, peripheral: peripheral)
        } else {
            peripheral.writeValue(data, for: characteristic, type: type)
        }
    }
    
    /// Set notification state for a characteristic
    public func setNotifyValue(_ enabled: Bool, for characteristicUUID: CBUUID, in peripheralID: UUID) async throws {
        guard let peripheral = connectedPeripherals[peripheralID] else {
            throw BleuError.peripheralNotFound(peripheralID)
        }
        
        guard let characteristic = findCharacteristic(uuid: characteristicUUID, in: peripheral) else {
            let uuid = UUID(uuidString: characteristicUUID.uuidString) ?? UUID()
            throw BleuError.characteristicNotFound(uuid)
        }
        
        guard let delegate = peripheralDelegates[peripheralID] else {
            throw BleuError.peripheralNotFound(peripheralID)
        }
        
        try await delegate.setNotifyValue(enabled, for: characteristic, peripheral: peripheral)
    }
    
    /// Get event stream
    public var events: AsyncStream<BLEEvent> {
        messageChannel.stream
    }
    
    /// Get maximum write value length for a connected peripheral
    public func getMaximumWriteValueLength(for peripheralID: UUID, type: CBCharacteristicWriteType) -> Int? {
        guard let peripheral = connectedPeripherals[peripheralID] else { return nil }
        return peripheral.maximumWriteValueLength(for: type)
    }
    
    /// Cancel connection attempt
    private func cancelConnection(_ peripheral: CBPeripheral) {
        centralManager?.cancelPeripheralConnection(peripheral)
    }
    
    /// Retrieve a peripheral by ID
    private func retrievePeripheral(with id: UUID) -> CBPeripheral? {
        let peripherals = centralManager?.retrievePeripherals(withIdentifiers: [id])
        return peripherals?.first
    }
    
    /// Find a characteristic in a peripheral
    private func findCharacteristic(uuid: CBUUID, in peripheral: CBPeripheral) -> CBCharacteristic? {
        guard let services = peripheral.services else { return nil }
        
        for service in services {
            if let characteristic = service.characteristics?.first(where: { $0.uuid == uuid }) {
                return characteristic
            }
        }
        
        return nil
    }
    
    /// Wait for powered on state
    private func waitForPoweredOn() async -> CBManagerState {
        guard let centralManager = centralManager else {
            return .unknown
        }
        
        if centralManager.state == .poweredOn {
            return .poweredOn
        }
        
        return await withCheckedContinuation { continuation in
            self.stateContinuation = continuation
        }
    }
    
    // Called by PeripheralDelegate
    func handleServiceDiscovery(for peripheralID: UUID, services: [CBService]?, error: Error?) async {
        // Create metadata from services
        let metadata = services?.map { service -> ServiceMetadata in
            // Use deterministic UUID for short UUIDs
            let uuid = UUID(uuidString: service.uuid.uuidString) ?? UUID.deterministic(from: service.uuid.uuidString)
            return ServiceMetadata(
                uuid: uuid,
                isPrimary: service.isPrimary,
                characteristics: []  // Will be populated when characteristics are discovered
            )
        } ?? []
        
        if let continuation = serviceDiscoveryContinuations.removeValue(forKey: peripheralID) {
            if let error = error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume(returning: metadata)
            }
        }
        
        // Send event
        if !metadata.isEmpty {
            await messageChannel.send(.serviceDiscovered(peripheralID, metadata))
        }
    }
    
    func handleCharacteristicDiscovery(for peripheralID: UUID, service: CBService, error: Error?) async {
        // Create metadata from characteristics
        let metadata = service.characteristics?.map { characteristic -> CharacteristicMetadata in
            // Use deterministic UUID for short UUIDs
            let uuid = UUID(uuidString: characteristic.uuid.uuidString) ?? UUID.deterministic(from: characteristic.uuid.uuidString)
            
            // Convert CBCharacteristicProperties to CharacteristicProperties
            var properties = CharacteristicProperties()
            let cbProps = characteristic.properties
            if cbProps.contains(.broadcast) { properties.insert(.broadcast) }
            if cbProps.contains(.read) { properties.insert(.read) }
            if cbProps.contains(.writeWithoutResponse) { properties.insert(.writeWithoutResponse) }
            if cbProps.contains(.write) { properties.insert(.write) }
            if cbProps.contains(.notify) { properties.insert(.notify) }
            if cbProps.contains(.indicate) { properties.insert(.indicate) }
            if cbProps.contains(.authenticatedSignedWrites) { properties.insert(.authenticatedSignedWrites) }
            if cbProps.contains(.extendedProperties) { properties.insert(.extendedProperties) }
            
            return CharacteristicMetadata(
                uuid: uuid,
                properties: properties,
                permissions: CharacteristicPermissions(), // CoreBluetooth doesn't expose permissions
                descriptors: []
            )
        } ?? []
        
        if let continuation = characteristicDiscoveryContinuations.removeValue(forKey: peripheralID) {
            if let error = error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume(returning: metadata)
            }
        }
    }
    
    func handleValueUpdate(for peripheralID: UUID, characteristic: CBCharacteristic, error: Error?) async {
        let serviceUUID = if let svcUUID = characteristic.service?.uuid {
            UUID(uuidString: svcUUID.uuidString) ?? UUID.deterministic(from: svcUUID.uuidString)
        } else {
            UUID()
        }
        let characteristicUUID = UUID(uuidString: characteristic.uuid.uuidString) ?? UUID.deterministic(from: characteristic.uuid.uuidString)
        
        await messageChannel.send(.characteristicValueUpdated(
            peripheralID,
            serviceUUID,
            characteristicUUID,
            characteristic.value
        ))
    }
}

// MARK: - Delegate Handlers

extension LocalCentralActor {
    func handleStateUpdate(_ state: CBManagerState) async {
        await messageChannel.send(.stateChanged(state))
        
        if let continuation = stateContinuation {
            continuation.resume(returning: state)
            stateContinuation = nil
        }
    }
    
    func handlePeripheralDiscovery(_ discovered: DiscoveredPeripheral, peripheral: CBPeripheral) async {
        discoveredPeripherals[peripheral.identifier] = peripheral
        
        scanContinuation?.yield(discovered)
        await messageChannel.send(.peripheralDiscovered(discovered))
    }
    
    func handleConnection(_ peripheral: CBPeripheral) async {
        connectedPeripherals[peripheral.identifier] = peripheral
        
        if let continuation = connectionContinuations.removeValue(forKey: peripheral.identifier) {
            continuation.resume()
        }
        
        await messageChannel.send(.peripheralConnected(peripheral.identifier))
    }
    
    func handleConnectionFailure(_ peripheral: CBPeripheral, error: Error?) async {
        if let continuation = connectionContinuations.removeValue(forKey: peripheral.identifier) {
            continuation.resume(throwing: error ?? BleuError.connectionFailed("Unknown error"))
        }
    }
    
    func handleDisconnection(_ peripheral: CBPeripheral, error: Error?) async {
        connectedPeripherals.removeValue(forKey: peripheral.identifier)
        peripheralDelegates.removeValue(forKey: peripheral.identifier)
        
        if let continuation = disconnectionContinuations.removeValue(forKey: peripheral.identifier) {
            if let error = error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        }
        
        await messageChannel.send(.peripheralDisconnected(peripheral.identifier, error))
    }
}

// MARK: - PeripheralDelegate

private class PeripheralDelegate: NSObject, CBPeripheralDelegate, @unchecked Sendable {
    let peripheralID: UUID
    weak var actor: LocalCentralActor?
    
    private var readContinuations: [CBUUID: CheckedContinuation<Data, Error>] = [:]
    private var writeContinuations: [CBUUID: CheckedContinuation<Void, Error>] = [:]
    private var notifyContinuations: [CBUUID: CheckedContinuation<Void, Error>] = [:]
    
    init(peripheralID: UUID, actor: LocalCentralActor) {
        self.peripheralID = peripheralID
        self.actor = actor
        super.init()
    }
    
    func readValue(for characteristic: CBCharacteristic, peripheral: CBPeripheral) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            readContinuations[characteristic.uuid] = continuation
            peripheral.readValue(for: characteristic)
        }
    }
    
    func writeValue(_ data: Data, for characteristic: CBCharacteristic, peripheral: CBPeripheral) async throws {
        try await withCheckedThrowingContinuation { continuation in
            writeContinuations[characteristic.uuid] = continuation
            peripheral.writeValue(data, for: characteristic, type: .withResponse)
        }
    }
    
    func setNotifyValue(_ enabled: Bool, for characteristic: CBCharacteristic, peripheral: CBPeripheral) async throws {
        try await withCheckedThrowingContinuation { continuation in
            notifyContinuations[characteristic.uuid] = continuation
            peripheral.setNotifyValue(enabled, for: characteristic)
        }
    }
    
    // CBPeripheralDelegate methods
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let services = peripheral.services
        Task { @Sendable [weak self, peripheralID] in
            guard let self = self else { return }
            // We pass the services directly since we marked the delegate as @unchecked Sendable
            // This is safe because we're only reading the services data
            await self.actor?.handleServiceDiscovery(for: peripheralID, services: services, error: error)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        Task { [weak self, peripheralID] in
            guard let self = self else { return }
            // We pass the service directly since we marked the delegate as @unchecked Sendable
            await self.actor?.handleCharacteristicDiscovery(for: peripheralID, service: service, error: error)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let continuation = readContinuations.removeValue(forKey: characteristic.uuid) {
            if let error = error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume(returning: characteristic.value ?? Data())
            }
        }
        
        Task { [weak self, peripheralID] in
            guard let self = self else { return }
            // We pass the characteristic directly since we marked the delegate as @unchecked Sendable
            await self.actor?.handleValueUpdate(for: peripheralID, characteristic: characteristic, error: error)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let continuation = writeContinuations.removeValue(forKey: characteristic.uuid) {
            if let error = error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let continuation = notifyContinuations.removeValue(forKey: characteristic.uuid) {
            if let error = error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        }
    }
}