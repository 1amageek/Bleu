import Foundation
import CoreBluetooth
import CoreBluetoothEmulator
@testable import Bleu

/// Adapter that wraps CoreBluetoothEmulator's EmulatedCBCentralManager
/// to conform to Bleu's BLECentralManagerProtocol
///
/// This adapter bridges the delegate-based EmulatedCBCentralManager API
/// to Bleu's actor-based AsyncStream API, enabling full-fidelity BLE
/// emulation in tests without requiring actual BLE hardware.
public actor EmulatedBLECentralManager: BLECentralManagerProtocol {

    // MARK: - Internal State

    /// The underlying EmulatedCBCentralManager from CoreBluetoothEmulator
    private nonisolated(unsafe) var centralManager: EmulatedCBCentralManager!

    /// Delegate bridge that converts callbacks to events
    private nonisolated(unsafe) var delegateBridge: DelegateBridge!

    /// Event channel for AsyncStream (AsyncChannel is thread-safe actor)
    private nonisolated let eventChannel = AsyncChannel<BLEEvent>()

    /// Track discovered peripherals (UUID -> EmulatedCBPeripheral)
    private var discoveredPeripherals: [UUID: EmulatedCBPeripheral] = [:]

    /// Track connected peripheral IDs
    private var connectedPeripherals: Set<UUID> = []

    /// Continuations waiting for connection completion
    private var connectionContinuations: [UUID: CheckedContinuation<Void, Error>] = [:]

    /// Continuations waiting for service discovery (peripheralID -> continuation)
    private var serviceDiscoveryContinuations: [UUID: CheckedContinuation<[ServiceMetadata], Error>] = [:]

    /// Continuations waiting for characteristic discovery (peripheralID+serviceUUID -> continuation)
    private var characteristicDiscoveryContinuations: [String: CheckedContinuation<[CharacteristicMetadata], Error>] = [:]

    /// Continuations waiting for read completion (peripheralID+charUUID -> continuation)
    private var readContinuations: [String: CheckedContinuation<Data, Error>] = [:]

    /// Continuations waiting for write completion (peripheralID+charUUID -> continuation)
    private var writeContinuations: [String: CheckedContinuation<Void, Error>] = [:]

    /// Continuations waiting for notify state change (peripheralID+charUUID -> continuation)
    private var notifyContinuations: [String: CheckedContinuation<Void, Error>] = [:]

    /// Continuations waiting for disconnection (peripheralID -> continuation)
    private var disconnectionContinuations: [UUID: CheckedContinuation<Void, Error>] = [:]

    /// Track peripheral services
    private var peripheralServices: [UUID: [ServiceMetadata]] = [:]

    /// Track peripheral characteristics per service
    private var peripheralCharacteristics: [UUID: [UUID: [CharacteristicMetadata]]] = [:]

    /// Track characteristic values
    private var characteristicValues: [UUID: [UUID: Data]] = [:]

    /// Track notifying characteristics
    private var notifyingCharacteristics: [UUID: Set<UUID>] = [:]

    /// Current Bluetooth state
    private var _state: CBManagerState = .unknown

    /// Dispatch queue for delegate callbacks (defaults to main queue)
    private let delegateQueue: DispatchQueue?

    // MARK: - Configuration

    public struct Configuration: Sendable {
        /// Initial Bluetooth state
        public var initialState: CBManagerState = .poweredOn

        /// Emulator configuration preset
        public var emulatorPreset: EmulatorPreset = .instant

        /// Custom emulator configuration (overrides preset if set)
        public var customEmulatorConfig: EmulatorConfiguration?

        /// Queue for delegate callbacks (nil = main queue)
        public var delegateQueue: DispatchQueue? = nil

        public enum EmulatorPreset: Sendable {
            case instant  // No delays, fast unit testing
            case `default`  // Realistic timing for development
            case slow  // Poor connection simulation
            case unreliable  // Error and failure simulation

            var configuration: EmulatorConfiguration {
                switch self {
                case .instant: return .instant
                case .default: return .default
                case .slow: return .slow
                case .unreliable: return .unreliable
                }
            }
        }

        public init() {}
    }

    private let config: Configuration

    // MARK: - Initialization

    public init(configuration: Configuration = Configuration()) {
        self.config = configuration
        self._state = configuration.initialState
        self.delegateQueue = configuration.delegateQueue
    }

    // MARK: - BLECentralManagerProtocol Implementation

    public nonisolated var events: AsyncStream<BLEEvent> {
        eventChannel.stream
    }

    public var state: CBManagerState {
        get async {
            return _state
        }
    }

    public func initialize() async {
        // EmulatorBus should be configured once by the test, not by each manager
        // Multiple configure() calls can interfere with event routing

        // Create delegate bridge
        let bridge = DelegateBridge(eventChannel: eventChannel, manager: self)
        self.delegateBridge = bridge

        // Create EmulatedCBCentralManager
        // This will automatically register with the already-configured EmulatorBus
        let manager = EmulatedCBCentralManager(
            delegate: bridge,
            queue: delegateQueue,
            options: nil
        )
        self.centralManager = manager
    }

    public func waitForPoweredOn() async -> CBManagerState {
        // Check if already powered on
        if _state == .poweredOn {
            return .poweredOn
        }

        // Wait for state to become powered on
        for await event in eventChannel.stream {
            if case .stateChanged(let newState) = event {
                _state = newState
                if newState == .poweredOn {
                    return .poweredOn
                }
            }
        }
        return _state
    }

    nonisolated public func scanForPeripherals(
        withServices serviceUUIDs: [UUID],
        timeout: TimeInterval
    ) -> AsyncStream<DiscoveredPeripheral> {
        let centralManager = self.centralManager
        let eventChannel = self.eventChannel

        return AsyncStream { continuation in
            Task {
                // Convert UUIDs to CBUUIDs
                let cbUUIDs = serviceUUIDs.isEmpty ? nil : serviceUUIDs.map { CBUUID(nsuuid: $0) }

                // Start scanning
                centralManager?.scanForPeripherals(withServices: cbUUIDs, options: nil)

                // Create a separate task to listen for discovery events
                let eventTask = Task {
                    for await event in eventChannel.stream {
                        if case .peripheralDiscovered(let discovered) = event {
                            continuation.yield(discovered)
                        }
                    }
                }

                // Wait for timeout
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))

                // Stop scanning
                centralManager?.stopScan()

                // Cancel event listening
                eventTask.cancel()
                continuation.finish()
            }
        }
    }

    public func stopScan() async {
        centralManager.stopScan()
    }

    public func connect(to peripheralID: UUID, timeout: TimeInterval) async throws {
        guard let peripheral = discoveredPeripherals[peripheralID] else {
            throw BleuError.peripheralNotFound(peripheralID)
        }

        // Check if already connected
        if connectedPeripherals.contains(peripheralID) {
            return
        }

        // Use continuation-based waiting instead of stream consumption
        // This avoids competing with other stream consumers (like waitForPoweredOn)
        return try await withThrowingTaskGroup(of: Void.self) { group in
            // Connection waiter using continuation
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    Task { [weak self] in
                        await self?.storeConnectionContinuation(peripheralID, continuation)
                    }
                }
            }

            // Timeout task
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw BleuError.connectionTimeout
            }

            // Start connection
            centralManager.connect(peripheral, options: nil)

            // Wait for first task to complete
            try await group.next()

            // Cancel remaining tasks and cleanup continuation
            group.cancelAll()
            connectionContinuations.removeValue(forKey: peripheralID)
        }
    }

    private func markConnected(_ peripheralID: UUID) {
        connectedPeripherals.insert(peripheralID)
    }

    private func storeConnectionContinuation(_ peripheralID: UUID, _ continuation: CheckedContinuation<Void, Error>) {
        connectionContinuations[peripheralID] = continuation
    }

    internal func resolveConnection(_ peripheralID: UUID) {
        if let continuation = connectionContinuations.removeValue(forKey: peripheralID) {
            markConnected(peripheralID)
            continuation.resume()
        }
    }

    internal func rejectConnection(_ peripheralID: UUID, _ error: Error) {
        if let continuation = connectionContinuations.removeValue(forKey: peripheralID) {
            continuation.resume(throwing: error)
        }
    }

    // MARK: - Continuation Storage Helpers

    private func storeServiceDiscoveryContinuation(_ peripheralID: UUID, _ continuation: CheckedContinuation<[ServiceMetadata], Error>) {
        serviceDiscoveryContinuations[peripheralID] = continuation
    }

    internal func resolveServiceDiscovery(_ peripheralID: UUID, _ services: [ServiceMetadata]) {
        if let continuation = serviceDiscoveryContinuations.removeValue(forKey: peripheralID) {
            peripheralServices[peripheralID] = services
            continuation.resume(returning: services)
        }
    }

    private func storeCharacteristicDiscoveryContinuation(_ key: String, _ continuation: CheckedContinuation<[CharacteristicMetadata], Error>) {
        characteristicDiscoveryContinuations[key] = continuation
    }

    internal func resolveCharacteristicDiscovery(_ peripheralID: UUID, _ serviceUUID: UUID, _ characteristics: [CharacteristicMetadata]) {
        let key = "\(peripheralID.uuidString)_\(serviceUUID.uuidString)"
        if let continuation = characteristicDiscoveryContinuations.removeValue(forKey: key) {
            if peripheralCharacteristics[peripheralID] == nil {
                peripheralCharacteristics[peripheralID] = [:]
            }
            peripheralCharacteristics[peripheralID]?[serviceUUID] = characteristics
            continuation.resume(returning: characteristics)
        }
    }

    private func storeReadContinuation(_ key: String, _ continuation: CheckedContinuation<Data, Error>) {
        readContinuations[key] = continuation
    }

    internal func resolveRead(_ peripheralID: UUID, _ characteristicUUID: UUID, _ data: Data?, _ error: Error?) {
        let key = "\(peripheralID.uuidString)_\(characteristicUUID.uuidString)"
        if let continuation = readContinuations.removeValue(forKey: key) {
            if let error = error {
                continuation.resume(throwing: error)
            } else if let data = data {
                if characteristicValues[peripheralID] == nil {
                    characteristicValues[peripheralID] = [:]
                }
                characteristicValues[peripheralID]?[characteristicUUID] = data
                continuation.resume(returning: data)
            } else {
                continuation.resume(throwing: BleuError.rpcFailed("Read operation returned no data"))
            }
        }
    }

    private func storeWriteContinuation(_ key: String, _ continuation: CheckedContinuation<Void, Error>) {
        writeContinuations[key] = continuation
    }

    internal func resolveWrite(_ peripheralID: UUID, _ characteristicUUID: UUID, _ error: Error?) {
        let key = "\(peripheralID.uuidString)_\(characteristicUUID.uuidString)"
        if let continuation = writeContinuations.removeValue(forKey: key) {
            if let error = error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
        }
    }

    private func storeNotifyContinuation(_ key: String, _ continuation: CheckedContinuation<Void, Error>) {
        notifyContinuations[key] = continuation
    }

    internal func resolveNotifyStateChange(_ peripheralID: UUID, _ characteristicUUID: UUID, _ isNotifying: Bool) {
        let key = "\(peripheralID.uuidString)_\(characteristicUUID.uuidString)"
        if let continuation = notifyContinuations.removeValue(forKey: key) {
            continuation.resume()
        }
    }

    private func storeDisconnectionContinuation(_ peripheralID: UUID, _ continuation: CheckedContinuation<Void, Error>) {
        disconnectionContinuations[peripheralID] = continuation
    }

    internal func resolveDisconnection(_ peripheralID: UUID) {
        if let continuation = disconnectionContinuations.removeValue(forKey: peripheralID) {
            continuation.resume()
        }
    }

    public func disconnect(from peripheralID: UUID) async throws {
        guard let peripheral = discoveredPeripherals[peripheralID] else {
            throw BleuError.peripheralNotFound(peripheralID)
        }

        // Use continuation-based waiting with timeout
        try await withThrowingTaskGroup(of: Void.self) { group in
            // Disconnection waiter using continuation
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    Task { [weak self] in
                        await self?.storeDisconnectionContinuation(peripheralID, continuation)
                    }
                }
            }

            // Timeout task
            group.addTask {
                try await Task.sleep(nanoseconds: 10_000_000_000)  // 10 seconds
                throw BleuError.connectionTimeout
            }

            // Start disconnection
            centralManager.cancelPeripheralConnection(peripheral)

            // Wait for first task to complete
            try await group.next()

            // Cancel remaining tasks and cleanup continuation
            group.cancelAll()
            disconnectionContinuations.removeValue(forKey: peripheralID)

            // Cleanup state
            connectedPeripherals.remove(peripheralID)
            peripheralServices.removeValue(forKey: peripheralID)
            peripheralCharacteristics.removeValue(forKey: peripheralID)
            characteristicValues.removeValue(forKey: peripheralID)
            notifyingCharacteristics.removeValue(forKey: peripheralID)
        }
    }

    public func isConnected(_ peripheralID: UUID) async -> Bool {
        return connectedPeripherals.contains(peripheralID)
    }

    public func discoverServices(
        for peripheralID: UUID,
        serviceUUIDs: [UUID]?
    ) async throws -> [ServiceMetadata] {
        guard let peripheral = discoveredPeripherals[peripheralID] else {
            throw BleuError.peripheralNotFound(peripheralID)
        }

        // Use continuation-based waiting with timeout to avoid stream consumption competition
        return try await withThrowingTaskGroup(of: [ServiceMetadata].self) { group in
            // Service discovery waiter using continuation
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    Task { [weak self] in
                        await self?.storeServiceDiscoveryContinuation(peripheralID, continuation)
                    }
                }
            }

            // Timeout task
            group.addTask {
                try await Task.sleep(nanoseconds: 10_000_000_000)  // 10 seconds
                throw BleuError.connectionTimeout
            }

            // Start service discovery
            let cbUUIDs = serviceUUIDs?.map { CBUUID(nsuuid: $0) }
            peripheral.discoverServices(cbUUIDs)

            // Wait for first task to complete
            let result = try await group.next()!

            // Cancel remaining tasks and cleanup continuation
            group.cancelAll()
            serviceDiscoveryContinuations.removeValue(forKey: peripheralID)

            return result
        }
    }

    public func discoverCharacteristics(
        for serviceUUID: UUID,
        in peripheralID: UUID,
        characteristicUUIDs: [UUID]?
    ) async throws -> [CharacteristicMetadata] {
        guard let peripheral = discoveredPeripherals[peripheralID],
              let service = peripheral.services?.first(where: { $0.uuid.uuidString == serviceUUID.uuidString }) else {
            throw BleuError.serviceNotFound(serviceUUID)
        }

        let key = "\(peripheralID.uuidString)_\(serviceUUID.uuidString)"

        // Use continuation-based waiting with timeout
        return try await withThrowingTaskGroup(of: [CharacteristicMetadata].self) { group in
            // Characteristic discovery waiter using continuation
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    Task { [weak self] in
                        await self?.storeCharacteristicDiscoveryContinuation(key, continuation)
                    }
                }
            }

            // Timeout task
            group.addTask {
                try await Task.sleep(nanoseconds: 10_000_000_000)  // 10 seconds
                throw BleuError.connectionTimeout
            }

            // Start characteristic discovery
            let cbUUIDs = characteristicUUIDs?.map { CBUUID(nsuuid: $0) }
            peripheral.discoverCharacteristics(cbUUIDs, for: service)

            // Wait for first task to complete
            let result = try await group.next()!

            // Cancel remaining tasks and cleanup continuation
            group.cancelAll()
            characteristicDiscoveryContinuations.removeValue(forKey: key)

            return result
        }
    }

    public func readValue(
        for characteristicUUID: UUID,
        in peripheralID: UUID
    ) async throws -> Data {
        guard let peripheral = discoveredPeripherals[peripheralID],
              let characteristic = findCharacteristic(characteristicUUID, in: peripheral) else {
            throw BleuError.characteristicNotFound(characteristicUUID)
        }

        let key = "\(peripheralID.uuidString)_\(characteristicUUID.uuidString)"

        // Use continuation-based waiting with timeout
        return try await withThrowingTaskGroup(of: Data.self) { group in
            // Read waiter using continuation
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    Task { [weak self] in
                        await self?.storeReadContinuation(key, continuation)
                    }
                }
            }

            // Timeout task
            group.addTask {
                try await Task.sleep(nanoseconds: 10_000_000_000)  // 10 seconds
                throw BleuError.connectionTimeout
            }

            // Start read operation
            peripheral.readValue(for: characteristic)

            // Wait for first task to complete
            let result = try await group.next()!

            // Cancel remaining tasks and cleanup continuation
            group.cancelAll()
            readContinuations.removeValue(forKey: key)

            return result
        }
    }

    public func writeValue(
        _ data: Data,
        for characteristicUUID: UUID,
        in peripheralID: UUID,
        type: CBCharacteristicWriteType
    ) async throws {
        guard let peripheral = discoveredPeripherals[peripheralID],
              let characteristic = findCharacteristic(characteristicUUID, in: peripheral) else {
            throw BleuError.characteristicNotFound(characteristicUUID)
        }

        // If with response, use continuation-based waiting with timeout
        if type == .withResponse {
            let key = "\(peripheralID.uuidString)_\(characteristicUUID.uuidString)"

            try await withThrowingTaskGroup(of: Void.self) { group in
                // Write completion waiter using continuation
                group.addTask {
                    try await withCheckedThrowingContinuation { continuation in
                        Task { [weak self] in
                            await self?.storeWriteContinuation(key, continuation)
                        }
                    }
                }

                // Timeout task
                group.addTask {
                    try await Task.sleep(nanoseconds: 10_000_000_000)  // 10 seconds
                    throw BleuError.connectionTimeout
                }

                // Start write operation
                peripheral.writeValue(data, for: characteristic, type: type)

                // Wait for first task to complete
                try await group.next()

                // Cancel remaining tasks and cleanup continuation
                group.cancelAll()
                writeContinuations.removeValue(forKey: key)
            }
        } else {
            // Without response - fire and forget
            peripheral.writeValue(data, for: characteristic, type: type)
        }
    }

    public func setNotifyValue(
        _ enabled: Bool,
        for characteristicUUID: UUID,
        in peripheralID: UUID
    ) async throws {
        guard let peripheral = discoveredPeripherals[peripheralID],
              let characteristic = findCharacteristic(characteristicUUID, in: peripheral) else {
            throw BleuError.characteristicNotFound(characteristicUUID)
        }

        let key = "\(peripheralID.uuidString)_\(characteristicUUID.uuidString)"

        // Use continuation-based waiting with timeout
        try await withThrowingTaskGroup(of: Void.self) { group in
            // Notify state change waiter using continuation
            group.addTask {
                try await withCheckedThrowingContinuation { continuation in
                    Task { [weak self] in
                        await self?.storeNotifyContinuation(key, continuation)
                    }
                }
            }

            // Timeout task
            group.addTask {
                try await Task.sleep(nanoseconds: 10_000_000_000)  // 10 seconds
                throw BleuError.connectionTimeout
            }

            // Start notify state change
            peripheral.setNotifyValue(enabled, for: characteristic)

            // Wait for first task to complete
            try await group.next()

            // Cancel remaining tasks and cleanup continuation
            group.cancelAll()
            notifyContinuations.removeValue(forKey: key)

            // Update tracking
            if enabled {
                if notifyingCharacteristics[peripheralID] == nil {
                    notifyingCharacteristics[peripheralID] = []
                }
                notifyingCharacteristics[peripheralID]?.insert(characteristicUUID)
            } else {
                notifyingCharacteristics[peripheralID]?.remove(characteristicUUID)
            }
        }
    }

    public func maximumWriteValueLength(
        for peripheralID: UUID,
        type: CBCharacteristicWriteType
    ) async -> Int? {
        guard let peripheral = discoveredPeripherals[peripheralID] else {
            return nil
        }

        return peripheral.maximumWriteValueLength(for: type)
    }

    // MARK: - Internal Helpers

    /// Store a discovered peripheral
    internal func storeDiscoveredPeripheral(_ peripheral: EmulatedCBPeripheral) {
        discoveredPeripherals[peripheral.identifier] = peripheral
    }

    /// Update state
    internal func updateState(_ newState: CBManagerState) {
        _state = newState
    }

    /// Find a characteristic in a peripheral by UUID
    private func findCharacteristic(_ uuid: UUID, in peripheral: EmulatedCBPeripheral) -> EmulatedCBCharacteristic? {
        guard let services = peripheral.services else { return nil }

        for service in services {
            if let characteristics = service.characteristics {
                for characteristic in characteristics {
                    if characteristic.uuid.uuidString == uuid.uuidString {
                        return characteristic
                    }
                }
            }
        }

        return nil
    }
}

