import Foundation
import CoreBluetooth
import Distributed
import ActorRuntime
import os


/// Actor to manage system initialization state
public actor BLEActorSystemBootstrap {
    private var peripheralState: CBManagerState = .unknown
    private var centralState: CBManagerState = .unknown

    var isReady: Bool {
        peripheralState == .poweredOn && centralState == .poweredOn
    }

    func updatePeripheralState(_ state: CBManagerState) {
        peripheralState = state
    }

    func updateCentralState(_ state: CBManagerState) {
        centralState = state
    }
}

private extension AdvertisementData {
    func advertisedActorID(for serviceUUID: UUID) -> UUID? {
        guard let data = serviceData[serviceUUID] else {
            return nil
        }
        return UUID(data: data)
    }
}

/// Distributed Actor System for BLE communication
/// Note: This class is inherently thread-safe because all mutable state is managed
/// through actors (ProxyManager, BLEActorSystemBootstrap) or immutable/sendable references
public final class BLEActorSystem: DistributedActorSystem, Sendable {
    public typealias ActorID = UUID
    public typealias InvocationDecoder = CodableInvocationDecoder
    public typealias InvocationEncoder = CodableInvocationEncoder
    public typealias ResultHandler = CodableResultHandler
    public typealias SerializationRequirement = Codable
    
    // Core components
    private let registry = ActorRegistry()  // Actor registry for distributed actors

    // BLE manager protocol instances (can be production or mock)
    private let peripheralManager: BLEPeripheralManagerProtocol
    private let centralManager: BLECentralManagerProtocol
    private let lifecycleTasks = LifecycleTaskManager()

    private actor LifecycleTaskManager {
        private var tasks: [Task<Void, Never>] = []
        private var isShutdown = false

        func add(contentsOf tasks: [Task<Void, Never>]) {
            guard !isShutdown else {
                for task in tasks {
                    task.cancel()
                }
                return
            }

            self.tasks.append(contentsOf: tasks)
        }

        func add(_ task: Task<Void, Never>) {
            guard !isShutdown else {
                task.cancel()
                return
            }

            tasks.append(task)
        }

        func active() -> Bool {
            !isShutdown
        }

        func shutdown() {
            isShutdown = true

            for task in tasks {
                task.cancel()
            }
            tasks.removeAll()
        }
    }

    private struct IncomingRPCRequest: Sendable {
        let data: Data
        let centralID: UUID
        let characteristicID: UUID
    }

    private actor IncomingRPCQueue {
        private var capacity: Int?
        private var pending: [IncomingRPCRequest] = []
        private var waiters: [CheckedContinuation<IncomingRPCRequest?, Never>] = []
        private var isShutdown = false

        func configure(capacity: Int) {
            self.capacity = max(1, capacity)
        }

        func enqueue(_ request: IncomingRPCRequest) -> Bool {
            guard !isShutdown, let capacity else {
                return false
            }

            if !waiters.isEmpty {
                let waiter = waiters.removeFirst()
                waiter.resume(returning: request)
                return true
            }

            guard pending.count < capacity else {
                return false
            }

            pending.append(request)
            return true
        }

        func next() async -> IncomingRPCRequest? {
            if !pending.isEmpty {
                return pending.removeFirst()
            }

            guard !isShutdown else {
                return nil
            }

            return await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }

        func shutdown() {
            isShutdown = true
            pending.removeAll()

            let continuations = waiters
            waiters.removeAll()
            for continuation in continuations {
                continuation.resume(returning: nil)
            }
        }
    }
    
    // Connection tracking
    private actor ProxyManager {
        private var peripheralProxies: [UUID: PeripheralActorProxy] = [:]
        private var pendingCalls: [String: CheckedContinuation<Data, Error>] = [:]
        private var peripheralCalls: [UUID: Set<String>] = [:]  // Track which calls belong to which peripheral
        private var callIDToPeripheral: [String: UUID] = [:]  // Reverse mapping for O(1) lookup
        private var pendingCallsQueue: [UUID: [String]] = [:]  // FIFO queue of pending calls per peripheral for ATT error handling
        private var timeoutTasks: [String: Task<Void, Never>] = [:]
        private var isShutdown = false

        /// Track calls cancelled before continuation was stored (timeout race fix)
        /// Includes timestamp for TTL-based cleanup to prevent memory leaks
        private var cancelledCalls: [String: (error: Error, timestamp: Date)] = [:]
        private let cancelledCallsTTL: TimeInterval = 30.0  // 30 seconds TTL
        private var cleanupTask: Task<Void, Never>?

        init() {
            Task { await self.startCleanupTaskIfNeeded() }
        }

        private func startCleanupTaskIfNeeded() {
            guard !isShutdown, cleanupTask == nil else {
                return
            }

            cleanupTask = Task { [weak self] in
                await self?.cleanupLoop()
            }
        }

        private func cleanupLoop() async {
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 10_000_000_000)
                } catch {
                    break
                }

                guard !isShutdown else {
                    break
                }

