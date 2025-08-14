import Foundation
import CoreBluetooth
import Distributed
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
    
    /// Shared instance
    public static let shared = BLEActorSystem()
    
    // Core components
    private let instanceRegistry = InstanceRegistry.shared
    private let eventBridge = EventBridge.shared
    
    // Local actors for BLE operations
    private let localPeripheral: LocalPeripheralActor
    private let localCentral: LocalCentralActor
    
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
    
    public init() {
        self.localPeripheral = LocalPeripheralActor()
        self.localCentral = LocalCentralActor()
        
        Task {
            await localPeripheral.initialize()
            await localCentral.initialize()
            await setupEventHandlers()
            await bootstrap.markReady()
        }
    }
    
    /// Setup event handlers for BLE events
    private func setupEventHandlers() async {
        // Monitor events from local actors
        Task {
            for await event in await localPeripheral.events {
                await eventBridge.distribute(event)
            }
        }
        
        Task {
            for await event in await localCentral.events {
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
        
        let envelope = InvocationEnvelope(
            actorID: actor.id,
            methodName: methodName,
            arguments: encoder.arguments
        )
        let messageData = try JSONEncoder().encode(envelope)
        
        // Register with event bridge and send
        async let responseEnvelope = eventBridge.registerRPCCall(envelope.id, peripheralID: actor.id)
        try await proxy.sendMessage(messageData)
        
        // Wait for response
        let response = try await responseEnvelope
        
        if let errorData = response.error {
            let error = try JSONDecoder().decode(BleuError.self, from: errorData)
            throw error
        }
        
        guard let resultData = response.result else {
            throw BleuError.invalidData
        }
        
        let result = try JSONDecoder().decode(Res.self, from: resultData)
        return result
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
            
            // Check if actor is registered locally
            guard await instanceRegistry.isRegistered(envelope.actorID) else {
                let error = BleuError.actorNotFound(envelope.actorID)
                let errorData = try JSONEncoder().encode(error)
                return ResponseEnvelope(id: envelope.id, error: errorData)
            }
            
            // Check if method is registered
            guard await methodRegistry.hasMethod(actorID: envelope.actorID, methodName: envelope.methodName) else {
                let error = BleuError.methodNotSupported(envelope.methodName)
                let errorData = try JSONEncoder().encode(error)
                return ResponseEnvelope(id: envelope.id, error: errorData)
            }
            
            // Execute the method using the registry
            let resultData = try await methodRegistry.execute(
                actorID: envelope.actorID,
                methodName: envelope.methodName,
                arguments: envelope.arguments
            )
            
            return ResponseEnvelope(id: envelope.id, result: resultData)
            
        } catch {
            // Return error response
            do {
                let bleuError = error as? BleuError ?? BleuError.rpcFailed(error.localizedDescription)
                let errorData = try JSONEncoder().encode(bleuError)
                return ResponseEnvelope(id: envelope.id, error: errorData)
            } catch {
                // If we can't even encode the error, return a generic error
                return ResponseEnvelope(id: envelope.id, error: Data())
            }
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
        
        // Setup service in local peripheral
        try await localPeripheral.setupService(from: metadata)
        
        // Create advertisement data
        let advertisementData = AdvertisementData(
            localName: String(describing: T.self),
            serviceUUIDs: [metadata.uuid]
        )
        
        // Start advertising
        try await localPeripheral.startAdvertising(advertisementData)
        
        // Register the actor
        actorReady(peripheral)
    }
    
    /// Stop advertising
    public func stopAdvertising() async {
        await localPeripheral.stopAdvertising()
    }
    
    // MARK: - Central Mode
    
    /// Discover peripherals of a specific type
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
        
        for await discovered in await localCentral.scan(
            for: [CBUUID(nsuuid: serviceUUID)],
            timeout: timeout
        ) {
            // Setup proxy for remote peripheral
            await setupRemoteProxy(id: discovered.id, type: type)
            
            // Create remote actor reference
            do {
                let actor = try T.resolve(id: discovered.id, using: self)
                // Register the remote actor in the instance registry
                await instanceRegistry.registerRemote(actor, peripheralID: discovered.id)
                discoveredActors.append(actor)
            } catch {
                // Log and continue with next peripheral
                BleuLogger.actorSystem.warning("Failed to resolve actor for \(discovered.id): \(error.localizedDescription)")
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
        try await localCentral.connect(to: peripheralID)
        
        // Update BLETransport MTU based on connected peripheral
        await updateTransportMTU(for: peripheralID)
        
        // Setup proxy for remote peripheral
        await setupRemoteProxy(id: peripheralID, type: type)
        
        // Create remote actor reference
        let actor = try T.resolve(id: peripheralID, using: self)
        
        // Register the remote actor in the instance registry
        await instanceRegistry.registerRemote(actor, peripheralID: peripheralID)
        
        return actor
    }
    
    /// Disconnect from a peripheral
    public func disconnect(from peripheralID: UUID) async throws {
        defer { resignID(peripheralID) }
        try await localCentral.disconnect(from: peripheralID)
    }
    
    /// Check if connected to a peripheral
    public func isConnected(_ peripheralID: UUID) async -> Bool {
        return await proxyManager.hasProxy(peripheralID)
    }
    
    // MARK: - Private Helpers
    
    /// Update BLETransport MTU based on connected peripheral
    private func updateTransportMTU(for peripheralID: UUID) async {
        // Get the maximum write value length for the connected peripheral
        if let maxWriteLength = await localCentral.getMaximumWriteValueLength(for: peripheralID, type: .withResponse) {
            let transport = BLETransport.shared
            await transport.updateMaxPayloadSize(maxWriteLength: maxWriteLength)
        }
    }
    
    /// Setup a proxy for a remote peripheral
    private func setupRemoteProxy<T: PeripheralActor>(id: UUID, type: T.Type) async {
        // Check if proxy already exists to prevent duplicates
        if await proxyManager.get(id) != nil { 
            return 
        }
        
        // Calculate service and RPC characteristic UUIDs for this actor type
        let serviceUUID = UUID.serviceUUID(for: type)
        let rpcCharUUID = UUID.characteristicUUID(for: "__rpc__", in: type)
        
        // Discover services if needed
        do {
            // Discover the actor's service
            let services = try await localCentral.discoverServices(
                for: id,
                serviceUUIDs: [CBUUID(nsuuid: serviceUUID)]
            )
            
            guard !services.isEmpty else {
                BleuLogger.actorSystem.warning("No services found for actor type \(type)")
                return
            }
            
            // Discover characteristics for the service
            let characteristics = try await localCentral.discoverCharacteristics(
                for: CBUUID(nsuuid: serviceUUID),
                in: id,
                characteristicUUIDs: [CBUUID(nsuuid: rpcCharUUID)]
            )
            
            guard !characteristics.isEmpty else {
                BleuLogger.actorSystem.warning("RPC characteristic not found for actor type \(type)")
                return
            }
            
            // Create a proxy for the remote peripheral with RPC characteristic
            let proxy = PeripheralActorProxy(
                id: id,
                localCentral: localCentral,
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
            
            // Enable CoreBluetooth notifications for this characteristic
            try await localCentral.setNotifyValue(true, for: CBUUID(nsuuid: rpcCharUUID), in: id)
            
        } catch {
            BleuLogger.actorSystem.error("Error setting up remote proxy for \(id): \(error.localizedDescription)")
        }
    }
}

// MARK: - Supporting Types

private struct VoidResult: Codable {}

private struct PeripheralActorProxy {
    let id: UUID
    let localCentral: LocalCentralActor
    let rpcCharUUID: UUID
    
    func sendMessage(_ data: Data) async throws {
        // Use BLETransport for fragmentation if needed
        let transport = BLETransport.shared
        try await transport.send(
            data,
            to: id,
            using: localCentral,
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