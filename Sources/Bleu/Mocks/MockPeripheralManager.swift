import Foundation
import CoreBluetooth

/// Mock implementation of BLE peripheral manager for testing
/// Simulates peripheral behavior without requiring BLE hardware or TCC permissions
public actor MockPeripheralManager: BLEPeripheralManagerProtocol {

    // MARK: - Internal State

    /// Unique ID for this mock peripheral (for bridge routing)
    /// This ID represents the peripheral's identity and should match the actor ID
    private var peripheralID: UUID?

    private var _state: CBManagerState
    private var _isAdvertising = false
    private var services: [UUID: ServiceMetadata] = [:]
    private var characteristicValues: [UUID: Data] = [:]
    private var subscribedCentrals: [UUID: Set<UUID>] = [:]
    private let eventChannel = AsyncChannel<BLEEvent>()

    // MARK: - Configuration

    public struct Configuration: Sendable {
        /// Initial Bluetooth state
        public var initialState: CBManagerState = .poweredOn

        /// Delay before advertising starts (simulates async)
        public var advertisingDelay: TimeInterval = 0

        /// Should advertising fail?
        public var shouldFailAdvertising: Bool = false

        /// Should service addition fail?
        public var shouldFailServiceAdd: Bool = false

        /// Delay before responding to writes
        public var writeResponseDelay: TimeInterval = 0

        public init() {}
    }

    private var config: Configuration

    // MARK: - Initialization

    public init(configuration: Configuration = Configuration()) {
        self.config = configuration
        self._state = configuration.initialState
    }

    // MARK: - BLEPeripheralManagerProtocol Implementation

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

    public func add(_ service: ServiceMetadata) async throws {
        if config.shouldFailServiceAdd {
            throw BleuError.operationNotSupported
        }

        services[service.uuid] = service

        // Initialize characteristic values
        for char in service.characteristics {
            characteristicValues[char.uuid] = Data()
        }

        // Register characteristics with bridge if peripheral ID is set
        if let peripheralID = peripheralID {
            for char in service.characteristics {
                await MockBLEBridge.shared.registerPeripheral(
                    peripheralID,
                    serviceUUID: service.uuid,
                    characteristicUUID: char.uuid,
                    writeHandler: { [weak self] charUUID, value in
                        guard let self = self else { return }
                        await self.handleIncomingWrite(charUUID: charUUID, value: value)
                    }
                )
            }
        }
    }

    /// Set the peripheral ID for bridge communication
    /// This should be called when the peripheral is associated with a distributed actor
    public func setPeripheralID(_ id: UUID) async {
        self.peripheralID = id

        // Register all existing characteristics with the bridge
        for (serviceUUID, service) in services {
            for char in service.characteristics {
                await MockBLEBridge.shared.registerPeripheral(
                    id,
                    serviceUUID: serviceUUID,
                    characteristicUUID: char.uuid,
                    writeHandler: { [weak self] charUUID, value in
                        guard let self = self else { return }
                        await self.handleIncomingWrite(charUUID: charUUID, value: value)
                    }
                )
            }
        }
    }

    /// Handle incoming write from bridge
    private func handleIncomingWrite(charUUID: UUID, value: Data) async {
        // Store the value
        characteristicValues[charUUID] = value

        // Send event to listeners
        await eventChannel.send(.writeRequestReceived(
            UUID(), // centralID - we don't have it in this context
            UUID(), // serviceUUID - we don't have it in this context
            charUUID,
            value
        ))
    }

    public func startAdvertising(_ data: AdvertisementData) async throws {
        if config.shouldFailAdvertising {
            throw BleuError.operationNotSupported
        }

        // Simulate async delay
        if config.advertisingDelay > 0 {
            try await Task.sleep(
                nanoseconds: UInt64(config.advertisingDelay * 1_000_000_000)
            )
        }

        _isAdvertising = true
        // Mock: advertising always succeeds
    }

    public func stopAdvertising() async {
        _isAdvertising = false
    }

    public var isAdvertising: Bool {
        get async {
            return _isAdvertising
        }
    }

    public func updateValue(
        _ data: Data,
        for characteristicUUID: UUID,
        to centrals: [UUID]?
    ) async throws -> Bool {
        // Simulate write delay
        if config.writeResponseDelay > 0 {
            try await Task.sleep(
                nanoseconds: UInt64(config.writeResponseDelay * 1_000_000_000)
            )
        }

        characteristicValues[characteristicUUID] = data

        // Send notification event for subscribed centrals
        let centralsToNotify = centrals ?? Array(
            subscribedCentrals[characteristicUUID] ?? []
        )

        for centralID in centralsToNotify {
            await eventChannel.send(.characteristicValueUpdated(
                centralID,
                UUID(),  // service UUID
                characteristicUUID,
                data
            ))
        }

        // Send notification through bridge for cross-system communication
        if let peripheralID = peripheralID {
            await MockBLEBridge.shared.peripheralNotify(
                from: peripheralID,
                characteristicUUID: characteristicUUID,
                value: data
            )
        }

        return true  // Mock always succeeds
    }

    public func subscribedCentrals(for characteristicUUID: UUID) async -> [UUID] {
        Array(subscribedCentrals[characteristicUUID] ?? [])
    }

    // MARK: - Test Helpers (Not in Protocol)

    /// Simulate a central subscribing to a characteristic
    public func simulateSubscription(
        central: UUID,
        to characteristic: UUID
    ) async {
        var centrals = subscribedCentrals[characteristic] ?? []
        centrals.insert(central)
        subscribedCentrals[characteristic] = centrals

        await eventChannel.send(.centralSubscribed(
            central,
            UUID(),  // service UUID
            characteristic
        ))
    }

    /// Simulate a write request from a central
    public func simulateWriteRequest(
        from central: UUID,
        to characteristic: UUID,
        value: Data
    ) async {
        characteristicValues[characteristic] = value
        await eventChannel.send(.writeRequestReceived(
            central,
            UUID(),  // service UUID
            characteristic,
            value
        ))
    }

    /// Change Bluetooth state (for testing state transitions)
    public func simulateStateChange(_ newState: CBManagerState) async {
        _state = newState
        await eventChannel.send(.stateChanged(newState))
    }

    /// Get current characteristic value (for testing)
    public func getCharacteristicValue(_ characteristicUUID: UUID) async -> Data? {
        characteristicValues[characteristicUUID]
    }

    /// Get all registered services (for testing)
    public func getServices() async -> [ServiceMetadata] {
        Array(services.values)
    }
}