                cleanupStaleCancelledCalls()
            }
        }

        private func cleanupStaleCancelledCalls() {
            let now = Date()
            let staleIDs = cancelledCalls.filter {
                now.timeIntervalSince($0.value.timestamp) >= cancelledCallsTTL
            }.keys

            for callID in staleIDs {
                cancelledCalls.removeValue(forKey: callID)
                BleuLogger.actorSystem.debug("Cleaned up stale cancelled call: \(callID)")
            }
        }

        func get(_ id: UUID) -> PeripheralActorProxy? {
            return peripheralProxies[id]
        }

        func set(_ id: UUID, proxy: PeripheralActorProxy) {
            peripheralProxies[id] = proxy
        }

        func remove(_ id: UUID) {
            peripheralProxies.removeValue(forKey: id)
        }

        func hasProxy(_ id: UUID) -> Bool {
            return peripheralProxies[id] != nil
        }

        func hasRPCCharacteristic(_ characteristicID: UUID, for peripheralID: UUID) -> Bool {
            peripheralProxies.values.contains {
                $0.id == peripheralID && $0.rpcCharUUID == characteristicID
            }
        }

        // Pending call management
        func storePendingCall(
            _ callID: String,
            for peripheralID: UUID,
            continuation: CheckedContinuation<Data, Error>,
            timeoutNanoseconds: UInt64
        ) {
            guard !isShutdown else {
                continuation.resume(throwing: BleuError.disconnected)
                return
            }

            // CRITICAL RACE FIX: Check if this call was already cancelled (e.g., by timeout)
            // This can happen when timeout fires BEFORE the Task{} in withCheckedThrowingContinuation executes
            if let entry = cancelledCalls.removeValue(forKey: callID) {
                // Call was already cancelled - immediately resume with the error
                continuation.resume(throwing: entry.error)
                return
            }

            pendingCalls[callID] = continuation
            peripheralCalls[peripheralID, default: []].insert(callID)
            callIDToPeripheral[callID] = peripheralID

            // CONCURRENT RPC FIX: Track calls in FIFO queue for better ATT error matching
            // ATT errors typically affect the oldest pending request
            pendingCallsQueue[peripheralID, default: []].append(callID)

            timeoutTasks[callID] = Task { [weak self] in
                do {
                    try await Task.sleep(nanoseconds: timeoutNanoseconds)
                    await self?.cancelPendingCall(callID, error: BleuError.connectionTimeout)
                } catch {}
            }
        }

        func resumePendingCall(_ callID: String, with result: Result<Data, Error>) {
            if let continuation = removePendingCall(callID) {
                continuation.resume(with: result)
            }
        }

        func cancelPendingCall(_ callID: String, error: Error) {
            if let continuation = removePendingCall(callID) {
                // Continuation exists - resume it with error
                continuation.resume(throwing: error)
            } else {
                guard !isShutdown else {
                    return
                }

                // CRITICAL RACE FIX: Continuation not yet stored (timeout won race)
                // Store the error with timestamp so storePendingCall can handle it when it arrives
                // TTL-based cleanup prevents memory leaks if storePendingCall is never called
                cancelledCalls[callID] = (error: error, timestamp: Date())

                // Also remove from FIFO queue
                if let peripheralID = callIDToPeripheral.removeValue(forKey: callID) {
                    if let index = pendingCallsQueue[peripheralID]?.firstIndex(of: callID) {
                        pendingCallsQueue[peripheralID]?.remove(at: index)
                        if pendingCallsQueue[peripheralID]?.isEmpty == true {
                            pendingCallsQueue.removeValue(forKey: peripheralID)
                        }
                    }
                }
            }
        }

        private func removePendingCall(_ callID: String) -> CheckedContinuation<Data, Error>? {
            let continuation = pendingCalls.removeValue(forKey: callID)

            timeoutTasks.removeValue(forKey: callID)?.cancel()

            if let peripheralID = callIDToPeripheral.removeValue(forKey: callID) {
                peripheralCalls[peripheralID]?.remove(callID)
                if peripheralCalls[peripheralID]?.isEmpty == true {
                    peripheralCalls.removeValue(forKey: peripheralID)
                }

                if let index = pendingCallsQueue[peripheralID]?.firstIndex(of: callID) {
                    pendingCallsQueue[peripheralID]?.remove(at: index)
                    if pendingCallsQueue[peripheralID]?.isEmpty == true {
                        pendingCallsQueue.removeValue(forKey: peripheralID)
                    }
                }
            }

            return continuation
        }

        /// Cancel the oldest pending call for a peripheral (for ATT errors)
        /// CONCURRENT RPC FIX: ATT errors typically affect the oldest pending request in FIFO order
        /// This is a best-effort approach since CoreBluetooth doesn't provide exact callID mapping
        func cancelOldestPendingCall(for peripheralID: UUID, error: Error) -> String? {
            // Get the oldest pending call from FIFO queue
            guard let oldestCallID = pendingCallsQueue[peripheralID]?.first else {
                // No pending calls - ATT error for already-completed request
                BleuLogger.actorSystem.debug("ATT error for peripheral \(peripheralID) but no pending calls - likely already completed")
                return nil
            }

            // Check if this call is actually still pending
            guard pendingCalls[oldestCallID] != nil else {
                // Call already completed but still in queue - remove and try next
                pendingCallsQueue[peripheralID]?.removeFirst()
                if pendingCallsQueue[peripheralID]?.isEmpty == true {
                    pendingCallsQueue.removeValue(forKey: peripheralID)
                }
                BleuLogger.actorSystem.debug("Oldest call \(oldestCallID) already completed - trying next in queue")
                return cancelOldestPendingCall(for: peripheralID, error: error)
            }

            BleuLogger.actorSystem.debug("Canceling oldest pending call \(oldestCallID) for peripheral \(peripheralID) due to ATT error")
            cancelPendingCall(oldestCallID, error: error)
            return oldestCallID
        }

        func cancelAllPendingCalls(for peripheralID: UUID, error: Error) {
            // Cancel ALL calls for this specific peripheral (used for disconnection)
            guard let callIDs = peripheralCalls.removeValue(forKey: peripheralID) else {
                return
            }

            for callID in callIDs {
                if let continuation = removePendingCall(callID) {
                    continuation.resume(throwing: error)
                }
            }

            // CONCURRENT RPC FIX: Clean up FIFO queue
            pendingCallsQueue.removeValue(forKey: peripheralID)
        }

        /// Shutdown ProxyManager and cancel all background tasks
        /// This method is idempotent and safe to call multiple times
        func shutdown() {
            isShutdown = true

            // Cancel cleanup task
            cleanupTask?.cancel()
            cleanupTask = nil

            for task in timeoutTasks.values {
                task.cancel()
            }
            timeoutTasks.removeAll()

            // Clear all state
            cancelledCalls.removeAll()
            peripheralProxies.removeAll()
            pendingCallsQueue.removeAll()
            peripheralCalls.removeAll()
            callIDToPeripheral.removeAll()

            for continuation in pendingCalls.values {
                continuation.resume(throwing: BleuError.disconnected)
            }
            pendingCalls.removeAll()
        }
    }
    
    private let proxyManager = ProxyManager()
    private let bootstrap = BLEActorSystemBootstrap()
    private let diagnostics = BleuDiagnostics()
    private let incomingRPCQueue = IncomingRPCQueue()

    public var diagnosticEvents: AsyncStream<BleuDiagnosticEvent> {
        diagnostics.events
    }

    public func diagnosticSnapshot() async -> [BleuDiagnosticEvent] {
        await diagnostics.snapshot()
    }

    public func diagnosticMetrics() async -> BleuDiagnosticMetrics {
        await diagnostics.currentMetrics()
    }

    /// Check if the system is ready for operations
    public var ready: Bool {
        get async {
            await bootstrap.isReady
        }
    }

    /// Shutdown the actor system and release all resources
    ///
    /// This method:
    /// - Cancels all background cleanup tasks
    /// - Clears internal state (proxies, pending calls)
    /// - Does NOT disconnect active BLE connections (caller should do this explicitly if needed)
    ///
    /// This method is idempotent and safe to call multiple times.
    /// After shutdown, the system should not be used for new operations.
    public func shutdown() async {
        await incomingRPCQueue.shutdown()
        await lifecycleTasks.shutdown()
        await proxyManager.shutdown()
        registry.clear()
        await diagnostics.finish()
        BleuLogger.actorSystem.info("BLEActorSystem shutdown complete")
    }

    // MARK: - Initialization (Internal with DI)

    /// Public initializer with dependency injection
    /// - Parameters:
    ///   - peripheralManager: BLE peripheral manager implementation
    ///   - centralManager: BLE central manager implementation
    /// - Note: Managers should have their initialize() method called BEFORE or during construction
    /// - Note: This initializer is primarily used for testing with mock implementations
    public init(
        peripheralManager: BLEPeripheralManagerProtocol,
        centralManager: BLECentralManagerProtocol
    ) {
        self.peripheralManager = peripheralManager
        self.centralManager = centralManager

        let bootstrapTask = Task { [peripheralManager, centralManager, bootstrap, lifecycleTasks] in
            guard await lifecycleTasks.active() else {
                return
            }

            // Snapshot initial states without parking this lifecycle task in manager continuations.
            let peripheralState = await peripheralManager.state
            let centralState = await centralManager.state

            guard await lifecycleTasks.active() else {
                return
            }

            // Update bootstrap with actual states (may not be .poweredOn)
            await bootstrap.updatePeripheralState(peripheralState)
            await bootstrap.updateCentralState(centralState)
        }
        Task { [lifecycleTasks] in
            await lifecycleTasks.add(bootstrapTask)
        }

        // Setup BLE event listeners
        let listenerSetupTask = Task { [weak self] in
            guard let self = self else {
                return
            }

            await self.setupEventListeners()
        }
        Task { [lifecycleTasks] in
            await lifecycleTasks.add(listenerSetupTask)
        }
    }

    /// Setup event listeners for BLE notifications and responses
    private func setupEventListeners() async {
        let configuration = await BleuConfigurationManager.shared.current()
        await incomingRPCQueue.configure(capacity: configuration.incomingRPCQueueCapacity)

        // Listen to central manager events for characteristic value updates (RPC responses)
        let centralTask = Task { [weak self, centralManager, lifecycleTasks] in
            guard await lifecycleTasks.active() else {
                return
            }

            for await event in centralManager.events {
                if Task.isCancelled {
                    break
                }

                guard await lifecycleTasks.active() else {
                    break
                }

                await self?.handleBLEEvent(event)
            }
        }

        // Listen to peripheral manager events for incoming RPC requests
        let peripheralTask = Task { [weak self, peripheralManager, lifecycleTasks] in
            guard await lifecycleTasks.active() else {
                return
            }

            for await event in peripheralManager.events {
                if Task.isCancelled {
                    break
                }

                guard await lifecycleTasks.active() else {
                    break
                }

                await self?.handlePeripheralEvent(event)
            }
        }

        var rpcWorkerTasks: [Task<Void, Never>] = []
        for _ in 0..<max(1, configuration.maxConcurrentIncomingRPCs) {
            let workerTask = Task { [weak self, lifecycleTasks] in
                while !Task.isCancelled {
                    guard await lifecycleTasks.active() else {
                        break
                    }

                    guard let self = self else {
                        break
                    }

                    guard let request = await self.incomingRPCQueue.next() else {
                        break
                    }

                    await self.processIncomingRPC(
                        request.data,
                        from: request.centralID,
                        characteristicUUID: request.characteristicID
                    )
                }
            }
            rpcWorkerTasks.append(workerTask)
        }

        await lifecycleTasks.add(contentsOf: [centralTask, peripheralTask] + rpcWorkerTasks)
    }

    /// Handle BLE events from central manager (responses to our RPCs)
    private func handleBLEEvent(_ event: BLEEvent) async {
        switch event {
        case .stateChanged(let state):
            // Update central manager state in bootstrap
            await bootstrap.updateCentralState(state)

        case .characteristicValueUpdated(let peripheralID, _, let characteristicID, let data, let error):
            // This is a response to an RPC call we made
            guard await proxyManager.hasRPCCharacteristic(characteristicID, for: peripheralID) else {
                return
            }

            // Check for ATT error first and fail the most recent call
            if let error = error {
                BleuLogger.actorSystem.error("ATT error received for peripheral \(peripheralID): \(error)")

                // CONCURRENT RPC FIX: Cancel the oldest pending call (FIFO order).
                // CoreBluetooth does not provide the originating call ID for ATT errors.
                let matchedCallID = await proxyManager.cancelOldestPendingCall(for: peripheralID, error: error)

                if let matchedCallID {
                    await recordDiagnostic(
                        severity: .warning,
                        kind: .attErrorMatched,
                        message: "ATT error matched to oldest pending RPC",
                        peripheralID: peripheralID,
                        callID: matchedCallID,
                        error: error
                    )
                } else {
                    // No pending calls - ATT error likely for already-completed request or notification
                    BleuLogger.actorSystem.warning("ATT error but no pending call to cancel - may be stale or for notification")
                    await recordDiagnostic(
                        severity: .warning,
                        kind: .attErrorUnmatched,
                        message: "ATT error had no pending RPC to cancel",
                        peripheralID: peripheralID,
                        error: error
                    )
                }
                return
            }

            guard let data = data else { return }
            let transport = BLETransport.shared
            switch await transport.receive(data) {
            case .complete(let unpackedData):
                do {
                    let responseEnvelope = try JSONDecoder().decode(ResponseEnvelope.self, from: unpackedData)
                    // Resume the pending call with the response data
                    await proxyManager.resumePendingCall(responseEnvelope.callID, with: .success(unpackedData))
                } catch {
                    BleuLogger.actorSystem.error("Failed to decode response envelope: \(error)")
                    await recordDiagnostic(
                        severity: .error,
                        kind: .responseEnvelopeDecodeFailed,
                        message: "Failed to decode RPC response envelope",
                        peripheralID: peripheralID,
                        error: error
                    )
                }

            case .partial:
                return

            case .rejected(let reason):
                await recordDiagnostic(
                    severity: .warning,
                    kind: .transportPacketRejected,
                    message: "Rejected RPC response packet: \(reason)",
                    peripheralID: peripheralID
                )
            }

        case .peripheralDisconnected(let peripheralID, _):
            // Cancel all pending calls for this peripheral
            await proxyManager.cancelAllPendingCalls(
                for: peripheralID,
                error: BleuError.disconnected
            )

        default:
            break
        }
    }

    /// Handle BLE events from peripheral manager (incoming RPC requests)
    private func handlePeripheralEvent(_ event: BLEEvent) async {
        switch event {
        case .stateChanged(let state):
            // Update peripheral manager state in bootstrap
            await bootstrap.updatePeripheralState(state)

        case .writeRequestReceived(let central, _, let characteristicUUID, let data):
            // Reassemble inline (cheap, actor-serialized on BLETransport). Only a complete
            // message is dispatched; partial fragments return here and wait for more.
            let transport = BLETransport.shared
            switch await transport.receive(data) {
            case .complete(let unpackedData):
                guard await lifecycleTasks.active() else { return }
                let accepted = await incomingRPCQueue.enqueue(IncomingRPCRequest(
                    data: unpackedData,
                    centralID: central,
                    characteristicID: characteristicUUID
                ))

                if !accepted {
                    await recordDiagnostic(
                        severity: .error,
                        kind: .incomingRPCQueueFull,
                        message: "Incoming RPC queue is full; dropping request",
                        centralID: central,
                        characteristicID: characteristicUUID
                    )
                }

            case .partial:
                return

            case .rejected(let reason):
                await recordDiagnostic(
                    severity: .warning,
                    kind: .transportPacketRejected,
                    message: "Rejected incoming RPC packet: \(reason)",
                    centralID: central,
                    characteristicID: characteristicUUID
                )
            }

        default:
            break
        }
    }

    /// Decode, execute, and respond to a single incoming RPC invocation.
    /// Runs off the event-listener loop (see `handlePeripheralEvent`).
    private func processIncomingRPC(
        _ unpackedData: Data,
        from central: UUID,
        characteristicUUID: UUID
    ) async {
        let invocationEnvelope: InvocationEnvelope
        do {
            invocationEnvelope = try JSONDecoder().decode(InvocationEnvelope.self, from: unpackedData)
        } catch {
            BleuLogger.actorSystem.error("Failed to decode incoming RPC invocation: \(error)")
            await recordDiagnostic(
                severity: .error,
                kind: .incomingInvocationDecodeFailed,
                message: "Failed to decode incoming RPC invocation",
                centralID: central,
                characteristicID: characteristicUUID,
                error: error
            )
            return
        }

        let responseEnvelope = await handleIncomingRPC(invocationEnvelope)
        let responseData: Data
        do {
            responseData = try JSONEncoder().encode(responseEnvelope)
        } catch {
            BleuLogger.actorSystem.error("Failed to encode incoming RPC response: \(error)")
            await recordDiagnostic(
                severity: .error,
                kind: .incomingRPCResponseEncodeFailed,
                message: "Failed to encode incoming RPC response",
                centralID: central,
                characteristicID: characteristicUUID,
                callID: invocationEnvelope.callID,
                error: error
            )
            return
        }

        do {
            let transport = BLETransport.shared
            let packets = try await transport.fragment(responseData, for: central)
            for packet in packets {
                let packedData = await transport.packPacket(packet)
                let sent = try await peripheralManager.updateValue(
                    packedData,
                    for: characteristicUUID,
                    to: [central]
                )
                guard sent else {
                    throw BleuError.rpcFailed("Peripheral manager reported an unsent RPC response")
                }
            }
        } catch {
            BleuLogger.actorSystem.error("Failed to send incoming RPC response: \(error)")
            await recordDiagnostic(
                severity: .error,
                kind: .incomingRPCResponseSendFailed,
                message: "Failed to send incoming RPC response",
                centralID: central,
                characteristicID: characteristicUUID,
                callID: invocationEnvelope.callID,
                error: error
            )
        }
    }

    // MARK: - Factory Methods

    /// Create production instance with real CoreBluetooth (async version - recommended)
    /// - Parameter timeout: Maximum time to wait for Bluetooth to be ready (default: 30s)
    /// - Returns: BLEActorSystem guaranteed to be ready for use
    /// - Throws: BleuError if Bluetooth state prevents initialization
    /// - Note: Requires Bluetooth permissions (TCC)
    /// - Warning: Will trigger TCC permission check on iOS/macOS
    public static func create(timeout: TimeInterval = 30.0) async throws -> BLEActorSystem {
        let peripheral = CoreBluetoothPeripheralManager()
        let central = CoreBluetoothCentralManager()

        // Initialize managers and wait for completion
        await peripheral.initialize()  // TCC check happens here
        await central.initialize()     // TCC check happens here

        let system = BLEActorSystem(
            peripheralManager: peripheral,
            centralManager: central
        )

        // Wait for system to be ready with proper error handling
        try await waitForReady(
            system: system,
            peripheralManager: peripheral,
            centralManager: central,
            timeout: timeout
        )

        return system
    }

    /// Wait for BLEActorSystem to be ready with proper error handling
    /// - Parameters:
    ///   - system: The BLEActorSystem to wait for
    ///   - peripheralManager: Peripheral manager to check state
    ///   - centralManager: Central manager to check state
    ///   - timeout: Maximum time to wait
    /// - Throws: BleuError if Bluetooth state prevents initialization
    /// - Note: `internal` so test factories (e.g. `mock()`) can reuse this instead of duplicating it.
    internal static func waitForReady(
        system: BLEActorSystem,
        peripheralManager: BLEPeripheralManagerProtocol,
        centralManager: BLECentralManagerProtocol,
        timeout: TimeInterval
    ) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        let checkInterval: UInt64 = 50_000_000  // 50ms

        while true {
            // Check if ready
            if await system.ready {
                return
            }

            // Get current states
            let peripheralState = await peripheralManager.state
            let centralState = await centralManager.state

            // Check for unrecoverable states (fail fast)
            if peripheralState == .unsupported || centralState == .unsupported {
                throw BleuError.bluetoothUnavailable
            }

            if peripheralState == .unauthorized || centralState == .unauthorized {
                throw BleuError.bluetoothUnauthorized
            }

            // Check timeout
            if Date() > deadline {
                if peripheralState == .poweredOff || centralState == .poweredOff {
                    throw BleuError.bluetoothPoweredOff
                }
                throw BleuError.connectionTimeout
            }

            try await Task.sleep(nanoseconds: checkInterval)
        }
    }

    /// Create production instance with real CoreBluetooth
    /// - Note: Requires Bluetooth permissions (TCC)
    /// - Warning: Will trigger TCC permission check on iOS/macOS
    /// - Warning: System may not be ready immediately. Check `ready` property or use `create()` instead.
    public static func production() -> BLEActorSystem {
        let peripheral = CoreBluetoothPeripheralManager()
        let central = CoreBluetoothCentralManager()

        // Initialize managers BEFORE creating BLEActorSystem
        Task {
            await peripheral.initialize()  // TCC check happens here
            await central.initialize()     // TCC check happens here
        }

        return BLEActorSystem(
            peripheralManager: peripheral,
            centralManager: central
        )
    }

    // MARK: - Backward Compatibility

    /// Shared instance - uses production() by default
    /// - Warning: Requires Bluetooth permissions
    /// - Note: Existing code using `.shared` continues to work unchanged
    public static let shared: BLEActorSystem = .production()

    /// Legacy initializer for backward compatibility
    /// - Note: Creates production instance identical to `.shared`
    /// - Warning: Requires Bluetooth permissions (TCC)
    public convenience init() {
        // Create dependencies directly without going through .production()
        let peripheral = CoreBluetoothPeripheralManager()
        let central = CoreBluetoothCentralManager()

        // Pass uninitialized managers to internal init
        self.init(
            peripheralManager: peripheral,
            centralManager: central
        )

        // Start initialization after BLEActorSystem is constructed
        Task {
            await peripheral.initialize()
            await central.initialize()
        }
    }
    
    /// Setup event handlers for BLE events
    // MARK: - DistributedActorSystem Protocol
    
    public func resolve<Act>(id: ActorID, as actorType: Act.Type) throws -> Act?
        where Act: DistributedActor, Act.ID == ActorID {
        
        // Note: resolve() cannot be async per the DistributedActorSystem protocol
        // Return nil to let the system create actor proxies
        // The actual proxy management happens in setupRemoteProxy
        return nil
    }
    
    public func assignID<Act>(_ actorType: Act.Type) -> ActorID
        where Act: DistributedActor, Act.ID == ActorID {
        return UUID()
    }
    
    public func actorReady<Act>(_ actor: Act)
        where Act: DistributedActor, Act.ID == ActorID {
        registry.register(actor, id: actor.id.uuidString)
    }

    public func resignID(_ id: ActorID) {
        registry.unregister(id: id.uuidString)
        Task {
            await proxyManager.remove(id)
        }
    }
    
    public func makeInvocationEncoder() -> InvocationEncoder {
        return CodableInvocationEncoder()
    }
    
    // MARK: - Remote Invocation
    
    public func remoteCall<Act, Err, Res>(
        on actor: Act,
        target: Distributed.RemoteCallTarget,
        invocation: inout InvocationEncoder,
        throwing: Err.Type,
        returning: Res.Type
    ) async throws -> Res
        where Act: DistributedActor,
              Act.ID == ActorID,
              Err: Error,
              Res: SerializationRequirement {

        // Check if actor is in local registry (same process - mock mode)
        if let targetActor = registry.find(id: actor.id.uuidString) {
            // Same-process execution (like InMemoryActorSystem)
            var encoder = invocation
            encoder.recordTarget(target)
            let envelope = try encoder.makeInvocationEnvelope(recipientID: actor.id.uuidString)
            var decoder = try CodableInvocationDecoder(envelope: envelope)

            var capturedResult: Result<Res, Error>?
            let handler = CodableResultHandler(callID: envelope.callID) { response in
                switch response.result {
                case .success(let data):
                    capturedResult = .success(try JSONDecoder().decode(Res.self, from: data))
                case .void:
                    // Void-returning methods resolve through remoteCallVoid, which sets
                    // Res == VoidResult. `() as! VoidResult` would trap, so construct the
                    // expected result type explicitly (mirrors the cross-process path).
                    if Res.self == VoidResult.self {
                        capturedResult = .success(VoidResult() as! Res)
                    } else {
                        capturedResult = .success(() as! Res)
                    }
                case .failure(let error):
                    capturedResult = .failure(error)
                }
            }

            try await executeDistributedTarget(
                on: targetActor,
                target: target,
                invocationDecoder: &decoder,
                handler: handler
            )

            guard let result = capturedResult else {
                throw BleuError.rpcFailed("No result captured from distributed target execution")
            }
            return try result.get()
        }

        // Cross-process execution (real BLE transport)
        return try await executeCrossProcess(
            on: actor,
            target: target,
            invocation: &invocation,
            returning: Res.self
        )
    }

    /// Execute a remote call via BLE transport (cross-process)
    private func executeCrossProcess<Act, Res>(
        on actor: Act,
        target: Distributed.RemoteCallTarget,
        invocation: inout InvocationEncoder,
        returning: Res.Type
    ) async throws -> Res
        where Act: DistributedActor,
              Act.ID == ActorID,
              Res: SerializationRequirement {

        // 1. Get proxy for the remote peripheral
        guard let proxy = await proxyManager.get(actor.id) else {
            throw BleuError.peripheralNotFound(actor.id)
        }

        // 2. Create invocation envelope
        var encoder = invocation
        encoder.recordTarget(target)
        let envelope = try encoder.makeInvocationEnvelope(
            recipientID: actor.id.uuidString,
            senderID: nil
        )

        // 3. Serialize envelope to data
        let envelopeData = try JSONEncoder().encode(envelope)

        // 4. Send via BLE and wait for response with the configured RPC timeout
        let rpcTimeout = await BleuConfigurationManager.shared.current().rpcTimeout
        let timeoutNanoseconds = UInt64(rpcTimeout * 1_000_000_000)
        let responseData: Data
        responseData = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Task { [weak self] in
                    guard let self = self else {
                        continuation.resume(throwing: BleuError.actorNotFound(actor.id))
                        return
                    }

                    await self.proxyManager.storePendingCall(
                        envelope.callID,
                        for: proxy.id,
                        continuation: continuation,
                        timeoutNanoseconds: timeoutNanoseconds
                    )

                    do {
                        try await proxy.sendMessage(envelopeData)
                    } catch {
                        await self.proxyManager.cancelPendingCall(envelope.callID, error: error)
                    }
                }
            }
        } onCancel: {
            Task { [proxyManager] in
                await proxyManager.cancelPendingCall(envelope.callID, error: CancellationError())
            }
        }

        // 5. Deserialize response envelope
        let responseEnvelope = try JSONDecoder().decode(ResponseEnvelope.self, from: responseData)

        // 6. Extract result
        switch responseEnvelope.result {
        case .success(let data):
            return try JSONDecoder().decode(Res.self, from: data)
        case .void:
            // Handle VoidResult specifically for void-returning methods
            if Res.self == VoidResult.self {
                return VoidResult() as! Res
            } else {
                return () as! Res
            }
        case .failure(let error):
            throw convertRuntimeError(error)
        }
    }
    
    public func remoteCallVoid<Act, Err>(
        on actor: Act,
        target: Distributed.RemoteCallTarget,
        invocation: inout InvocationEncoder,
        throwing: Err.Type
    ) async throws
        where Act: DistributedActor,
              Act.ID == ActorID,
              Err: Error {
        
        let _: VoidResult = try await remoteCall(
            on: actor,
            target: target,
            invocation: &invocation,
            throwing: throwing,
            returning: VoidResult.self
        )
    }
    
    // MARK: - Local Invocation Support
    
    /// Execute a distributed target locally (called by peripheral when receiving RPC)
    /// This delegates to Swift's global executeDistributedTarget function
    /// Implementation follows the same pattern as InMemoryActorSystem
    private func _executeDistributedTargetLocally<Act: DistributedActor>(
        on actor: Act,
        target: RemoteCallTarget,
        invocationDecoder: inout CodableInvocationDecoder,
        handler: CodableResultHandler
    ) async throws {
        // Call Swift's global executeDistributedTarget function
        // This is available from Swift 5.7+ via the Distributed module
        try await executeDistributedTarget(
            on: actor,
            target: target,
            invocationDecoder: &invocationDecoder,
            handler: handler
        )
    }
    
    /// Handle an incoming RPC invocation (decoded from a peripheral write request)
    public func handleIncomingRPC(_ envelope: InvocationEnvelope) async -> ResponseEnvelope {
        do {

            // Get the local actor instance from ActorRegistry (not InstanceRegistry actor)
            guard let actor = registry.find(id: envelope.recipientID) else {
                let error = RuntimeError.actorNotFound(envelope.recipientID)
                return ResponseEnvelope(callID: envelope.callID, result: .failure(error))
            }

            // Reconstruct RemoteCallTarget from string identifier
            let target = RemoteCallTarget(envelope.target)

            // Create InvocationDecoder from envelope
            var decoder = try CodableInvocationDecoder(envelope: envelope)

            // Create result handler that captures the response
            var capturedResponse: ResponseEnvelope?
            let resultHandler = CodableResultHandler(callID: envelope.callID) { response in
                capturedResponse = response
            }

            // Execute the distributed target using Swift's built-in mechanism
            try await _executeDistributedTargetLocally(
                on: actor,
                target: target,
                invocationDecoder: &decoder,
                handler: resultHandler
            )

            // Return the captured response
            guard let response = capturedResponse else {
                throw RuntimeError.executionFailed("No result captured", underlying: "Unknown")
            }

            return response

        } catch {
            // Convert BleuError or other errors to RuntimeError
            let runtimeError: RuntimeError
            if let bleuError = error as? BleuError {
                runtimeError = convertToRuntimeError(bleuError)
            } else if let runtimeError = error as? RuntimeError {
                return ResponseEnvelope(callID: envelope.callID, result: .failure(runtimeError))
            } else {
                // Provide more detailed error information for debugging
                let errorDescription = String(describing: error)
                let errorReflection = String(reflecting: error)
                runtimeError = .executionFailed(
                    "Method execution failed: \(errorDescription)",
                    underlying: errorReflection
                )
            }
            return ResponseEnvelope(callID: envelope.callID, result: .failure(runtimeError))
        }
    }
    
    // MARK: - Peripheral Mode
    
    /// Start advertising as a peripheral
    public func startAdvertising<T: PeripheralActor>(_ peripheral: T) async throws {
        // Ensure system is ready
        guard await ready else {
            throw BleuError.bluetoothUnavailable
        }

        // Get service metadata from the actor type
        let metadata = ServiceMapper.createServiceMetadata(from: T.self, actorID: peripheral.id)

        // Add service to peripheral manager
        try await peripheralManager.add(metadata)

        // Create advertisement data
        let advertisementData = AdvertisementData(
            localName: String(describing: T.self),
            serviceUUIDs: [metadata.uuid]
        )

        // Start advertising
        try await peripheralManager.startAdvertising(advertisementData)

        // Register the actor
        actorReady(peripheral)
    }

    /// Stop advertising
    public func stopAdvertising() async {
        await peripheralManager.stopAdvertising()
    }
    
    // MARK: - Central Mode
    
    /// Discover peripherals of a specific type
    ///
    /// This method scans for BLE peripherals advertising the service UUID
    /// associated with the specified actor type, connects to each discovered
    /// peripheral, and returns an array of ready-to-use actor references.
    ///
    /// - Parameter type: The distributed actor type to discover
    /// - Parameter timeout: Maximum time to scan for peripherals (default: 10.0s)
    /// - Returns: Array of connected, ready-to-use peripheral actors
    ///
    /// - Note: Peripherals that fail connection or setup are logged and skipped.
    ///         The method returns successfully with all successfully connected actors.
    public func discover<T: PeripheralActor>(
        _ type: T.Type,
        timeout: TimeInterval = 10.0
    ) async throws -> [T] {
        // Ensure system is ready
        guard await ready else {
            throw BleuError.bluetoothUnavailable
        }

        let serviceUUID = UUID.serviceUUID(for: type)
        let connectionTimeout = await BleuConfigurationManager.shared.current().connectionTimeout
        var discoveredActors: [T] = []
        var discoveredActorIDs = Set<UUID>()
        var discoveredPeripheralIDs = Set<UUID>()

        for await discovered in await centralManager.scanForPeripherals(
            withServices: [serviceUUID],
            timeout: timeout
        ) {
            guard !discoveredPeripheralIDs.contains(discovered.id) else {
                continue
            }
            discoveredPeripheralIDs.insert(discovered.id)

            var actorID = discovered.advertisementData.advertisedActorID(for: serviceUUID) ?? discovered.id
            guard !discoveredActorIDs.contains(actorID) else {
                continue
            }

            do {
                // Connect to the peripheral first
                try await centralManager.connect(to: discovered.id, timeout: connectionTimeout)

                // Update BLETransport MTU based on connected peripheral
                await updateTransportMTU(for: discovered.id)

                actorID = await resolveRemoteActorID(
                    from: discovered,
                    as: type,
                    serviceUUID: serviceUUID
                )
                guard !discoveredActorIDs.contains(actorID) else {
                    try await centralManager.disconnect(from: discovered.id)
                    continue
                }

                // Setup proxy for remote peripheral (now throws errors)
                try await setupRemoteProxy(
                    peripheralID: discovered.id,
                    actorID: actorID,
                    type: type
                )

                // Create remote actor reference
                let actor = try T.resolve(id: actorID, using: self)

                // Add to results
                discoveredActorIDs.insert(actorID)
                discoveredActors.append(actor)

                BleuLogger.actorSystem.info("Successfully discovered and connected to \(actorID)")

            } catch let error as BleuError {
                // Structured error logging for known error types
                switch error {
                case .connectionTimeout:
                    BleuLogger.actorSystem.warning("Connection timeout for \(discovered.id)")
                case .connectionFailed(let message):
                    BleuLogger.actorSystem.warning("Connection failed for \(discovered.id): \(message)")
                case .serviceNotFound(let uuid):
                    BleuLogger.actorSystem.warning("Service \(uuid) not found on \(discovered.id)")
                case .characteristicNotFound(let uuid):
                    BleuLogger.actorSystem.warning("Characteristic \(uuid) not found on \(discovered.id)")
                case .peripheralNotFound(let uuid):
                    BleuLogger.actorSystem.warning("Peripheral \(uuid) not found")
                default:
                    BleuLogger.actorSystem.warning("Setup failed for \(discovered.id): \(error)")
                }

                // Cleanup: remove any partial state and disconnect
                await cleanupPeripheralState(actorID: actorID, peripheralID: discovered.id)
                do {
                    try await centralManager.disconnect(from: discovered.id)
                } catch {
                    BleuLogger.actorSystem.warning("Failed to disconnect \(discovered.id) during cleanup: \(error)")
                }

                // Continue with next peripheral
                continue

            } catch {
                // Unexpected errors (non-BleuError)
                BleuLogger.actorSystem.error("Unexpected error setting up \(discovered.id): \(error)")

                // Cleanup: remove any partial state and disconnect
                await cleanupPeripheralState(actorID: actorID, peripheralID: discovered.id)
                do {
                    try await centralManager.disconnect(from: discovered.id)
                } catch {
                    BleuLogger.actorSystem.warning("Failed to disconnect \(discovered.id) during cleanup: \(error)")
                }

                // Continue with next peripheral
                continue
            }
        }

        return discoveredActors
    }
    
    /// Connect to a known peripheral by UUID
    public func connect<T: PeripheralActor>(
        to peripheralID: UUID,
        as type: T.Type
    ) async throws -> T {
        // Connect if not already connected
        let connectionTimeout = await BleuConfigurationManager.shared.current().connectionTimeout
        try await centralManager.connect(to: peripheralID, timeout: connectionTimeout)

        // Update BLETransport MTU based on connected peripheral
        await updateTransportMTU(for: peripheralID)

        // Setup proxy for remote peripheral (now throws)
        try await setupRemoteProxy(
            peripheralID: peripheralID,
            actorID: peripheralID,
            type: type
        )

        // Create remote actor reference
        let actor = try T.resolve(id: peripheralID, using: self)

        return actor
    }
    
    /// Disconnect from a peripheral
    public func disconnect(from peripheralID: UUID) async throws {
        let physicalPeripheralID = await proxyManager.get(peripheralID)?.id ?? peripheralID

        // Cleanup proxy and subscriptions before disconnecting
        await cleanupPeripheralState(actorID: peripheralID, peripheralID: physicalPeripheralID)

        defer { resignID(peripheralID) }
        try await centralManager.disconnect(from: physicalPeripheralID)
    }
    
    /// Check if connected to a peripheral
    public func isConnected(_ peripheralID: UUID) async -> Bool {
        return await proxyManager.hasProxy(peripheralID)
    }
    
    // MARK: - Private Helpers

    private func recordDiagnostic(
        severity: BleuDiagnosticSeverity,
        kind: BleuDiagnosticKind,
        message: String,
        peripheralID: UUID? = nil,
        centralID: UUID? = nil,
        characteristicID: UUID? = nil,
        callID: String? = nil,
        error: Error? = nil
    ) async {
        await diagnostics.record(BleuDiagnosticEvent(
            severity: severity,
            kind: kind,
            message: message,
            peripheralID: peripheralID,
            centralID: centralID,
            characteristicID: characteristicID,
            callID: callID,
            underlyingError: error.map { String(reflecting: $0) }
        ))
    }

    /// Cleanup all state associated with a peripheral
    /// - Parameter peripheralID: The UUID of the peripheral to cleanup
    /// - Note: This method is idempotent and safe to call multiple times
    private func cleanupPeripheralState(actorID: UUID, peripheralID: UUID) async {
        // Remove proxy from ProxyManager
        await proxyManager.remove(actorID)

        // Remove MTU entry from BLETransport
        let transport = BLETransport.shared
        await transport.removeMTU(for: peripheralID)

        BleuLogger.actorSystem.debug("Cleaned up state for actor \(actorID)")
    }

    /// Update BLETransport MTU based on connected peripheral
    private func updateTransportMTU(for peripheralID: UUID) async {
        // Get the maximum write value length for the connected peripheral
        if let maxWriteLength = await centralManager.maximumWriteValueLength(for: peripheralID, type: .withResponse) {
            let transport = BLETransport.shared
            // Store MTU per device to handle multiple connections with different MTUs
            await transport.updateMaxPayloadSize(for: peripheralID, maxWriteLength: maxWriteLength)
        }
    }

    private func resolveRemoteActorID<T: PeripheralActor>(
        from discovered: DiscoveredPeripheral,
        as type: T.Type,
        serviceUUID: UUID
    ) async -> UUID {
        if let advertisedActorID = discovered.advertisementData.advertisedActorID(for: serviceUUID) {
            return advertisedActorID
        }

        do {
            let actorIDCharacteristicUUID = UUID.characteristicUUID(for: "__actor_id__", in: type)
            let services = try await centralManager.discoverServices(
                for: discovered.id,
                serviceUUIDs: [serviceUUID]
            )
            guard !services.isEmpty else {
                return discovered.id
            }

            let characteristics = try await centralManager.discoverCharacteristics(
                for: serviceUUID,
                in: discovered.id,
                characteristicUUIDs: [actorIDCharacteristicUUID]
            )
            guard !characteristics.isEmpty else {
                return discovered.id
            }

            let data = try await centralManager.readValue(
                for: actorIDCharacteristicUUID,
                in: discovered.id
            )
            return UUID(data: data) ?? discovered.id
        } catch {
            BleuLogger.actorSystem.warning("Failed to resolve remote actor ID for \(discovered.id): \(error)")
            return discovered.id
        }
    }
    
    /// Setup a proxy for a remote peripheral
    /// - Precondition: The peripheral MUST be connected via the central manager
    /// - Throws: BleuError if setup fails
    /// - Note: This method is transactional - either all setup succeeds or nothing is registered
    private func setupRemoteProxy<T: PeripheralActor>(
        peripheralID: UUID,
        actorID: UUID,
        type: T.Type
    ) async throws {
        // Check if proxy already exists to prevent duplicates (idempotent)
        if await proxyManager.get(actorID) != nil {
            return
        }

        // Calculate service and RPC characteristic UUIDs for this actor type
        let serviceUUID = UUID.serviceUUID(for: type)
        let rpcCharUUID = UUID.characteristicUUID(for: "__rpc__", in: type)

        // Phase 1: Discovery (throws on failure, no cleanup needed)

        // Discover the actor's service
        let services = try await centralManager.discoverServices(
            for: peripheralID,
            serviceUUIDs: [serviceUUID]
        )

        guard !services.isEmpty else {
            throw BleuError.serviceNotFound(serviceUUID)
        }

        // Discover characteristics for the service
        let characteristics = try await centralManager.discoverCharacteristics(
            for: serviceUUID,
            in: peripheralID,
            characteristicUUIDs: [rpcCharUUID]
        )

        guard !characteristics.isEmpty else {
            throw BleuError.characteristicNotFound(rpcCharUUID)
        }

        // Phase 2: Enable notifications BEFORE registering (critical - must succeed first)
        do {
            try await centralManager.setNotifyValue(true, for: rpcCharUUID, in: peripheralID)
        } catch {
            // If notification setup fails, throw immediately (nothing registered yet)
            throw error
        }

        // Phase 3: Registration (only after all critical operations succeed)

        // Create a proxy for the remote peripheral with RPC characteristic
        let proxy = PeripheralActorProxy(
            id: peripheralID,
            centralManager: centralManager,
            rpcCharUUID: rpcCharUUID
        )

        await proxyManager.set(actorID, proxy: proxy)

        BleuLogger.actorSystem.debug("Successfully setup remote proxy for \(actorID)")
    }

    // MARK: - Error Conversion

    /// Convert RuntimeError to BleuError
    private func convertRuntimeError(_ error: RuntimeError) -> BleuError {
        switch error {
        case .actorNotFound(let id):
            if let uuid = UUID(uuidString: id) {
                return .actorNotFound(uuid)
            }
            return .invalidData
        case .actorDeallocated(let id):
            if let uuid = UUID(uuidString: id) {
                return .actorNotFound(uuid)
            }
            return .invalidData
        case .methodNotFound(let method):
            return .methodNotSupported(method)
        case .executionFailed(let message, _):
            return .rpcFailed(message)
        case .serializationFailed(_):
            return .invalidData
        case .transportFailed(let message):
            return .connectionFailed(message)
        case .timeout(_):
            return .connectionTimeout
        case .invalidEnvelope(_):
            return .invalidData
        case .versionMismatch(expected: _, actual: _):
            return .invalidData
        }
    }

    /// Convert BleuError to RuntimeError
    private func convertToRuntimeError(_ error: BleuError) -> RuntimeError {
        switch error {
        case .actorNotFound(let uuid):
            return .actorNotFound(uuid.uuidString)
        case .methodNotSupported(let method):
            return .methodNotFound(method)
        case .rpcFailed(let message):
            return .executionFailed("RPC failed", underlying: message)
        case .invalidData:
            return .serializationFailed("Invalid data")
        case .connectionFailed(let message):
            return .transportFailed(message)
        case .connectionTimeout:
            return .timeout(10.0)
        case .bluetoothUnavailable:
            return .transportFailed("Bluetooth unavailable")
        case .bluetoothUnauthorized:
            return .transportFailed("Bluetooth unauthorized")
        case .bluetoothPoweredOff:
            return .transportFailed("Bluetooth powered off")
        case .serviceNotFound(let uuid):
            return .transportFailed("Service not found: \(uuid)")
        case .characteristicNotFound(let uuid):
            return .transportFailed("Characteristic not found: \(uuid)")
        case .peripheralNotFound(let uuid):
            return .actorNotFound(uuid.uuidString)
        case .disconnected:
            return .transportFailed("Disconnected")
        case .incompatibleVersion(let detected, let required):
            return .versionMismatch(expected: String(required), actual: String(detected))
        case .quotaExceeded:
            return .transportFailed("Quota exceeded")
        case .operationNotSupported:
            return .transportFailed("Operation not supported")
        case .operationInProgress(let operation):
            return .transportFailed("Operation already in progress: \(operation)")
        case .fragmentationFailed(let message):
            return .transportFailed("Fragmentation failed: \(message)")
        }
    }
}

/// MARK: - Supporting Types

/// Internal type representing void/unit result for distributed actor calls
internal struct VoidResult: Codable {}

private struct PeripheralActorProxy {
    let id: UUID
    let centralManager: BLECentralManagerProtocol
    let rpcCharUUID: UUID

    func sendMessage(_ data: Data) async throws {
        // Use BLETransport for fragmentation if needed
        let transport = BLETransport.shared
        try await transport.send(
            data,
            to: id,
            using: centralManager,
            characteristicUUID: rpcCharUUID
        )
    }
}
