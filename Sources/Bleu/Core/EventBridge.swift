import Foundation
import CoreBluetooth
import Distributed
import ActorRuntime

/// Event bridge for routing BLE events to distributed actors
public actor EventBridge {
    
    /// Event handler type
    public typealias EventHandler = @Sendable (BLEEvent) async throws -> Void
    
    /// Response handler for RPC calls
    public typealias ResponseHandler = @Sendable (ResponseEnvelope) async throws -> Void

    /// RPC request handler type (peripheral side)
    public typealias RPCRequestHandler = @Sendable (InvocationEnvelope) async -> ResponseEnvelope

    // Event subscriptions
    private var eventHandlers: [UUID: EventHandler] = [:]
    private var characteristicSubscriptions: [UUID: Set<UUID>] = [:] // characteristic -> actor IDs

    // RPC response handlers
    private var responseHandlers: [UUID: ResponseHandler] = [:]

    // RPC request handler (peripheral side)
    private var rpcRequestHandler: RPCRequestHandler?
    
    // Pending RPC calls
    private var pendingCalls: [UUID: CheckedContinuation<ResponseEnvelope, Error>] = [:]
    
    // Track which calls belong to which peripheral for cleanup
    private var callToPeripheral: [UUID: UUID] = [:] // callID -> peripheralID
    private var peripheralCalls: [UUID: Set<UUID>] = [:] // peripheralID -> Set<callID>
    
    // RPC characteristic mapping
    private var rpcCharacteristicByActor: [UUID: UUID] = [:] // actorID -> rpcCharUUID
    private var actorByRPCCharacteristic: [UUID: UUID] = [:] // rpcCharUUID -> actorID
    
    /// Shared instance (deprecated - each BLEActorSystem should have its own)
    @available(*, deprecated, message: "Use instance per BLEActorSystem instead of singleton")
    public static let shared = EventBridge()

    public init() {}
    
    // MARK: - Event Subscription
    
    /// Subscribe to BLE events
    public func subscribe(_ actorID: UUID, handler: @escaping EventHandler) {
        eventHandlers[actorID] = handler
    }
    
    /// Unsubscribe from BLE events
    public func unsubscribe(_ actorID: UUID) {
        eventHandlers.removeValue(forKey: actorID)
        
        // Remove from characteristic subscriptions
        // Take snapshot of keys to avoid mutating dictionary while iterating
        let keys = Array(characteristicSubscriptions.keys)
        for charUUID in keys {
            if var subscribers = characteristicSubscriptions[charUUID] {
                subscribers.remove(actorID)
                if subscribers.isEmpty {
                    characteristicSubscriptions.removeValue(forKey: charUUID)
                } else {
                    characteristicSubscriptions[charUUID] = subscribers
                }
            }
        }
    }
    
    /// Subscribe to a specific characteristic
    public func subscribeToCharacteristic(_ characteristicUUID: UUID, actorID: UUID) {
        if characteristicSubscriptions[characteristicUUID] == nil {
            characteristicSubscriptions[characteristicUUID] = []
        }
        characteristicSubscriptions[characteristicUUID]?.insert(actorID)
    }
    
    /// Unsubscribe from a specific characteristic
    public func unsubscribeFromCharacteristic(_ characteristicUUID: UUID, actorID: UUID) {
        characteristicSubscriptions[characteristicUUID]?.remove(actorID)
        if characteristicSubscriptions[characteristicUUID]?.isEmpty == true {
            characteristicSubscriptions.removeValue(forKey: characteristicUUID)
        }
    }
    
    /// Register an RPC characteristic for an actor
    public func registerRPCCharacteristic(_ characteristicUUID: UUID, for actorID: UUID) {
        rpcCharacteristicByActor[actorID] = characteristicUUID
        actorByRPCCharacteristic[characteristicUUID] = actorID
    }
    
    /// Unregister an RPC characteristic
    public func unregisterRPCCharacteristic(for actorID: UUID) {
        if let charUUID = rpcCharacteristicByActor.removeValue(forKey: actorID) {
            actorByRPCCharacteristic.removeValue(forKey: charUUID)
        }
    }
    
    // MARK: - Event Distribution
    
    /// Distribute a BLE event to relevant actors
    public func distribute(_ event: BLEEvent) async {
        // Extract peripheral ID from event (for future use)
        // This could be used for peripheral-specific routing in the future
        
        // Send to all general event handlers
        await withTaskGroup(of: Void.self) { group in
            for (_, handler) in eventHandlers {
                group.addTask {
                    do {
                        try await handler(event)
                    } catch {
                        BleuLogger.actorSystem.error("Event handler failed: \(error.localizedDescription)")
                    }
                }
            }
        }
        
        // Handle characteristic-specific events
        switch event {
        case .characteristicValueUpdated(let peripheralID, _, let characteristicUUID, let data):
            await distributeCharacteristicUpdate(characteristicUUID, peripheralID: peripheralID, data: data)
            
        case .writeRequestReceived(_, _, let characteristicUUID, let data):
            await handleWriteRequest(characteristicUUID, data: data)
            
        case .peripheralDisconnected(let peripheralID, _):
            // Clean up any pending RPC calls for this peripheral
            await cleanupPeripheral(peripheralID)
            
        default:
            break
        }
    }
    
    /// Distribute characteristic updates to subscribed actors
    private func distributeCharacteristicUpdate(_ characteristicUUID: UUID, peripheralID: UUID, data: Data?) async {
        guard let data = data else { return }
        
        // Check if this is an RPC characteristic
        if let _ = actorByRPCCharacteristic[characteristicUUID] {
            // Use BLETransport to reassemble fragmented responses
            let transport = BLETransport.shared
            if let completeData = await transport.receive(data) {
                // Try to decode as ResponseEnvelope for RPC responses
                if let envelope = try? JSONDecoder().decode(ResponseEnvelope.self, from: completeData) {
                    await handleRPCResponse(envelope)
                }
            }
            // If nil, packet is part of a larger message, wait for more
        } else {
            // Regular characteristic notification
            if let subscribers = characteristicSubscriptions[characteristicUUID] {
                for actorID in subscribers {
                    if let handler = eventHandlers[actorID] {
                        do {
                            try await handler(.characteristicValueUpdated(
                                peripheralID,
                                UUID(), // service UUID would need to be tracked separately
                                characteristicUUID,
                                data
                            ))
                        } catch {
                            BleuLogger.actorSystem.error("Characteristic update handler failed: \(error.localizedDescription)")
                        }
                    }
                }
            }
        }
    }
    
    /// Set the RPC request handler (called by BLEActorSystem during initialization)
    public func setRPCRequestHandler(_ handler: @escaping RPCRequestHandler) {
        self.rpcRequestHandler = handler
    }

    /// Set the peripheral manager for sending RPC responses
    /// Note: Not weak because BLEPeripheralManagerProtocol is a protocol, and we need to keep the reference
    private var peripheralManager: BLEPeripheralManagerProtocol?

    public func setPeripheralManager(_ manager: BLEPeripheralManagerProtocol) {
        self.peripheralManager = manager
    }

    /// Handle write requests (for RPC invocations)
    private func handleWriteRequest(_ characteristicUUID: UUID, data: Data) async {
        // Unpack the data using BLETransport (handles fragmentation)
        let transport = BLETransport.shared
        guard let completeData = await transport.receive(data) else {
            return  // Waiting for more fragments
        }

        // Try to decode as InvocationEnvelope
        guard let envelope = try? JSONDecoder().decode(InvocationEnvelope.self, from: completeData) else {
            return
        }

        // Process the RPC request if handler is set (peripheral side)
        if let handler = rpcRequestHandler {
            let response = await handler(envelope)

            // Send response back via characteristic notification
            do {
                let responseData = try JSONEncoder().encode(response)
                guard let peripheralManager = peripheralManager else {
                    BleuLogger.rpc.error("Peripheral manager not available for response")
                    return
                }

                // Use BLETransport to fragment response if needed
                let transport = BLETransport.shared
                let packets = await transport.fragment(responseData)

                // Send each packet with retry logic
                for (index, packet) in packets.enumerated() {
                    let packetData = await transport.packPacket(packet)

                    // Try up to 3 times: initial attempt + 2 retries
                    // Delays: 50ms, 100ms (exponential backoff)
                    var attempt = 0
                    var success = false
                    let maxAttempts = 3

                    while attempt < maxAttempts && !success {
                        do {
                            success = try await peripheralManager.updateValue(
                                packetData,
                                for: characteristicUUID,
                                to: nil  // Broadcast to all subscribed centrals
                            )

                            if !success && attempt < maxAttempts - 1 {
                                // Central not ready, wait before retry
                                // Exponential backoff: 50ms, 100ms
                                let delayMs = 50 * (1 << attempt)  // 50ms * (1, 2) = 50ms, 100ms
                                BleuLogger.rpc.debug("Packet \(index)/\(packets.count) failed, retrying after \(delayMs)ms (attempt \(attempt + 1)/\(maxAttempts))")
                                try await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                            }
                        } catch {
                            BleuLogger.rpc.warning("Error sending packet \(index): \(error)")
                            if attempt < maxAttempts - 1 {
                                // Wait before retry
                                let delayMs = 50 * (1 << attempt)
                                try await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                            }
                        }

                        attempt += 1
                    }

                    // If all attempts failed, send error response to Central
                    if !success {
                        BleuLogger.rpc.error("Failed to send packet \(index)/\(packets.count) after \(maxAttempts) attempts, sending error response")
                        await sendErrorResponse(
                            callID: response.callID,
                            characteristicUUID: characteristicUUID,
                            peripheralManager: peripheralManager,
                            error: "Packet transmission failed after retries"
                        )
                        return
                    }

                    // Small delay between packets to prevent overwhelming the central
                    if index < packets.count - 1 {
                        try await Task.sleep(nanoseconds: 10_000_000) // 10ms
                    }
                }

                BleuLogger.rpc.debug("Successfully sent \(packets.count) packet(s) for RPC response")

            } catch {
                BleuLogger.rpc.error("Failed to encode or send RPC response: \(error)")
                // Send error response to Central
                if let peripheralManager = peripheralManager {
                    await sendErrorResponse(
                        callID: response.callID,
                        characteristicUUID: characteristicUUID,
                        peripheralManager: peripheralManager,
                        error: "Response encoding failed: \(error.localizedDescription)"
                    )
                }
            }
        } else {
            // Fallback: route to event handlers
            // Convert recipientID (String) to UUID
            if let actorID = UUID(uuidString: envelope.recipientID),
               let eventHandler = eventHandlers[actorID] {
                do {
                    try await eventHandler(.writeRequestReceived(
                        actorID,
                        UUID(), // service UUID would be determined by the actor
                        characteristicUUID,
                        data
                    ))
                } catch {
                    BleuLogger.actorSystem.error("Write request handler failed: \(error.localizedDescription)")
                }
            }
        }
    }
    
    // MARK: - RPC Support
    
    /// Atomically take and remove a pending call continuation
    private func takePending(_ id: UUID) -> CheckedContinuation<ResponseEnvelope, Error>? {
        let cont = pendingCalls.removeValue(forKey: id)
        if let peripheralID = callToPeripheral.removeValue(forKey: id) {
            peripheralCalls[peripheralID]?.remove(id)
            if peripheralCalls[peripheralID]?.isEmpty == true {
                peripheralCalls.removeValue(forKey: peripheralID)
            }
        }
        return cont
    }
    
    /// Register a pending RPC call
    public func registerRPCCall(_ callID: String, peripheralID: UUID? = nil) async throws -> ResponseEnvelope {
        // Convert String callID to UUID for internal tracking
        guard let id = UUID(uuidString: callID) else {
            throw BleuError.invalidData
        }

        // Get timeout from configuration
        let timeoutSec = await BleuConfigurationManager.shared.current().rpcTimeout

        return try await withCheckedThrowingContinuation { continuation in
            pendingCalls[id] = continuation

            // Track peripheral association if provided
            if let peripheralID = peripheralID {
                callToPeripheral[id] = peripheralID
                if peripheralCalls[peripheralID] == nil {
                    peripheralCalls[peripheralID] = []
                }
                peripheralCalls[peripheralID]?.insert(id)
            }

            // Set timeout using configuration
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSec * 1_000_000_000))
                if let cont = self.takePending(id) {
                    cont.resume(throwing: BleuError.connectionTimeout)
                }
            }
        }
    }
    
    /// Send error response to Central when packet transmission fails
    private func sendErrorResponse(
        callID: String,
        characteristicUUID: UUID,
        peripheralManager: BLEPeripheralManagerProtocol,
        error: String
    ) async {
        // Create error response envelope
        let errorResponse = ResponseEnvelope(
            callID: callID,
            result: .failure(.transportFailed(error))
        )

        do {
            let errorData = try JSONEncoder().encode(errorResponse)

            // Try to send as single packet (error responses are usually small)
            let transport = BLETransport.shared
            let packets = await transport.fragment(errorData)

            // Send only the first packet (if error response is small)
            // Don't retry error responses to avoid infinite loops
            if let firstPacket = packets.first {
                let packetData = await transport.packPacket(firstPacket)
                _ = try? await peripheralManager.updateValue(
                    packetData,
                    for: characteristicUUID,
                    to: nil
                )
                BleuLogger.rpc.debug("Sent error response for call \(callID)")
            }
        } catch {
            BleuLogger.rpc.error("Failed to send error response: \(error)")
        }
    }

    /// Handle an RPC response
    private func handleRPCResponse(_ envelope: ResponseEnvelope) async {
        // Convert callID (String) to UUID for lookup
        guard let callUUID = UUID(uuidString: envelope.callID) else {
            BleuLogger.actorSystem.error("Invalid callID in response: \(envelope.callID)")
            return
        }

        // Atomically take the continuation to avoid race conditions
        if let cont = takePending(callUUID) {
            cont.resume(returning: envelope)
        }

        // Also notify any response handlers
        if let handler = responseHandlers.removeValue(forKey: callUUID) {
            do {
                try await handler(envelope)
            } catch {
                BleuLogger.actorSystem.error("Response handler failed for envelope \(envelope.callID): \(error.localizedDescription)")
            }
        }
    }
    
    /// Register a response handler for an RPC call
    public func registerResponseHandler(_ id: UUID, handler: @escaping ResponseHandler) {
        responseHandlers[id] = handler
    }
    
    // MARK: - Cleanup
    
    /// Clean up resources for a disconnected peripheral
    public func cleanupPeripheral(_ peripheralID: UUID) async {
        // Cancel any pending RPC calls for this peripheral
        if let callIDs = peripheralCalls.removeValue(forKey: peripheralID) {
            for callID in callIDs {
                callToPeripheral.removeValue(forKey: callID)
                // Atomically take the continuation
                if let cont = pendingCalls.removeValue(forKey: callID) {
                    cont.resume(throwing: BleuError.disconnected)
                }
            }
        }
    }
    
    /// Clear all registrations
    public func clear() {
        eventHandlers.removeAll()
        characteristicSubscriptions.removeAll()
        responseHandlers.removeAll()
        
        // Cancel all pending calls
        for (_, continuation) in pendingCalls {
            continuation.resume(throwing: BleuError.disconnected)
        }
        pendingCalls.removeAll()
        
        // Clear RPC mapping
        callToPeripheral.removeAll()
        peripheralCalls.removeAll()
        rpcCharacteristicByActor.removeAll()
        actorByRPCCharacteristic.removeAll()
    }
    
    /// Get statistics
    public func statistics() -> EventBridgeStatistics {
        return EventBridgeStatistics(
            eventHandlers: eventHandlers.count,
            characteristicSubscriptions: characteristicSubscriptions.count,
            pendingRPCCalls: pendingCalls.count,
            responseHandlers: responseHandlers.count
        )
    }
}

/// Event bridge statistics
public struct EventBridgeStatistics: Sendable {
    public let eventHandlers: Int
    public let characteristicSubscriptions: Int
    public let pendingRPCCalls: Int
    public let responseHandlers: Int
}