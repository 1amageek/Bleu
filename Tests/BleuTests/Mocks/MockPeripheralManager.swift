import Foundation
import CoreBluetooth
@testable import Bleu

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
        // MARK: - Existing Properties (unchanged for backward compatibility)

        /// Initial Bluetooth state
        public var initialState: CBManagerState = .poweredOn

        /// Skip automatic transition to powered on during initialization
        /// Set to true if you want to test state changes manually
        public var skipWaitForPoweredOn: Bool = false

        /// Delay before advertising starts (simulates async)
        public var advertisingDelay: TimeInterval = 0

        /// Should advertising fail?
        public var shouldFailAdvertising: Bool = false

        /// Should service addition fail?
        public var shouldFailServiceAdd: Bool = false

        /// Delay before responding to writes
        public var writeResponseDelay: TimeInterval = 0

        /// Optional bridge instance for cross-system communication
        /// When set, this manager will use the provided bridge to communicate
        /// with other systems' mock managers
        public var bridge: MockBLEBridge? = nil

        /// Convenience property for backward compatibility
        public var useBridge: Bool {
            get { bridge != nil }
            set {
                if newValue && bridge == nil {
                    fatalError("useBridge=true requires setting a bridge instance. Use config.bridge = MockBLEBridge() instead.")
                } else if !newValue {
                    bridge = nil
                }
            }
        }

        // MARK: - NEW: Phase 1 - Behavioral Realism

        /// Enable realistic CoreBluetooth behavior
        public var realisticBehavior: Bool = false

        /// State transition behavior (same as MockCentralManager)
        public enum StateTransitionMode: Sendable {
            case instant                              // Current behavior: immediate transition
            case realistic(duration: TimeInterval)    // Simulates real state change timing
            case stuck(CBManagerState)                // Never transitions from this state
        }
        public var stateTransition: StateTransitionMode = .instant

        /// UpdateValue queue behavior (peripheral-specific)
        public enum QueueBehavior: Sendable {
            case infinite                              // Current: never fails (default)
            case realistic(capacity: Int, retries: Int)  // Matches real queue behavior
        }
        public var queueBehavior: QueueBehavior = .infinite

        /// Error injection configuration for testing error handling
        public struct ErrorInjection: Sendable {
            public var serviceAddition: Error? = nil
            public var advertisingStart: Error? = nil
            public var updateValue: Error? = nil
            public var queueFullProbability: Double = 0.0  // 0.0-1.0 probability of queue being full

            public init(
                serviceAddition: Error? = nil,
                advertisingStart: Error? = nil,
                updateValue: Error? = nil,
                queueFullProbability: Double = 0.0
            ) {
                self.serviceAddition = serviceAddition
                self.advertisingStart = advertisingStart
                self.updateValue = updateValue
                self.queueFullProbability = queueFullProbability
            }

            public static var none: ErrorInjection { ErrorInjection() }
        }
        public var errorInjection: ErrorInjection = .none

        /// Update MTU on subscription (matches real CoreBluetooth behavior)
        public var updateMTUOnSubscription: Bool = true

        /// Support read requests (new functionality)
        public var supportReadRequests: Bool = true

        /// Fragmentation support - use BLETransport like real implementation
        public var useFragmentation: Bool = true

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
        // If skipWaitForPoweredOn is true, return current state without transitioning
        if config.skipWaitForPoweredOn {
            return _state
        }

        // Already powered on - return immediately
        if _state == .poweredOn {
            return .poweredOn
        }

        // Handle state transition based on configuration mode
        switch config.stateTransition {
        case .instant:
            // Default behavior: instant transition (backward compatible)
            _state = .poweredOn
            await eventChannel.send(.stateChanged(.poweredOn))
            return .poweredOn

        case .realistic(let duration):
            // Realistic mode: simulate state transition timing
            if duration > 0 {
                try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            }

            // Check if transition to poweredOn is possible
            if shouldTransitionToPoweredOn() {
                _state = .poweredOn
                await eventChannel.send(.stateChanged(.poweredOn))
            }
            return _state

        case .stuck(let stuckState):
            // Stuck mode: never transitions (for testing authorization failures)
            _state = stuckState
            await eventChannel.send(.stateChanged(stuckState))
            return stuckState
        }
    }

    /// Determines if state can transition to .poweredOn
    /// Simulates real CoreBluetooth state transition logic
    private func shouldTransitionToPoweredOn() -> Bool {
        switch _state {
        case .unauthorized, .unsupported:
            // Cannot transition from these states
            return false
        case .poweredOff, .resetting, .unknown:
            // Can transition to .poweredOn from these states
            return true
        case .poweredOn:
            // Already powered on
            return true
        @unknown default:
            return false
        }
    }

    public func add(_ service: ServiceMetadata) async throws {
        // Realistic mode: validate state (matches real CoreBluetooth)
        if config.realisticBehavior {
            guard _state == .poweredOn else {
                throw BleuError.bluetoothPoweredOff
            }
        }

        // Error injection
        if let error = config.errorInjection.serviceAddition {
            throw error
        }

        // Backward compatible: simple flag check
        if config.shouldFailServiceAdd {
            throw BleuError.operationNotSupported
        }

        services[service.uuid] = service

        // Initialize characteristic values
        for char in service.characteristics {
            characteristicValues[char.uuid] = Data()
        }

        // Register with bridge if enabled
        if config.useBridge, let peripheralID = peripheralID, let bridge = config.bridge {
            for char in service.characteristics {
                await bridge.registerPeripheral(
                    peripheralID,
                    serviceUUID: service.uuid,
                    characteristicUUID: char.uuid,
                    writeHandler: { [weak self] centralID, charUUID, data in
                        guard let self = self else { return }

                        // Register large MTU for this central in mock mode
                        await BLETransport.shared.updateMaxPayloadSize(for: centralID, maxWriteLength: 512)

                        // Store the value
                        await self.storeCharacteristicValue(charUUID, data: data)
                        // Send event to local system
                        await self.eventChannel.send(.writeRequestReceived(
                            centralID,  // Use central ID from bridge
                            service.uuid,
                            charUUID,
                            data
                        ))
                    }
                )
            }

            // Register disconnection handler (once per peripheral, not per characteristic)
            await bridge.registerDisconnectionHandler(for: peripheralID) { [weak self] centralID in
                guard let self = self else { return }
                await self.handleCentralDisconnected(centralID)
            }
        }
    }

    /// Handle central disconnection (peripheral side)
    /// Automatically cleans up subscriptions for the disconnected central
    private func handleCentralDisconnected(_ centralID: UUID) async {
        // Remove subscriptions for this central
        for (charUUID, centrals) in subscribedCentrals {
            var updatedCentrals = centrals
            updatedCentrals.remove(centralID)
            subscribedCentrals[charUUID] = updatedCentrals

            // Send unsubscribed event if this central was subscribed
            if centrals.contains(centralID) {
                await eventChannel.send(.centralUnsubscribed(
                    centralID,
                    UUID(),  // service UUID
                    charUUID
                ))
            }
        }

        // Remove MTU for this central
        if config.updateMTUOnSubscription {
            await BLETransport.shared.removeMTU(for: centralID)
        }

        // Send disconnect event to peripheral system
        // Note: BLEEvent doesn't have peripheralDisconnected for peripheral side,
        // so we use centralUnsubscribed as a proxy for cleanup
    }

    /// Store characteristic value (internal helper)
    private func storeCharacteristicValue(_ uuid: UUID, data: Data) {
        characteristicValues[uuid] = data
    }

    /// Set the peripheral ID for bridge communication
    /// This should be called when the peripheral is associated with a distributed actor
    public func setPeripheralID(_ id: UUID) async {
        self.peripheralID = id
    }

    public func startAdvertising(_ data: AdvertisementData) async throws {
        // Error injection
        if let error = config.errorInjection.advertisingStart {
            throw error
        }

        // Backward compatible: simple flag check
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

        // Queue behavior simulation
        switch config.queueBehavior {
        case .infinite:
            // Default behavior: always succeeds
            return try await sendUpdateValue(data, for: characteristicUUID, to: centrals)

        case .realistic(_, let maxRetries):
            // Realistic mode: simulate queue full behavior
            var retries = 0

            while retries < maxRetries {
                // Check if queue is full (random simulation based on probability)
                let queueFullChance = config.errorInjection.queueFullProbability
                let isQueueFull = Double.random(in: 0...1) < queueFullChance

                if !isQueueFull {
                    // Queue has space - send notification
                    return try await sendUpdateValue(data, for: characteristicUUID, to: centrals)
                }

                // Queue full - wait and retry (matches real CoreBluetooth)
                retries += 1
                if retries < maxRetries {
                    try await Task.sleep(nanoseconds: 10_000_000)  // 10ms between retries
                }
            }

            // Max retries exhausted - check if should throw or return false
            if let error = config.errorInjection.updateValue {
                throw error
            }
            return false  // Indicates queue still full
        }
    }

    /// Internal helper to send update value (shared by both queue modes)
    private func sendUpdateValue(
        _ data: Data,
        for characteristicUUID: UUID,
        to centrals: [UUID]?
    ) async throws -> Bool {
        characteristicValues[characteristicUUID] = data

        if config.useBridge, let peripheralID = peripheralID, let bridge = config.bridge {
            // Bridge mode: Bridge handles routing - skip subscription checks
            // The bridge will only deliver notifications to centrals that have registered handlers
            await bridge.peripheralNotify(
                from: peripheralID,
                characteristicUUID: characteristicUUID,
                value: data
            )
        } else {
            // Non-bridge mode: Check subscriptions and filter centrals
            // CRITICAL SECURITY FIX: If centrals filter is provided but results in empty list, throw error
            let centralsToNotify: [UUID]
            if let requestedCentralIDs = centrals {
                let allSubscribed = subscribedCentrals[characteristicUUID] ?? []
                let filtered = allSubscribed.filter { requestedCentralIDs.contains($0) }

                // Empty filter result - refuse to broadcast
                if filtered.isEmpty {
                    throw BleuError.peripheralNotFound(requestedCentralIDs.first ?? UUID())
                }

                centralsToNotify = Array(filtered)
            } else {
                // No filter - send to all subscribers
                centralsToNotify = Array(subscribedCentrals[characteristicUUID] ?? [])
            }

            // Local event channel for same-system communication
            for centralID in centralsToNotify {
                await eventChannel.send(.characteristicValueUpdated(
                    centralID,
                    UUID(),  // service UUID
                    characteristicUUID,
                    data,
                    nil  // no error in mock
                ))
            }
        }

        return true
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

        // Update MTU like real CoreBluetoothPeripheralManager
        if config.updateMTUOnSubscription {
            // Get realistic MTU for this central (varies by device)
            let mtu: Int
            if config.realisticBehavior {
                // Realistic variation (common iOS/macOS MTU values)
                let realisticMTUs = [23, 27, 158, 185, 247, 251, 512]
                mtu = realisticMTUs.randomElement() ?? 185
            } else {
                // Fast/predictable (backward compatible)
                mtu = 512
            }

            // Register with BLETransport
            await BLETransport.shared.updateMaxPayloadSize(for: central, maxWriteLength: mtu)
        }

        await eventChannel.send(.centralSubscribed(
            central,
            UUID(),  // service UUID
            characteristic
        ))
    }

    /// Simulate a central unsubscribing from a characteristic
    public func simulateUnsubscription(
        central: UUID,
        from characteristic: UUID
    ) async {
        subscribedCentrals[characteristic]?.remove(central)

        // Remove MTU like real implementation
        if config.updateMTUOnSubscription {
            await BLETransport.shared.removeMTU(for: central)
        }

        await eventChannel.send(.centralUnsubscribed(
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

    /// Simulate a read request from a central
    /// - Parameters:
    ///   - central: Central UUID requesting the read
    ///   - characteristic: Characteristic UUID being read
    ///   - offset: Byte offset for read (0 for complete read)
    /// - Returns: Data at the characteristic, or throws ATT error
    public func simulateReadRequest(
        from central: UUID,
        for characteristic: UUID,
        offset: Int = 0
    ) async throws -> Data {
        guard config.supportReadRequests else {
            throw BleuError.operationNotSupported
        }

        // Get characteristic value
        guard let value = characteristicValues[characteristic] else {
            // No value set - return ATT error
            let error = NSError(
                domain: CBATTErrorDomain,
                code: CBATTError.readNotPermitted.rawValue,
                userInfo: [NSLocalizedDescriptionKey: "Characteristic has no value"]
            )
            throw error
        }

        // Validate offset
        guard offset >= 0 && offset < value.count else {
            let error = NSError(
                domain: CBATTErrorDomain,
                code: CBATTError.invalidOffset.rawValue,
                userInfo: [NSLocalizedDescriptionKey: "Invalid offset \(offset)"]
            )
            throw error
        }

        // Return value from offset
        let result = value[offset...]

        // Send event (BLEEvent.readRequestReceived takes 3 UUIDs only)
        await eventChannel.send(.readRequestReceived(
            central,
            UUID(),  // service UUID
            characteristic
        ))

        return Data(result)
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
