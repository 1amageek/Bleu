import Foundation
import CoreBluetooth
import Distributed
import ActorRuntime
import os

/// Actor to manage system initialization state
public actor BLEActorSystemBootstrap {
    private(set) var isReady = false
    
    func markReady() {
        isReady = true
    }
}

/// Distributed Actor System for BLE communication
/// Note: This class is inherently thread-safe because all mutable state is managed
/// through actors (ProxyManager, BLEActorSystemBootstrap) or immutable/sendable references
public final class BLEActorSystem: DistributedActorSystem, Sendable {
    public typealias ActorID = UUID
    public typealias InvocationDecoder = BLEInvocationDecoder
    public typealias InvocationEncoder = BLEInvocationEncoder
    public typealias ResultHandler = BLEResultHandler
    public typealias SerializationRequirement = Codable
    
    // Core components
    private let instanceRegistry = InstanceRegistry.shared
    private let eventBridge = EventBridge()  // Each system gets its own instance

    // BLE manager protocol instances (can be production or mock)
    private let peripheralManager: BLEPeripheralManagerProtocol
    private let centralManager: BLECentralManagerProtocol
    
    // Connection tracking
    private actor ProxyManager {
        private var peripheralProxies: [UUID: PeripheralActorProxy] = [:]
        
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

    /// Internal initializer with dependency injection
    /// - Parameters:
    ///   - peripheralManager: BLE peripheral manager implementation
    ///   - centralManager: BLE central manager implementation
    /// - Note: Managers should have their initialize() method called BEFORE or during construction
    internal init(
        peripheralManager: BLEPeripheralManagerProtocol,
        centralManager: BLECentralManagerProtocol
    ) {
        self.peripheralManager = peripheralManager
        self.centralManager = centralManager

        Task {
            // Wait for managers to be powered on before setting up event handlers
            _ = await peripheralManager.waitForPoweredOn()
            _ = await centralManager.waitForPoweredOn()

            await setupEventHandlers()
            await bootstrap.markReady()
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

    /// Create mock instance for testing (async version - recommended)
    /// - Parameters:
    ///   - peripheralConfig: Configuration for mock peripheral manager
    ///   - centralConfig: Configuration for mock central manager
    /// - Returns: BLEActorSystem with mock implementations, guaranteed to be ready
    /// - Note: No Bluetooth permissions required, no hardware needed
    /// - Important: This async version waits for the system to be ready before returning
    public static func mock(
        peripheralConfig: MockPeripheralManager.Configuration = .init(),
        centralConfig: MockCentralManager.Configuration = .init()
    ) async -> BLEActorSystem {
        let system = BLEActorSystem(
            peripheralManager: MockPeripheralManager(
                configuration: peripheralConfig
            ),
            centralManager: MockCentralManager(
                configuration: centralConfig
            )
        )

        // Wait for system to be ready (should be almost instant with mocks)
        var retries = 1000  // 10 seconds max
        while retries > 0 {
            if await system.ready {
                break
            }
            try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms
            retries -= 1
        }

        return system
    }

    /// Create mock instance for testing (synchronous version - legacy)
    /// - Parameters:
    ///   - peripheralConfig: Configuration for mock peripheral manager
    ///   - centralConfig: Configuration for mock central manager
    /// - Returns: BLEActorSystem with mock implementations
    /// - Note: No Bluetooth permissions required, no hardware needed
    /// - Warning: System may not be immediately ready. Consider using async version instead.
    /// - Important: Deprecated in favor of async mock() method
    @available(*, deprecated, message: "Use async mock() method for guaranteed readiness")
    public static func mockSync(
        peripheralConfig: MockPeripheralManager.Configuration = .init(),
        centralConfig: MockCentralManager.Configuration = .init()
    ) -> BLEActorSystem {
        return BLEActorSystem(
            peripheralManager: MockPeripheralManager(
                configuration: peripheralConfig
            ),
            centralManager: MockCentralManager(
                configuration: centralConfig
            )
        )
    }

    // MARK: - Testing Support

    /// Access to mock peripheral manager for testing
    /// - Returns: Mock peripheral manager if the system was created with `.mock()`, otherwise nil
    /// - Note: Only available when using mock implementations
    /// - Important: Use this method instead of direct downcasting to access mock-specific APIs
    public func mockPeripheralManager() async -> MockPeripheralManager? {
        return peripheralManager as? MockPeripheralManager
    }

    /// Access to mock central manager for testing
    /// - Returns: Mock central manager if the system was created with `.mock()`, otherwise nil
    /// - Note: Only available when using mock implementations
    /// - Important: Use this method instead of direct downcasting to access mock-specific APIs
    public func mockCentralManager() async -> MockCentralManager? {
        return centralManager as? MockCentralManager
    }

    // MARK: - Backward Compatibility

    /// Shared instance - now uses production() by default
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
    private func setupEventHandlers() async {
        // Register peripheral manager for sending RPC responses
        await eventBridge.setPeripheralManager(peripheralManager)

        // Register RPC request handler so peripheral can process incoming RPCs
        await eventBridge.setRPCRequestHandler { [weak self] envelope in
            guard let self = self else {
                let error = RuntimeError.transportFailed("Actor system deallocated")
                return ResponseEnvelope(callID: envelope.callID, result: .failure(error))
            }
            return await self.handleIncomingRPC(envelope)
        }

        // Monitor events from BLE managers
        Task {
            for await event in peripheralManager.events {
                await eventBridge.distribute(event)
            }
        }

        Task {
            for await event in centralManager.events {
                await eventBridge.distribute(event)
            }
        }
    }
    
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
        
        Task {
            await instanceRegistry.registerLocal(actor)
        }
    }
    
    public func resignID(_ id: ActorID) {
        Task {
            await proxyManager.remove(id)
            await instanceRegistry.unregister(id)
            await eventBridge.unsubscribe(id)
            await eventBridge.unregisterRPCCharacteristic(for: id)
        }
    }
    
    public func makeInvocationEncoder() -> InvocationEncoder {
        return BLEInvocationEncoder()
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
        
        // Get the method name from target
        let methodName = target.identifier
        
        // Get the peripheral actor proxy
        guard let proxy = await proxyManager.get(actor.id) else {
            throw BleuError.actorNotFound(actor.id)
        }
        
        // Create invocation envelope
        let encoder = invocation  // We know it's BLEInvocationEncoder from the type system

        // Encode arguments as JSON array in a single step (not double-encoding)
        // The arguments field is an opaque Data blob - we choose JSON array encoding
        // BLETransport will handle MTU fragmentation at the transport layer
        let arguments = encoder.arguments
        let argumentsData: Data
        if arguments.isEmpty {
            // Empty data for no-argument methods
            argumentsData = Data("[]".utf8)  // Empty JSON array
        } else {
            // Single serialization: [Data, Data, ...] → JSON array → Data
            argumentsData = try JSONEncoder().encode(arguments)
        }

        let envelope = InvocationEnvelope(
            recipientID: actor.id.uuidString,
            senderID: nil,  // Central doesn't need sender ID for BLE
            target: methodName,
            arguments: argumentsData
        )
        let messageData = try JSONEncoder().encode(envelope)
        
        // Register with event bridge and send
        async let responseEnvelope = eventBridge.registerRPCCall(envelope.callID, peripheralID: actor.id)
        try await proxy.sendMessage(messageData)

        // Wait for response
        let response = try await responseEnvelope

        // Handle the response using InvocationResult enum
        switch response.result {
        case .success(let resultData):
            let result = try JSONDecoder().decode(Res.self, from: resultData)
            return result
        case .void:
            throw BleuError.invalidData  // Should not happen for non-void calls
        case .failure(let runtimeError):
            // Convert RuntimeError to BleuError
            throw convertRuntimeError(runtimeError)
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
            // Get the target actor from registry
            let instanceRegistry = InstanceRegistry.shared
            let methodRegistry = MethodRegistry.shared

            // Parse actorID from recipientID (convert String back to UUID)
            guard let actorID = UUID(uuidString: envelope.recipientID) else {
                let error = RuntimeError.invalidEnvelope("Invalid recipient ID: \(envelope.recipientID)")
                return ResponseEnvelope(callID: envelope.callID, result: .failure(error))
            }

            // Check if actor is registered locally
            guard await instanceRegistry.isRegistered(actorID) else {
                let error = RuntimeError.actorNotFound(envelope.recipientID)
                return ResponseEnvelope(callID: envelope.callID, result: .failure(error))
            }

            // Check if method is registered
            guard await methodRegistry.hasMethod(actorID: actorID, methodName: envelope.target) else {
                let error = RuntimeError.methodNotFound(envelope.target)
                return ResponseEnvelope(callID: envelope.callID, result: .failure(error))
            }

            // Decode arguments array from the opaque Data blob
            // This reverses the single serialization done in remoteCall
            let arguments: [Data]
            if envelope.arguments.isEmpty || envelope.arguments == Data("[]".utf8) {
                arguments = []
            } else {
                arguments = try JSONDecoder().decode([Data].self, from: envelope.arguments)
            }

            // Execute the method using the registry
            let resultData = try await methodRegistry.execute(
                actorID: actorID,
                methodName: envelope.target,
                arguments: arguments
            )

            return ResponseEnvelope(callID: envelope.callID, result: .success(resultData))

        } catch {
            // Convert BleuError or other errors to RuntimeError
            let runtimeError: RuntimeError
            if let bleuError = error as? BleuError {
                runtimeError = convertToRuntimeError(bleuError)
            } else {
                runtimeError = .executionFailed("Method execution failed", underlying: error.localizedDescription)
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

        // For mock peripherals, set the peripheral ID BEFORE adding service
        // so that characteristics can be registered with the bridge
        if let mockPeripheral = peripheralManager as? MockPeripheralManager {
            await mockPeripheral.setPeripheralID(peripheral.id)
        }

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

                // Register the remote actor in the instance registry
                await instanceRegistry.registerRemote(actor, peripheralID: discovered.id)

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

        // Register the remote actor in the instance registry
        await instanceRegistry.registerRemote(actor, peripheralID: peripheralID)

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

        // Unsubscribe from EventBridge
        await eventBridge.unsubscribe(peripheralID)

        // Unregister RPC characteristic mapping
        await eventBridge.unregisterRPCCharacteristic(for: peripheralID)

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

        // Setup event handler for this actor
        let eventHandler: EventBridge.EventHandler = { @Sendable (event: BLEEvent) async throws in
            // Handle events for this remote actor
            BleuLogger.actorSystem.debug("Event for remote actor: \(id)")
        }
        await eventBridge.subscribe(id, handler: eventHandler)

        // Subscribe to RPC characteristic for responses
        await eventBridge.subscribeToCharacteristic(rpcCharUUID, actorID: id)

        // Register RPC characteristic mapping
        await eventBridge.registerRPCCharacteristic(rpcCharUUID, for: id)
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

// MARK: - Supporting Types

private struct VoidResult: Codable {}

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

// MARK: - Invocation Encoder/Decoder

public struct BLEInvocationEncoder: DistributedTargetInvocationEncoder {
    public typealias SerializationRequirement = Codable
    
    private(set) var arguments: [Data] = []
    private let encoder = JSONEncoder()
    
    public init() {}
    
    public mutating func recordGenericSubstitution<T>(_ type: T.Type) throws {}
    
    public mutating func recordArgument<Value: SerializationRequirement>(
        _ argument: RemoteCallArgument<Value>
    ) throws {
        let data = try encoder.encode(argument.value)
        arguments.append(data)
    }
    
    public mutating func recordReturnType<R: SerializationRequirement>(_ type: R.Type) throws {}
    
    public mutating func recordErrorType<E: Error>(_ type: E.Type) throws {}
    
    public mutating func doneRecording() throws {}
}

public struct BLEInvocationDecoder: DistributedTargetInvocationDecoder {
    public typealias SerializationRequirement = Codable
    
    private let decoder = JSONDecoder()
    private var arguments: [Data]
    private var currentIndex = 0
    
    public init(arguments: [Data]) {
        self.arguments = arguments
    }
    
    public mutating func decodeGenericSubstitutions() throws -> [Any.Type] {
        return []
    }
    
    public mutating func decodeNextArgument<Argument: SerializationRequirement>() throws -> Argument {
        guard currentIndex < arguments.count else {
            throw BleuError.invalidData
        }
        
        let data = arguments[currentIndex]
        currentIndex += 1
        return try decoder.decode(Argument.self, from: data)
    }
    
    public mutating func decodeReturnType() throws -> Any.Type? {
        return nil
    }
    
    public mutating func decodeErrorType() throws -> Any.Type? {
        return nil
    }
}

public struct BLEResultHandler: DistributedTargetInvocationResultHandler {
    public typealias SerializationRequirement = Codable
    
    public func onReturn<Success: SerializationRequirement>(value: Success) async throws {
        // Handle successful return
    }
    
    public func onReturnVoid() async throws {
        // Handle void return
    }
    
    public func onThrow<Failure: Error>(error: Failure) async throws {
        throw error
    }
}