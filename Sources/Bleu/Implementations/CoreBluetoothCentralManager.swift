import Foundation
@preconcurrency import CoreBluetooth

/// CoreBluetooth implementation of BLECentralManagerProtocol
/// Wraps CBCentralManager and provides async/await interface
public actor CoreBluetoothCentralManager: BLECentralManagerProtocol {

    // MARK: - Properties

    private var centralManager: CBCentralManager?
    private var delegateProxy: CoreBluetoothCentralManagerDelegateProxy?
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

    // State continuations (support multiple waiters)
    private var stateContinuations: [CheckedContinuation<CBManagerState, Never>] = []

    // MARK: - Initialization

    public init() {}

    // MARK: - BLECentralManagerProtocol - Event Stream

    public nonisolated var events: AsyncStream<BLEEvent> {
        messageChannel.stream
    }

    // MARK: - BLECentralManagerProtocol - State Management

    public var state: CBManagerState {
        get async {
            return centralManager?.state ?? .unknown
        }
    }

    public func initialize() async {
        delegateProxy = CoreBluetoothCentralManagerDelegateProxy(actor: self)
        centralManager = CBCentralManager(delegate: delegateProxy, queue: nil)
    }

    public func waitForPoweredOn() async -> CBManagerState {
        guard let centralManager = centralManager else {
            return .unknown
        }

        if centralManager.state == .poweredOn {
            return .poweredOn
        }

        return await withCheckedContinuation { continuation in
            self.stateContinuations.append(continuation)
        }
    }

    // MARK: - BLECentralManagerProtocol - Scanning

    public func scanForPeripherals(
        withServices serviceUUIDs: [UUID],
        timeout: TimeInterval
    ) -> AsyncStream<DiscoveredPeripheral> {
        AsyncStream { continuation in
            Task { [weak self] in
                guard let self = self else { return }
                // Convert UUID to CBUUID inside Task to avoid Sendable issues
                let cbUUIDs = serviceUUIDs.map { CBUUID(nsuuid: $0) }
                await self.startScanning(for: cbUUIDs, continuation: continuation)

                // Set timeout
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await self.finishScanIfNeeded()
            }
        }
    }

    public func stopScan() async {
        finishScanIfNeeded()
    }

    // MARK: - BLECentralManagerProtocol - Connection Management

    public func connect(to peripheralID: UUID, timeout: TimeInterval) async throws {
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

    public func disconnect(from peripheralID: UUID) async throws {
        guard let peripheral = connectedPeripherals[peripheralID] else {
            return  // Already disconnected
        }

        try await withCheckedThrowingContinuation { continuation in
            disconnectionContinuations[peripheralID] = continuation
            centralManager?.cancelPeripheralConnection(peripheral)
        }
    }

    public func isConnected(_ peripheralID: UUID) async -> Bool {
        return connectedPeripherals[peripheralID] != nil
    }

    // MARK: - BLECentralManagerProtocol - Service & Characteristic Discovery

    public func discoverServices(
        for peripheralID: UUID,
        serviceUUIDs: [UUID]?
    ) async throws -> [ServiceMetadata] {
        guard let peripheral = connectedPeripherals[peripheralID] else {
            throw BleuError.peripheralNotFound(peripheralID)
        }

        let cbUUIDs = serviceUUIDs?.map { CBUUID(nsuuid: $0) }

        return try await withCheckedThrowingContinuation { continuation in
            serviceDiscoveryContinuations[peripheralID] = continuation
            peripheral.discoverServices(cbUUIDs)
        }
    }

    public func discoverCharacteristics(
        for serviceUUID: UUID,
        in peripheralID: UUID,
        characteristicUUIDs: [UUID]?
    ) async throws -> [CharacteristicMetadata] {
        guard let peripheral = connectedPeripherals[peripheralID] else {
            throw BleuError.peripheralNotFound(peripheralID)
        }

        let cbServiceUUID = CBUUID(nsuuid: serviceUUID)

        guard let service = peripheral.services?.first(where: { $0.uuid == cbServiceUUID }) else {
            throw BleuError.serviceNotFound(serviceUUID)
        }

        let cbCharUUIDs = characteristicUUIDs?.map { CBUUID(nsuuid: $0) }

        return try await withCheckedThrowingContinuation { continuation in
            characteristicDiscoveryContinuations[peripheralID] = continuation
            peripheral.discoverCharacteristics(cbCharUUIDs, for: service)
        }
    }

    // MARK: - BLECentralManagerProtocol - Characteristic Operations

    public func readValue(
        for characteristicUUID: UUID,
        in peripheralID: UUID
    ) async throws -> Data {
        guard let peripheral = connectedPeripherals[peripheralID] else {
            throw BleuError.peripheralNotFound(peripheralID)
        }

        let cbUUID = CBUUID(nsuuid: characteristicUUID)

        guard let characteristic = findCharacteristic(uuid: cbUUID, in: peripheral) else {
            throw BleuError.characteristicNotFound(characteristicUUID)
        }

        guard let delegate = peripheralDelegates[peripheralID] else {
            throw BleuError.peripheralNotFound(peripheralID)
        }

        return try await delegate.readValue(for: characteristic, peripheral: peripheral)
    }

    public func writeValue(
        _ data: Data,
        for characteristicUUID: UUID,
        in peripheralID: UUID,
        type: CBCharacteristicWriteType
    ) async throws {
        guard let peripheral = connectedPeripherals[peripheralID] else {
            throw BleuError.peripheralNotFound(peripheralID)
        }

        let cbUUID = CBUUID(nsuuid: characteristicUUID)

        guard let characteristic = findCharacteristic(uuid: cbUUID, in: peripheral) else {
            throw BleuError.characteristicNotFound(characteristicUUID)
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

    public func setNotifyValue(
        _ enabled: Bool,
        for characteristicUUID: UUID,
        in peripheralID: UUID
    ) async throws {
        guard let peripheral = connectedPeripherals[peripheralID] else {
            throw BleuError.peripheralNotFound(peripheralID)
        }

        let cbUUID = CBUUID(nsuuid: characteristicUUID)

        guard let characteristic = findCharacteristic(uuid: cbUUID, in: peripheral) else {
            throw BleuError.characteristicNotFound(characteristicUUID)
        }

        guard let delegate = peripheralDelegates[peripheralID] else {
            throw BleuError.peripheralNotFound(peripheralID)
        }

        try await delegate.setNotifyValue(enabled, for: characteristic, peripheral: peripheral)
    }

    // MARK: - BLECentralManagerProtocol - MTU Management

    public func maximumWriteValueLength(
        for peripheralID: UUID,
        type: CBCharacteristicWriteType
    ) async -> Int? {
        guard let peripheral = connectedPeripherals[peripheralID] else { return nil }
        return peripheral.maximumWriteValueLength(for: type)
    }

    // MARK: - Private Scanning Methods

    private func startScanning(for services: [CBUUID], continuation: AsyncStream<DiscoveredPeripheral>.Continuation) {
        guard !isScanning else { return }

        scanContinuation = continuation
        isScanning = true

        // Get configuration for scan options
        Task {
            let allowDuplicates = await BleuConfigurationManager.shared.current().allowDuplicatesInScan
            self.performScan(services: services, allowDuplicates: allowDuplicates)
        }
    }

    private func performScan(services: [CBUUID], allowDuplicates: Bool) {
        centralManager?.scanForPeripherals(
            withServices: services.isEmpty ? nil : services,
            options: [
                CBCentralManagerScanOptionAllowDuplicatesKey: allowDuplicates
            ]
        )
    }

    private func finishScanIfNeeded() {
        guard isScanning else { return }

        isScanning = false
        scanContinuation?.finish()
        scanContinuation = nil
        centralManager?.stopScan()
    }

    // MARK: - Private Connection Methods

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

    private func cancelConnection(_ peripheral: CBPeripheral) {
        centralManager?.cancelPeripheralConnection(peripheral)
    }

    private func retrievePeripheral(with id: UUID) -> CBPeripheral? {
        let peripherals = centralManager?.retrievePeripherals(withIdentifiers: [id])
        return peripherals?.first
    }

    // MARK: - Private Helper Methods

    private func findCharacteristic(uuid: CBUUID, in peripheral: CBPeripheral) -> CBCharacteristic? {
        guard let services = peripheral.services else { return nil }

        for service in services {
            if let characteristic = service.characteristics?.first(where: { $0.uuid == uuid }) {
                return characteristic
            }
        }

        return nil
    }

    // MARK: - Internal Delegate Handlers

    func handleStateUpdate(_ state: CBManagerState) async {
        await messageChannel.send(.stateChanged(state))

        if state == .poweredOn && !stateContinuations.isEmpty {
            stateContinuations.forEach { $0.resume(returning: state) }
            stateContinuations.removeAll()
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

    fileprivate func handleCharacteristicDiscovery(for peripheralID: UUID, serviceUUID: String, characteristics: [CoreBluetoothSendableCharacteristic]?, error: Error?) async {
        // Create metadata from characteristics
        let metadata = characteristics?.map { characteristic -> CharacteristicMetadata in
            // Use deterministic UUID for short UUIDs
            let uuid = UUID(uuidString: characteristic.uuid) ?? UUID.deterministic(from: characteristic.uuid)

            // Convert from rawValue to CharacteristicProperties
            let properties = CharacteristicProperties(rawValue: characteristic.properties)

            return CharacteristicMetadata(
                uuid: uuid,
                properties: properties,
                permissions: CharacteristicPermissions(), // CoreBluetooth doesn't expose permissions on CBCharacteristic
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

    func handleValueUpdate(for peripheralID: UUID, characteristicUUID: String, serviceUUID: String?, value: Data?, error: Error?) async {
        let svcUUID = if let svcUUID = serviceUUID {
            UUID(uuidString: svcUUID) ?? UUID.deterministic(from: svcUUID)
        } else {
            UUID()
        }
        let charUUID = UUID(uuidString: characteristicUUID) ?? UUID.deterministic(from: characteristicUUID)

        // Include error in event for proper ATT error propagation
        await messageChannel.send(.characteristicValueUpdated(
            peripheralID,
            svcUUID,
            charUUID,
            value,
            error  // Now propagate ATT errors to BLEActorSystem
        ))
    }
}

// MARK: - PeripheralDelegate

/// Delegate for CBPeripheral that handles characteristic operations
/// Note: Using NSLock for thread-safety as this delegate is called from CoreBluetooth's internal queue
private final class PeripheralDelegate: NSObject, CBPeripheralDelegate, @unchecked Sendable {
    let peripheralID: UUID
    weak var actor: CoreBluetoothCentralManager?

    // Thread-safe continuation storage using NSLock
    private let lock = NSLock()
    private var readContinuations: [CBUUID: CheckedContinuation<Data, Error>] = [:]
    private var writeContinuations: [CBUUID: CheckedContinuation<Void, Error>] = [:]
    private var notifyContinuations: [CBUUID: CheckedContinuation<Void, Error>] = [:]

    init(peripheralID: UUID, actor: CoreBluetoothCentralManager) {
        self.peripheralID = peripheralID
        self.actor = actor
        super.init()
    }

    func readValue(for characteristic: CBCharacteristic, peripheral: CBPeripheral) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            readContinuations[characteristic.uuid] = continuation
            lock.unlock()
            peripheral.readValue(for: characteristic)
        }
    }

    func writeValue(_ data: Data, for characteristic: CBCharacteristic, peripheral: CBPeripheral) async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            writeContinuations[characteristic.uuid] = continuation
            lock.unlock()
            peripheral.writeValue(data, for: characteristic, type: .withResponse)
        }
    }

    func setNotifyValue(_ enabled: Bool, for characteristic: CBCharacteristic, peripheral: CBPeripheral) async throws {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            notifyContinuations[characteristic.uuid] = continuation
            lock.unlock()
            peripheral.setNotifyValue(enabled, for: characteristic)
        }
    }

    // MARK: - CBPeripheralDelegate Methods

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
        // Extract service info before Task boundary
        let serviceUUID = service.uuid.uuidString
        let characteristics = service.characteristics?.map { CoreBluetoothSendableCharacteristic(from: $0) }

        Task { [weak self, peripheralID] in
            guard let self = self else { return }
            // Pass extracted values, not the CBService itself
            await self.actor?.handleCharacteristicDiscovery(for: peripheralID, serviceUUID: serviceUUID, characteristics: characteristics, error: error)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        // Extract values before Task boundary to avoid passing non-Sendable objects
        let value = characteristic.value
        let charUUID = characteristic.uuid.uuidString
        let serviceUUID = characteristic.service?.uuid.uuidString

        lock.lock()
        let continuation = readContinuations.removeValue(forKey: characteristic.uuid)
        lock.unlock()

        if let continuation = continuation {
            if let error = error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume(returning: value ?? Data())
            }
        }

        Task { [weak self, peripheralID] in
            guard let self = self else { return }
            // Pass only extracted values, not the CBCharacteristic itself
            await self.actor?.handleValueUpdate(for: peripheralID, characteristicUUID: charUUID, serviceUUID: serviceUUID, value: value, error: error)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        lock.lock()
        let continuation = writeContinuations.removeValue(forKey: characteristic.uuid)
        lock.unlock()

        if let continuation = continuation {
            if let error = error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        lock.lock()
        let continuation = notifyContinuations.removeValue(forKey: characteristic.uuid)
        lock.unlock()

        if let continuation = continuation {
            if let error = error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        }
    }
}

// MARK: - CoreBluetoothCentralManagerDelegateProxy

/// Delegate proxy for CBCentralManager to forward callbacks to CoreBluetoothCentralManager
final class CoreBluetoothCentralManagerDelegateProxy: NSObject, CBCentralManagerDelegate, @unchecked Sendable {
    weak var actor: CoreBluetoothCentralManager?

    init(actor: CoreBluetoothCentralManager) {
        self.actor = actor
        super.init()
    }

    // MARK: - CBCentralManagerDelegate

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { [weak actor] in
            await actor?.handleStateUpdate(central.state)
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        // Convert advertisement data to Sendable type
        let rssiInt = RSSI.intValue
        let adData = AdvertisementData(from: advertisementData)
        let peripheralID = peripheral.identifier
        let peripheralName = peripheral.name

        Task { [weak actor] in
            // Create a new discovered peripheral struct to avoid capturing non-Sendable peripheral
            let discovered = DiscoveredPeripheral(
                id: peripheralID,
                name: peripheralName,
                rssi: rssiInt,
                advertisementData: adData
            )

            // Store the peripheral separately (needs to be refactored)
            await actor?.handlePeripheralDiscovery(discovered, peripheral: peripheral)
        }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { [weak actor] in
            await actor?.handleConnection(peripheral)
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { [weak actor] in
            await actor?.handleConnectionFailure(peripheral, error: error)
        }
    }

    public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { [weak actor] in
            await actor?.handleDisconnection(peripheral, error: error)
        }
    }
}

// MARK: - CoreBluetoothSendableCharacteristic

/// Sendable representation of CBCharacteristic for CoreBluetoothCentralManager
fileprivate struct CoreBluetoothSendableCharacteristic: Sendable {
    let uuid: String
    let properties: UInt

    init(from characteristic: CBCharacteristic) {
        self.uuid = characteristic.uuid.uuidString
        self.properties = characteristic.properties.rawValue
    }
}