// MARK: - Delegate Bridge

/// Bridge that converts EmulatedCBCentralManagerDelegate callbacks to BLEEvent stream
private class DelegateBridge: NSObject, EmulatedCBCentralManagerDelegate, EmulatedCBPeripheralDelegate, @unchecked Sendable {

    private let eventChannel: AsyncChannel<BLEEvent>
    private weak var manager: EmulatedBLECentralManager?

    init(eventChannel: AsyncChannel<BLEEvent>, manager: EmulatedBLECentralManager) {
        self.eventChannel = eventChannel
        self.manager = manager
    }

    // MARK: - EmulatedCBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: EmulatedCBCentralManager) {
        Task {
            await manager?.updateState(central.state)
            await eventChannel.send(.stateChanged(central.state))
        }
    }

    func centralManager(
        _ central: EmulatedCBCentralManager,
        didDiscover peripheral: EmulatedCBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        // Capture values before Task to avoid data races
        let peripheralID = peripheral.identifier
        let peripheralName = peripheral.name
        let rssiValue = RSSI.intValue
        let advData = AdvertisementData(from: advertisementData)

        // Set peripheral delegate on main thread before Task
        peripheral.delegate = self

        Task { [weak manager, eventChannel] in
            await manager?.storeDiscoveredPeripheral(peripheral)

            let discovered = DiscoveredPeripheral(
                id: peripheralID,
                name: peripheralName,
                rssi: rssiValue,
                advertisementData: advData
            )

            await eventChannel.send(.peripheralDiscovered(discovered))
        }
    }

    func centralManager(_ central: EmulatedCBCentralManager, didConnect peripheral: EmulatedCBPeripheral) {
        Task { [weak manager, eventChannel] in
            // Resolve continuation first (for connect() method)
            await manager?.resolveConnection(peripheral.identifier)
            // Then send event (for other consumers)
            await eventChannel.send(.peripheralConnected(peripheral.identifier))
        }
    }

    func centralManager(_ central: EmulatedCBCentralManager, didFailToConnect peripheral: EmulatedCBPeripheral, error: Error?) {
        Task { [weak manager, eventChannel] in
            let connectionError = error ?? BleuError.connectionFailed("Connection failed")
            // Reject continuation first (for connect() method)
            await manager?.rejectConnection(peripheral.identifier, connectionError)
            // Then send event (for other consumers)
            await eventChannel.send(.peripheralDisconnected(peripheral.identifier, connectionError))
        }
    }

    func centralManager(_ central: EmulatedCBCentralManager, didDisconnectPeripheral peripheral: EmulatedCBPeripheral, error: Error?) {
        Task { [weak manager, eventChannel] in
            // Resolve continuation first (for disconnect() method)
            await manager?.resolveDisconnection(peripheral.identifier)
            // Then send event (for other consumers)
            await eventChannel.send(.peripheralDisconnected(peripheral.identifier, error))
        }
    }

    // MARK: - EmulatedCBPeripheralDelegate

    func peripheral(_ peripheral: EmulatedCBPeripheral, didDiscoverServices error: Error?) {
        Task { [weak manager, eventChannel] in
            guard let services = peripheral.services else { return }

            let serviceMetadata = services.map { service in
                ServiceMetadata(
                    uuid: UUID(uuidString: service.uuid.uuidString) ?? UUID(),
                    isPrimary: service.isPrimary,
                    characteristics: []
                )
            }

            // Resolve continuation first (for discoverServices() method)
            await manager?.resolveServiceDiscovery(peripheral.identifier, serviceMetadata)
            // Then send event (for other consumers like scanForPeripherals)
            await eventChannel.send(.serviceDiscovered(peripheral.identifier, serviceMetadata))
        }
    }

    func peripheral(_ peripheral: EmulatedCBPeripheral, didDiscoverCharacteristicsFor service: EmulatedCBService, error: Error?) {
        Task { [weak manager, eventChannel] in
            guard let characteristics = service.characteristics else { return }

            let charMetadata = characteristics.map { char in
                CharacteristicMetadata(
                    uuid: UUID(uuidString: char.uuid.uuidString) ?? UUID(),
                    properties: CharacteristicProperties(rawValue: char.properties.rawValue),
                    permissions: CharacteristicPermissions(rawValue: 0b11), // readable + writeable
                    descriptors: []
                )
            }

            let serviceUUID = UUID(uuidString: service.uuid.uuidString) ?? UUID()
            // Resolve continuation first (for discoverCharacteristics() method)
            await manager?.resolveCharacteristicDiscovery(peripheral.identifier, serviceUUID, charMetadata)
            // Then send event (for other consumers)
            await eventChannel.send(.characteristicDiscovered(peripheral.identifier, serviceUUID, charMetadata))
        }
    }

    func peripheral(_ peripheral: EmulatedCBPeripheral, didUpdateValueFor characteristic: EmulatedCBCharacteristic, error: Error?) {
        Task { [weak manager, eventChannel] in
            let charUUID = UUID(uuidString: characteristic.uuid.uuidString) ?? UUID()
            let serviceUUID = UUID(uuidString: characteristic.service?.uuid.uuidString ?? "") ?? UUID()

            // Resolve continuation first (for readValue() method)
            await manager?.resolveRead(peripheral.identifier, charUUID, characteristic.value, error)
            // Then send event (for notification updates and other consumers)
            await eventChannel.send(.characteristicValueUpdated(
                peripheral.identifier,
                serviceUUID,
                charUUID,
                characteristic.value,
                error
            ))
        }
    }

    func peripheral(_ peripheral: EmulatedCBPeripheral, didWriteValueFor characteristic: EmulatedCBCharacteristic, error: Error?) {
        Task { [weak manager, eventChannel] in
            let charUUID = UUID(uuidString: characteristic.uuid.uuidString) ?? UUID()
            let serviceUUID = UUID(uuidString: characteristic.service?.uuid.uuidString ?? "") ?? UUID()

            // Resolve continuation first (for writeValue() method)
            await manager?.resolveWrite(peripheral.identifier, charUUID, error)
            // Then send event (for other consumers)
            await eventChannel.send(.characteristicWriteCompleted(
                peripheral.identifier,
                serviceUUID,
                charUUID,
                error
            ))
        }
    }

    func peripheral(_ peripheral: EmulatedCBPeripheral, didUpdateNotificationStateFor characteristic: EmulatedCBCharacteristic, error: Error?) {
        Task { [weak manager, eventChannel] in
            let charUUID = UUID(uuidString: characteristic.uuid.uuidString) ?? UUID()
            let serviceUUID = UUID(uuidString: characteristic.service?.uuid.uuidString ?? "") ?? UUID()

            // Resolve continuation first (for setNotifyValue() method)
            await manager?.resolveNotifyStateChange(peripheral.identifier, charUUID, characteristic.isNotifying)
            // Then send event (for other consumers)
            await eventChannel.send(.notificationStateChanged(
                peripheral.identifier,
                serviceUUID,
                charUUID,
                characteristic.isNotifying
            ))
        }
    }

    // L2CAP methods (not used but required by protocol)
    func peripheral(_ peripheral: EmulatedCBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        // L2CAP not implemented in Bleu, stub for protocol conformance
    }

    // Write without response ready callback
    func peripheralIsReady(toSendWriteWithoutResponse peripheral: EmulatedCBPeripheral) {
        // Backpressure handling - peripheral is ready for more writes
        // Could send an event here if needed
    }
}
