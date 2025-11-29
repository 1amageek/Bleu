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

    // MARK: - NEW: State for realistic behavior

    /// Cache MTU per peripheral (for realistic MTU variation)
    private var peripheralMTU: [UUID: Int] = [:]

    /// Track pending connections (for timeout cancellation)
    private var pendingConnections: Set<UUID> = []

    /// Track which peripherals have been discovered (for duplicate suppression)
    private var alreadyDiscovered: Set<UUID> = []

    /// Track write queue state per peripheral (for backpressure simulation)
    private var writeQueueReady: [UUID: Bool] = [:]

    // MARK: - Configuration

    public struct Configuration: Sendable {
        // MARK: - Existing Properties (unchanged for backward compatibility)

        public var initialState: CBManagerState = .poweredOn
        public var skipWaitForPoweredOn: Bool = false
        public var scanDelay: TimeInterval = 0.1
        public var connectionDelay: TimeInterval = 0.1
        public var discoveryDelay: TimeInterval = 0.05
        public var shouldFailConnection: Bool = false
        public var connectionTimeout: Bool = false

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

        /// Enable realistic CoreBluetooth behavior (vs fast predictable mock)
        /// When true, applies realistic delays, state transitions, and MTU values
        public var realisticBehavior: Bool = false

        /// State transition behavior
        public enum StateTransitionMode: Sendable {
            case instant                              // Current behavior: immediate transition
            case realistic(duration: TimeInterval)    // Simulates real state change timing
            case stuck(CBManagerState)                // Never transitions from this state
        }
        public var stateTransition: StateTransitionMode = .instant

        /// MTU simulation mode
        public enum MTUMode: Sendable {
            case fixed(Int)                           // Current: always same value (default 512)
            case realistic(min: Int, max: Int)        // Varies per connection (simulates different devices)
            case actual                               // Queries real device (iOS default: 185)
        }
        public var mtuMode: MTUMode = .fixed(512)

        /// Error injection configuration for testing error handling
        public struct ErrorInjection: Sendable {
            public var serviceDiscovery: Error? = nil
            public var characteristicDiscovery: Error? = nil
            public var readOperation: Error? = nil
            public var writeOperation: Error? = nil
            public var notificationSubscription: Error? = nil
            public var connectionFailureRate: Double = 0.0  // 0.0-1.0 random failure probability

            public init(
                serviceDiscovery: Error? = nil,
                characteristicDiscovery: Error? = nil,
                readOperation: Error? = nil,
                writeOperation: Error? = nil,
                notificationSubscription: Error? = nil,
                connectionFailureRate: Double = 0.0
            ) {
                self.serviceDiscovery = serviceDiscovery
                self.characteristicDiscovery = characteristicDiscovery
                self.readOperation = readOperation
                self.writeOperation = writeOperation
                self.notificationSubscription = notificationSubscription
                self.connectionFailureRate = connectionFailureRate
            }

            public static var none: ErrorInjection { ErrorInjection() }

            public static func random(failureRate: Double = 0.1) -> ErrorInjection {
                ErrorInjection(connectionFailureRate: failureRate)
            }
        }
        public var errorInjection: ErrorInjection = .none

        /// Connection behavior - cancel connection on timeout (matches real CoreBluetooth)
        public var cancelConnectionOnTimeout: Bool = true

        /// Write operation behavior - differentiate between .withResponse and .withoutResponse
        public var differentiateWriteTypes: Bool = true

        /// Fragmentation behavior - use BLETransport like real implementation
        public var useFragmentation: Bool = true

        // MARK: - NEW: Scan Options Support

        /// Scan options configuration
        public struct ScanOptions: Sendable {
            /// Allow duplicate discovery reports (CBCentralManagerScanOptionAllowDuplicatesKey)
            /// When false (default), each peripheral is reported only once
            /// When true, peripherals are reported every time they advertise
            public var allowDuplicates: Bool = false

            /// Solicited service UUIDs (CBCentralManagerScanOptionSolicitedServiceUUIDsKey)
            /// Peripherals advertising these services will be discovered even if not in the main service list
            public var solicitedServiceUUIDs: [UUID] = []

            public init(
                allowDuplicates: Bool = false,
                solicitedServiceUUIDs: [UUID] = []
            ) {
                self.allowDuplicates = allowDuplicates
                self.solicitedServiceUUIDs = solicitedServiceUUIDs
            }
        }

        /// Default scan options (used when scanForPeripherals is called without options)
        public var defaultScanOptions: ScanOptions = ScanOptions()

        // MARK: - NEW: Write Backpressure Configuration

        /// canSendWriteWithoutResponse behavior
        public enum WriteQueueBehavior: Sendable {
            case alwaysReady                    // Default: always returns true (backward compatible)
            case realistic(queueSize: Int)      // Simulates real queue with ready callbacks
        }
        public var writeQueueBehavior: WriteQueueBehavior = .alwaysReady

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

    public func scanForPeripherals(
        withServices serviceUUIDs: [UUID],
        timeout: TimeInterval
    ) -> AsyncStream<DiscoveredPeripheral> {
        // Use default scan options
        return scanForPeripherals(
            withServices: serviceUUIDs,
            options: config.defaultScanOptions,
            timeout: timeout
        )
    }

    /// Scan for peripherals with explicit options
    public func scanForPeripherals(
        withServices serviceUUIDs: [UUID],
        options: Configuration.ScanOptions,
        timeout: TimeInterval
    ) -> AsyncStream<DiscoveredPeripheral> {
        AsyncStream { continuation in
            Task { [weak self] in
                guard let self = self else {
                    continuation.finish()
                    return
                }

                // Reset already discovered set if not allowing duplicates
                if !options.allowDuplicates {
                    await self.clearAlreadyDiscovered()
                }

                // Emit discovered peripherals matching service UUIDs or solicited services
                for peripheral in await self.discoveredPeripherals.values {
                    // Check if already discovered (duplicate suppression)
                    if !options.allowDuplicates {
                        if await self.wasAlreadyDiscovered(peripheral.id) {
                            continue  // Skip duplicates
                        }
                    }

                    // Check if peripheral matches requested services
                    let matchesServices = serviceUUIDs.isEmpty ||
                        peripheral.advertisementData.serviceUUIDs.contains(
                            where: { serviceUUIDs.contains($0) }
                        )

                    // Check if peripheral matches solicited services
                    let matchesSolicited = !options.solicitedServiceUUIDs.isEmpty &&
                        peripheral.advertisementData.serviceUUIDs.contains(
                            where: { options.solicitedServiceUUIDs.contains($0) }
                        )

                    if matchesServices || matchesSolicited {
                        if await self.config.scanDelay > 0 {
                            try? await Task.sleep(
                                nanoseconds: UInt64(await self.config.scanDelay * 1_000_000_000)
                            )
                        }

                        // Mark as discovered
                        if !options.allowDuplicates {
                            await self.markAsDiscovered(peripheral.id)
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

    /// Check if peripheral was already discovered
    private func wasAlreadyDiscovered(_ peripheralID: UUID) -> Bool {
        alreadyDiscovered.contains(peripheralID)
    }

    /// Mark peripheral as discovered
    private func markAsDiscovered(_ peripheralID: UUID) {
        alreadyDiscovered.insert(peripheralID)
    }

    /// Clear already discovered set (for new scan)
    private func clearAlreadyDiscovered() {
        alreadyDiscovered.removeAll()
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

        guard discoveredPeripherals[peripheralID] != nil else {
            throw BleuError.peripheralNotFound(peripheralID)
        }

        // Track pending connection
        pendingConnections.insert(peripheralID)

        if config.connectionTimeout {
            try await Task.sleep(
                nanoseconds: UInt64(timeout * 1_000_000_000)
            )

            // Cancel connection before throwing (matches real CoreBluetooth behavior)
            if config.cancelConnectionOnTimeout {
                pendingConnections.remove(peripheralID)
                await eventChannel.send(.peripheralDisconnected(peripheralID, BleuError.connectionTimeout))
            }

            throw BleuError.connectionTimeout
        }

        if config.connectionDelay > 0 {
            try await Task.sleep(
                nanoseconds: UInt64(config.connectionDelay * 1_000_000_000)
            )
        }

        // Remove from pending and add to connected
        pendingConnections.remove(peripheralID)
        connectedPeripherals.insert(peripheralID)

        // Register MTU based on configuration mode
        let mtu = await maximumWriteValueLength(for: peripheralID, type: .withResponse) ?? 512
        await BLETransport.shared.updateMaxPayloadSize(for: peripheralID, maxWriteLength: mtu)

        await eventChannel.send(.peripheralConnected(peripheralID))
    }

    public func disconnect(from peripheralID: UUID) async throws {
        connectedPeripherals.remove(peripheralID)

        // Clean up MTU registration
        await BLETransport.shared.removeMTU(for: peripheralID)
        peripheralMTU.removeValue(forKey: peripheralID)

        // Clean up write queue state
        writeQueueReady.removeValue(forKey: peripheralID)

        // Clean up subscriptions
        notifyingCharacteristics.removeValue(forKey: peripheralID)

        // Notify peripheral side via bridge
        if config.useBridge, let bridge = config.bridge {
            await bridge.centralDisconnected(centralID: centralID, from: peripheralID)
        }

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

        // Error injection
        if let error = config.errorInjection.serviceDiscovery {
            throw error
        }

        // Random failure simulation
        if config.errorInjection.connectionFailureRate > 0 {
            if Double.random(in: 0...1) < config.errorInjection.connectionFailureRate {
                throw BleuError.rpcFailed("Random discovery failure (simulated)")
            }
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

        // Error injection
        if let error = config.errorInjection.characteristicDiscovery {
            throw error
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

        // Error injection
        if let error = config.errorInjection.readOperation {
            throw error
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

        // Error injection
        if let error = config.errorInjection.writeOperation {
            throw error
        }

        // Write type differentiation
        if config.differentiateWriteTypes {
            switch type {
            case .withResponse:
                // Simulate confirmation wait (matches real CoreBluetooth)
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    Task {
                        // Simulate confirmation delay
                        try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms

                        // Store the value
                        if characteristicValues[peripheralID] == nil {
                            characteristicValues[peripheralID] = [:]
                        }
                        characteristicValues[peripheralID]?[characteristicUUID] = data

                        // Forward to bridge if enabled
                        if config.useBridge, let bridge = config.bridge {
                            do {
                                try await bridge.centralWrite(
                                    from: centralID,
                                    to: peripheralID,
                                    characteristicUUID: characteristicUUID,
                                    value: data
                                )
                                continuation.resume()
                            } catch {
                                continuation.resume(throwing: error)
                            }
                        } else {
                            continuation.resume()
                        }
                    }
                }

            case .withoutResponse:
                // No wait, just store (matches real CoreBluetooth)
                if characteristicValues[peripheralID] == nil {
                    characteristicValues[peripheralID] = [:]
                }
                characteristicValues[peripheralID]?[characteristicUUID] = data

                // Simulate queue filling (for realistic backpressure)
                await simulateQueueFilling(for: peripheralID)

                // Forward to bridge if enabled (no wait for response)
                if config.useBridge, let bridge = config.bridge {
                    try await bridge.centralWrite(
                        from: centralID,
                        to: peripheralID,
                        characteristicUUID: characteristicUUID,
                        value: data
                    )
                }

            @unknown default:
                throw BleuError.operationNotSupported
            }
        } else {
            // Backward compatible: no differentiation
            if characteristicValues[peripheralID] == nil {
                characteristicValues[peripheralID] = [:]
            }
            characteristicValues[peripheralID]?[characteristicUUID] = data

            // Forward to bridge if enabled
            if config.useBridge, let bridge = config.bridge {
                try await bridge.centralWrite(
                    from: centralID,  // Use consistent central ID for routing
                    to: peripheralID,
                    characteristicUUID: characteristicUUID,
                    value: data
                )
            }
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

        // Error injection
        if let error = config.errorInjection.notificationSubscription {
            throw error
        }

        if enabled {
            if notifyingCharacteristics[peripheralID] == nil {
                notifyingCharacteristics[peripheralID] = []
            }
            notifyingCharacteristics[peripheralID]?.insert(characteristicUUID)

            // Register with bridge to receive notifications
            if config.useBridge, let bridge = config.bridge {
                await bridge.registerCentral(
                    centralID,  // Use consistent central ID for routing
                    for: peripheralID,
                    characteristicUUID: characteristicUUID,
                    notificationHandler: { [weak self] charUUID, data in
                        guard let self = self else { return }
                        // Send notification event to local system
                        await self.eventChannel.send(.characteristicValueUpdated(
                            peripheralID,
                            UUID(),  // service UUID
                            charUUID,
                            data,
                            nil  // no error in mock
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

        // Return MTU based on configuration mode
        switch config.mtuMode {
        case .fixed(let value):
            // Fixed MTU (default 512 for backward compatibility)
            return value

        case .realistic(let min, let max):
            // Realistic MTU variation per peripheral
            // Cache MTU so same peripheral gets consistent value
            if let cached = peripheralMTU[peripheralID] {
                return cached
            }

            // Common real-world MTU values from various iOS/macOS devices
            // BLE 4.0 min: 23, iOS default: 185, BLE 5.0 max: 251, iOS max: 512
            let realisticValues = [23, 27, 158, 185, 247, 251, 512].filter { $0 >= min && $0 <= max }
            let mtu = realisticValues.randomElement() ?? min
            peripheralMTU[peripheralID] = mtu
            return mtu

        case .actual:
            // iOS default MTU (for more realistic testing)
            return 185
        }
    }

    /// Check if peripheral's write queue is ready to accept writeWithoutResponse
    /// Simulates CoreBluetooth's canSendWriteWithoutResponse
    public func canSendWriteWithoutResponse(for peripheralID: UUID) async -> Bool {
        guard connectedPeripherals.contains(peripheralID) else {
            return false
        }

        switch config.writeQueueBehavior {
        case .alwaysReady:
            // Default: always ready (backward compatible)
            return true

        case .realistic(_):
            // Realistic: check queue state
            // Initially true, becomes false after queueSize writes
            let isReady = writeQueueReady[peripheralID] ?? true

            if !isReady {
                // Simulate queue draining (ready callback simulation)
                // In real CoreBluetooth, peripheralIsReadyToSendWriteWithoutResponse is called
                // Here we simulate it by randomly marking as ready
                if Bool.random() {
                    writeQueueReady[peripheralID] = true
                    // Note: Real CoreBluetooth would call peripheralIsReadyToSendWriteWithoutResponse delegate
                    // This is a simplified simulation for testing
                    return true
                }
            }

            return isReady
        }
    }

    /// Simulate write queue becoming full (for realistic mode)
    /// This is called internally after writes to simulate queue filling up
    private func simulateQueueFilling(for peripheralID: UUID) async {
        guard case .realistic(let queueSize) = config.writeQueueBehavior else {
            return
        }

        // Randomly mark queue as full based on queue size
        // Smaller queue = higher probability of filling
        let fillProbability = 1.0 / Double(queueSize)
        if Double.random(in: 0...1) < fillProbability {
            writeQueueReady[peripheralID] = false
        }
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
                value,
                nil  // no error in mock
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

    /// Simulate ATT error for testing error handling
    /// This simulates a characteristic value update with an error
    public func simulateATTError(for peripheralID: UUID) async {
        let error = NSError(
            domain: CBATTErrorDomain,
            code: CBATTError.invalidHandle.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "Simulated ATT error for testing"]
        )

        // Send characteristic value update with error
        // Use a dummy UUID since we're simulating an error scenario
        await eventChannel.send(.characteristicValueUpdated(
            peripheralID,
            UUID(),  // service UUID (not important for error case)
            UUID(),  // characteristic UUID (not important for error case)
            nil,     // no data on error
            error    // the ATT error
        ))
    }
}
