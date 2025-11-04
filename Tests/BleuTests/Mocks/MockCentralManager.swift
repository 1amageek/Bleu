import Foundation
import CoreBluetooth
@testable import Bleu

/// Mock implementation of BLE central manager for testing
/// Simulates central behavior without requiring BLE hardware or TCC permissions
public actor MockCentralManager: BLECentralManagerProtocol {

    // MARK: - Internal State

    /// Unique ID for this mock central (for bridge routing)
    private let centralID = UUID()

    private var _state: CBManagerState
    private var discoveredPeripherals: [UUID: DiscoveredPeripheral] = [:]
    private var connectedPeripherals: Set<UUID> = []
    private var peripheralServices: [UUID: [ServiceMetadata]] = [:]
    private var peripheralCharacteristics: [UUID: [UUID: [CharacteristicMetadata]]] = [:]
    private var characteristicValues: [UUID: [UUID: Data]] = [:]
    private var notifyingCharacteristics: [UUID: Set<UUID>] = [:]
    private let eventChannel = AsyncChannel<BLEEvent>()

    // MARK: - Configuration

    public struct Configuration: Sendable {
        public var initialState: CBManagerState = .poweredOn
        public var skipWaitForPoweredOn: Bool = false
        public var scanDelay: TimeInterval = 0.1
        public var connectionDelay: TimeInterval = 0.1
        public var discoveryDelay: TimeInterval = 0.05
        public var shouldFailConnection: Bool = false
        public var connectionTimeout: Bool = false

        /// Enable cross-system communication via MockBLEBridge
        /// When true, this manager will use MockBLEBridge.shared to communicate
        /// with other systems' mock managers
        public var useBridge: Bool = false

        public init() {}
    }

    private var config: Configuration

    // MARK: - Initialization

    public init(configuration: Configuration = Configuration()) {
        self.config = configuration
        self._state = configuration.initialState
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
        // Mock implementation - no-op
        // Already initialized in init(), no CoreBluetooth to create
    }

    public func waitForPoweredOn() async -> CBManagerState {
        // If skipWaitForPoweredOn is true, return current state without transitioning
        if config.skipWaitForPoweredOn {
            return _state
        }

        // Already powered on - return immediately
        if _state == .poweredOn {
            return .poweredOn
        }

        // Only transition if not already powered on
        // No artificial delay - mock should be instant
        _state = .poweredOn
        await eventChannel.send(.stateChanged(.poweredOn))
        return .poweredOn
    }

    public func scanForPeripherals(
        withServices serviceUUIDs: [UUID],
        timeout: TimeInterval
    ) -> AsyncStream<DiscoveredPeripheral> {
        AsyncStream { continuation in
            Task { [weak self] in
                guard let self = self else {
                    continuation.finish()
                    return
                }

                // Emit discovered peripherals matching service UUIDs
                for peripheral in await self.discoveredPeripherals.values {
                    let matches = serviceUUIDs.isEmpty ||
                        peripheral.advertisementData.serviceUUIDs.contains(
                            where: { serviceUUIDs.contains($0) }
                        )

                    if matches {
                        if await self.config.scanDelay > 0 {
                            try? await Task.sleep(
                                nanoseconds: UInt64(await self.config.scanDelay * 1_000_000_000)
                            )
                        }
                        continuation.yield(peripheral)
                        await self.eventChannel.send(.peripheralDiscovered(peripheral))
                    }
                }

                // Wait for timeout
                try? await Task.sleep(
                    nanoseconds: UInt64(timeout * 1_000_000_000)
                )
                continuation.finish()
            }
        }
    }

    public func stopScan() async {
        // Mock: no-op
    }

    public func connect(
        to peripheralID: UUID,
        timeout: TimeInterval
    ) async throws {
        if config.shouldFailConnection {
            throw BleuError.connectionFailed("Mock configured to fail")
        }

        if config.connectionTimeout {
            try await Task.sleep(
                nanoseconds: UInt64(timeout * 1_000_000_000)
            )
            throw BleuError.connectionTimeout
        }

        guard discoveredPeripherals[peripheralID] != nil else {
            throw BleuError.peripheralNotFound(peripheralID)
        }

        if config.connectionDelay > 0 {
            try await Task.sleep(
                nanoseconds: UInt64(config.connectionDelay * 1_000_000_000)
            )
        }

        connectedPeripherals.insert(peripheralID)
        await eventChannel.send(.peripheralConnected(peripheralID))
    }

    public func disconnect(from peripheralID: UUID) async throws {
        connectedPeripherals.remove(peripheralID)
        await eventChannel.send(.peripheralDisconnected(peripheralID, nil))
    }

    public func isConnected(_ peripheralID: UUID) async -> Bool {
        connectedPeripherals.contains(peripheralID)
    }

    public func discoverServices(
        for peripheralID: UUID,
        serviceUUIDs: [UUID]?
    ) async throws -> [ServiceMetadata] {
        guard connectedPeripherals.contains(peripheralID) else {
            throw BleuError.peripheralNotFound(peripheralID)
        }

        if config.discoveryDelay > 0 {
            try await Task.sleep(
                nanoseconds: UInt64(config.discoveryDelay * 1_000_000_000)
            )
        }

        let services = peripheralServices[peripheralID] ?? []
        await eventChannel.send(.serviceDiscovered(peripheralID, services))
        return services
    }

    public func discoverCharacteristics(
        for serviceUUID: UUID,
        in peripheralID: UUID,
        characteristicUUIDs: [UUID]?
    ) async throws -> [CharacteristicMetadata] {
        guard connectedPeripherals.contains(peripheralID) else {
            throw BleuError.peripheralNotFound(peripheralID)
        }

        if config.discoveryDelay > 0 {
            try await Task.sleep(
                nanoseconds: UInt64(config.discoveryDelay * 1_000_000_000)
            )
        }

        return peripheralCharacteristics[peripheralID]?[serviceUUID] ?? []
    }

    public func readValue(
        for characteristicUUID: UUID,
        in peripheralID: UUID
    ) async throws -> Data {
        guard connectedPeripherals.contains(peripheralID) else {
            throw BleuError.peripheralNotFound(peripheralID)
        }

        return characteristicValues[peripheralID]?[characteristicUUID] ?? Data()
    }

    public func writeValue(
        _ data: Data,
        for characteristicUUID: UUID,
        in peripheralID: UUID,
        type: CBCharacteristicWriteType
    ) async throws {
        guard connectedPeripherals.contains(peripheralID) else {
            throw BleuError.peripheralNotFound(peripheralID)
        }

        // Store locally
        if characteristicValues[peripheralID] == nil {
            characteristicValues[peripheralID] = [:]
        }
        characteristicValues[peripheralID]?[characteristicUUID] = data

        // Forward to bridge if enabled
        if config.useBridge {
            try await MockBLEBridge.shared.centralWrite(
                from: UUID(),  // central ID - could be tracked if needed
                to: peripheralID,
                characteristicUUID: characteristicUUID,
                value: data
            )
        }
    }

    public func setNotifyValue(
        _ enabled: Bool,
        for characteristicUUID: UUID,
        in peripheralID: UUID
    ) async throws {
        guard connectedPeripherals.contains(peripheralID) else {
            throw BleuError.peripheralNotFound(peripheralID)
        }

        if enabled {
            if notifyingCharacteristics[peripheralID] == nil {
                notifyingCharacteristics[peripheralID] = []
            }
            notifyingCharacteristics[peripheralID]?.insert(characteristicUUID)

            // Register with bridge to receive notifications
            if config.useBridge {
                await MockBLEBridge.shared.registerCentral(
                    UUID(),  // central ID
                    for: peripheralID,
                    characteristicUUID: characteristicUUID,
                    notificationHandler: { [weak self] charUUID, data in
                        guard let self = self else { return }
                        // Send notification event to local system
                        await self.eventChannel.send(.characteristicValueUpdated(
                            peripheralID,
                            UUID(),  // service UUID
                            charUUID,
                            data
                        ))
                    }
                )
            }
        } else {
            notifyingCharacteristics[peripheralID]?.remove(characteristicUUID)
        }

        await eventChannel.send(.notificationStateChanged(
            peripheralID,
            UUID(),
            characteristicUUID,
            enabled
        ))
    }

    public func maximumWriteValueLength(
        for peripheralID: UUID,
        type: CBCharacteristicWriteType
    ) async -> Int? {
        guard connectedPeripherals.contains(peripheralID) else {
            return nil
        }
        return 512  // Mock MTU
    }

    // MARK: - Test Helpers (Not in Protocol)

    /// Register a peripheral for discovery
    public func registerPeripheral(
        _ peripheral: DiscoveredPeripheral,
        services: [ServiceMetadata]
    ) async {
        discoveredPeripherals[peripheral.id] = peripheral
        peripheralServices[peripheral.id] = services

        // Setup characteristics mapping
        peripheralCharacteristics[peripheral.id] = [:]
        for service in services {
            peripheralCharacteristics[peripheral.id]?[service.uuid] =
                service.characteristics
        }
    }

    /// Simulate a characteristic value update (notification)
    public func simulateValueUpdate(
        for characteristicUUID: UUID,
        in peripheralID: UUID,
        value: Data
    ) async {
        if characteristicValues[peripheralID] == nil {
            characteristicValues[peripheralID] = [:]
        }
        characteristicValues[peripheralID]?[characteristicUUID] = value

        if notifyingCharacteristics[peripheralID]?.contains(characteristicUUID) == true {
            await eventChannel.send(.characteristicValueUpdated(
                peripheralID,
                UUID(),
                characteristicUUID,
                value
            ))
        }
    }

    /// Simulate disconnection with error
    public func simulateDisconnection(
        peripheralID: UUID,
        error: Error?
    ) async {
        connectedPeripherals.remove(peripheralID)
        await eventChannel.send(.peripheralDisconnected(peripheralID, error))
    }

    /// Change Bluetooth state
    public func simulateStateChange(_ newState: CBManagerState) async {
        _state = newState
        await eventChannel.send(.stateChanged(newState))
    }

    /// Get all discovered peripherals (for testing)
    public func getDiscoveredPeripherals() async -> [DiscoveredPeripheral] {
        Array(discoveredPeripherals.values)
    }

    /// Get connected peripheral IDs (for testing)
    public func getConnectedPeripheralIDs() async -> Set<UUID> {
        connectedPeripherals
    }

    /// Get characteristic value (for testing)
    public func getCharacteristicValue(
        _ characteristicUUID: UUID,
        in peripheralID: UUID
    ) async -> Data? {
        characteristicValues[peripheralID]?[characteristicUUID]
    }
}
