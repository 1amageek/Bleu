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
    
    // Connection tracking
    private actor ProxyManager {
        private var peripheralProxies: [UUID: PeripheralActorProxy] = [:]
        private var pendingCalls: [String: CheckedContinuation<Data, Error>] = [:]

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

        // Pending call management
        func storePendingCall(_ callID: String, continuation: CheckedContinuation<Data, Error>) {
            pendingCalls[callID] = continuation
        }

        func resumePendingCall(_ callID: String, with result: Result<Data, Error>) {
            if let continuation = pendingCalls.removeValue(forKey: callID) {
                continuation.resume(with: result)
            }
        }

        func cancelPendingCall(_ callID: String, error: Error) {
            if let continuation = pendingCalls.removeValue(forKey: callID) {
                continuation.resume(throwing: error)
            }
        }

        func cancelAllPendingCalls(for peripheralID: UUID, error: Error) {
            // Cancel all pending calls - we don't track by peripheral currently
            // This is a limitation that could be improved
            for (_, continuation) in pendingCalls {
                continuation.resume(throwing: error)
            }
            pendingCalls.removeAll()
        }
    }
    
    private let proxyManager = ProxyManager()
    private let bootstrap = BLEActorSystemBootstrap()

    /// Check if the system is ready for operations
    public var ready: Bool {
        get async {
            await bootstrap.isReady
        }
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

        Task {
            // Get initial states from managers
            let peripheralState = await peripheralManager.waitForPoweredOn()
            let centralState = await centralManager.waitForPoweredOn()

            // Update bootstrap with actual states (may not be .poweredOn)
            await bootstrap.updatePeripheralState(peripheralState)
            await bootstrap.updateCentralState(centralState)
        }

        // Setup BLE event listeners
        Task {
            await setupEventListeners()
        }
    }

    /// Setup event listeners for BLE notifications and responses
    private func setupEventListeners() async {
        // Listen to central manager events for characteristic value updates (RPC responses)
        Task {
            for await event in centralManager.events {
                await handleBLEEvent(event)
            }
        }

        // Listen to peripheral manager events for incoming RPC requests
        Task {
            for await event in peripheralManager.events {
                await handlePeripheralEvent(event)
            }
        }
    }

    /// Handle BLE events from central manager (responses to our RPCs)
    private func handleBLEEvent(_ event: BLEEvent) async {
        switch event {
        case .stateChanged(let state):
            // Update central manager state in bootstrap
            await bootstrap.updateCentralState(state)

        case .characteristicValueUpdated(let peripheralID, let serviceUUID, let characteristicUUID, let data):
            // This is a response to an RPC call we made
            guard let data = data else { return }
            do {
                // Unpack BLETransport packet if needed
                let transport = BLETransport.shared
                guard let unpackedData = await transport.receive(data) else {
                    BleuLogger.actorSystem.warning("Failed to reassemble response packet - may need more fragments")
                    return
                }
                let responseEnvelope = try JSONDecoder().decode(ResponseEnvelope.self, from: unpackedData)
                // Resume the pending call with the response data
                await proxyManager.resumePendingCall(responseEnvelope.callID, with: .success(unpackedData))
            } catch {
                BleuLogger.actorSystem.error("Failed to decode response envelope: \(error)")
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
            // This is an incoming RPC request
            do {

                // Unpack BLETransport packet if needed (could be fragmented)
                let transport = BLETransport.shared

                // Try to receive the data - this handles unpacking if it's a BLETransport packet
                // If it's not a packet (raw data), receive() returns it unchanged
                guard let unpackedData = await transport.receive(data) else {
                    BleuLogger.actorSystem.warning("Failed to reassemble packet - may need more fragments")
                    return
                }

                let invocationEnvelope = try JSONDecoder().decode(InvocationEnvelope.self, from: unpackedData)
                let responseEnvelope = await handleIncomingRPC(invocationEnvelope)
                let responseData = try JSONEncoder().encode(responseEnvelope)

                // Pack response with BLETransport for transmission
                let packets = await transport.fragment(responseData)
                for (index, packet) in packets.enumerated() {
                    let packedData = await transport.packPacket(packet)
                    // Send response back via notification to the specific central
                    _ = try await peripheralManager.updateValue(packedData, for: characteristicUUID, to: [central])
                }
            } catch {
                BleuLogger.actorSystem.error("Failed to handle write request: \(error)")
            }

        default:
            break
        }
    }

    // MARK: - Factory Methods

    /// Create production instance with real CoreBluetooth
    /// - Note: Requires Bluetooth permissions (TCC)
    /// - Warning: Will trigger TCC permission check on iOS/macOS
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
                    capturedResult = .success(() as! Res)
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

            return try capturedResult!.get()
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

        // 4. Send via BLE and wait for response with timeout
        let responseData = try await withThrowingTaskGroup(of: Data.self) { group in
            // Task 1: Send and wait for response
            group.addTask { [weak self] in
                guard let self = self else {
                    throw BleuError.actorNotFound(actor.id)
                }

                return try await withCheckedThrowingContinuation { continuation in
                    Task {
                        // Store continuation for when response arrives
                        await self.proxyManager.storePendingCall(envelope.callID, continuation: continuation)

                        // Send the request
                        do {
                            try await proxy.sendMessage(envelopeData)
                        } catch {
                            // If send fails, cancel the pending call
                            await self.proxyManager.cancelPendingCall(envelope.callID, error: error)
                        }
                    }
                }
            }

            // Task 2: Timeout
            group.addTask {
                try await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
                throw BleuError.connectionTimeout
            }

            // Wait for first result (either response or timeout)
            let result = try await group.next()!
            group.cancelAll()
            return result
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
    public func executeDistributedTarget<Act, Res>(
        on actor: Act,
        target: Distributed.RemoteCallTarget,
        invocationDecoder: inout InvocationDecoder,
        returning: Res.Type
    ) async throws -> Res
        where Act: DistributedActor,
              Act.ID == ActorID,
              Res: SerializationRequirement {
        
        // NOTE: This requires access to Swift's internal distributed actor runtime APIs
        // which are not publicly available. Will be implemented when Swift exposes these APIs.
        throw BleuError.methodNotSupported(target.identifier)
    }
    
    /// Handle an incoming RPC invocation (called by LocalPeripheralActor)
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
            try await executeDistributedTarget(
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
        let metadata = ServiceMapper.createServiceMetadata(from: T.self)

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
        var discoveredActors: [T] = []

        for await discovered in await centralManager.scanForPeripherals(
            withServices: [serviceUUID],
            timeout: timeout
        ) {
            do {
                // Connect to the peripheral first
                try await centralManager.connect(to: discovered.id, timeout: 10.0)

                // Update BLETransport MTU based on connected peripheral
                await updateTransportMTU(for: discovered.id)

                // Setup proxy for remote peripheral (now throws errors)
                try await setupRemoteProxy(id: discovered.id, type: type)

                // Create remote actor reference
                let actor = try T.resolve(id: discovered.id, using: self)

                // Add to results
                discoveredActors.append(actor)

                BleuLogger.actorSystem.info("Successfully discovered and connected to \(discovered.id)")

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
                await cleanupPeripheralState(discovered.id)
                try? await centralManager.disconnect(from: discovered.id)

                // Continue with next peripheral
                continue

            } catch {
                // Unexpected errors (non-BleuError)
                BleuLogger.actorSystem.error("Unexpected error setting up \(discovered.id): \(error)")

                // Cleanup: remove any partial state and disconnect
                await cleanupPeripheralState(discovered.id)
                try? await centralManager.disconnect(from: discovered.id)

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
        try await centralManager.connect(to: peripheralID, timeout: 10.0)

        // Update BLETransport MTU based on connected peripheral
        await updateTransportMTU(for: peripheralID)

        // Setup proxy for remote peripheral (now throws)
        try await setupRemoteProxy(id: peripheralID, type: type)

        // Create remote actor reference
        let actor = try T.resolve(id: peripheralID, using: self)

        return actor
    }
    
    /// Disconnect from a peripheral
    public func disconnect(from peripheralID: UUID) async throws {
        // Cleanup proxy and subscriptions before disconnecting
        await cleanupPeripheralState(peripheralID)

        defer { resignID(peripheralID) }
        try await centralManager.disconnect(from: peripheralID)
    }
    
    /// Check if connected to a peripheral
    public func isConnected(_ peripheralID: UUID) async -> Bool {
        return await proxyManager.hasProxy(peripheralID)
    }
    
    // MARK: - Private Helpers

    /// Cleanup all state associated with a peripheral
    /// - Parameter peripheralID: The UUID of the peripheral to cleanup
    /// - Note: This method is idempotent and safe to call multiple times
    private func cleanupPeripheralState(_ peripheralID: UUID) async {
        // Remove proxy from ProxyManager
        await proxyManager.remove(peripheralID)

        BleuLogger.actorSystem.debug("Cleaned up state for peripheral \(peripheralID)")
    }

    /// Update BLETransport MTU based on connected peripheral
    private func updateTransportMTU(for peripheralID: UUID) async {
        // Get the maximum write value length for the connected peripheral
        if let maxWriteLength = await centralManager.maximumWriteValueLength(for: peripheralID, type: .withResponse) {
            let transport = BLETransport.shared
            await transport.updateMaxPayloadSize(maxWriteLength: maxWriteLength)
        }
    }
    
    /// Setup a proxy for a remote peripheral
    /// - Precondition: The peripheral MUST be connected via LocalCentralActor
    /// - Throws: BleuError if setup fails
    /// - Note: This method is transactional - either all setup succeeds or nothing is registered
    private func setupRemoteProxy<T: PeripheralActor>(id: UUID, type: T.Type) async throws {
        // Check if proxy already exists to prevent duplicates (idempotent)
        if await proxyManager.get(id) != nil {
            return
        }

        // Calculate service and RPC characteristic UUIDs for this actor type
        let serviceUUID = UUID.serviceUUID(for: type)
        let rpcCharUUID = UUID.characteristicUUID(for: "__rpc__", in: type)

        // Phase 1: Discovery (throws on failure, no cleanup needed)

        // Discover the actor's service
        let services = try await centralManager.discoverServices(
            for: id,
            serviceUUIDs: [serviceUUID]
        )

        guard !services.isEmpty else {
            throw BleuError.serviceNotFound(serviceUUID)
        }

        // Discover characteristics for the service
        let characteristics = try await centralManager.discoverCharacteristics(
            for: serviceUUID,
            in: id,
            characteristicUUIDs: [rpcCharUUID]
        )

        guard !characteristics.isEmpty else {
            throw BleuError.characteristicNotFound(rpcCharUUID)
        }

        // Phase 2: Enable notifications BEFORE registering (critical - must succeed first)
        do {
            try await centralManager.setNotifyValue(true, for: rpcCharUUID, in: id)
        } catch {
            // If notification setup fails, throw immediately (nothing registered yet)
            throw error
        }

        // Phase 3: Registration (only after all critical operations succeed)

        // Create a proxy for the remote peripheral with RPC characteristic
        let proxy = PeripheralActorProxy(
            id: id,
            centralManager: centralManager,
            rpcCharUUID: rpcCharUUID
        )

        await proxyManager.set(id, proxy: proxy)

        BleuLogger.actorSystem.debug("Successfully setup remote proxy for \(id)")
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
