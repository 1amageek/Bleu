import Foundation
@preconcurrency import CoreBluetooth
import os

/// Local actor that wraps CBPeripheralManager for BLE peripheral operations
public actor LocalPeripheralActor {
    private var peripheralManager: CBPeripheralManager?
    private var delegateProxy: PeripheralManagerDelegateProxy?
    private let messageChannel = AsyncChannel<BLEEvent>()
    private var services: [UUID: CBMutableService] = [:]
    private var characteristics: [UUID: CBMutableCharacteristic] = [:]
    private var subscribedCentrals: [UUID: Set<CBCentral>] = [:]
    private var rpcCharacteristics: Set<UUID> = []  // Track RPC characteristics
    
    // Continuations for async operations
    private var stateContinuations: [CheckedContinuation<CBManagerState, Never>] = []
    private var advertisingContinuation: CheckedContinuation<Void, Error>?
    
    init() {}
    
    /// Initialize the peripheral manager
    public func initialize() {
        delegateProxy = PeripheralManagerDelegateProxy(actor: self)
        peripheralManager = CBPeripheralManager(delegate: delegateProxy, queue: nil)
    }
    
    /// Setup a BLE service from metadata
    public func setupService(from metadata: ServiceMetadata) async throws {
        // Wait for powered on state
        let state = await waitForPoweredOn()
        guard state == .poweredOn else {
            throw BleuError.bluetoothPoweredOff
        }
        
        // Create service
        let service = CBMutableService(type: CBUUID(nsuuid: metadata.uuid), primary: metadata.isPrimary)
        
        // Create characteristics
        var cbCharacteristics: [CBMutableCharacteristic] = []
        for charMetadata in metadata.characteristics {
            let characteristic = CBMutableCharacteristic(
                type: CBUUID(nsuuid: charMetadata.uuid),
                properties: charMetadata.properties.cbProperties,
                value: nil,
                permissions: charMetadata.permissions.cbPermissions
            )
            
            characteristics[charMetadata.uuid] = characteristic
            cbCharacteristics.append(characteristic)
            
            // RPC characteristic detection:
            // Convention: A characteristic is considered RPC-capable if it has both
            // .notify (for sending responses) and .write (for receiving invocations)
            // This allows bidirectional communication required for RPC pattern
            if charMetadata.properties.contains([.notify, .write]) {
                rpcCharacteristics.insert(charMetadata.uuid)
            }
        }
        
        service.characteristics = cbCharacteristics
        services[metadata.uuid] = service
        
        // Add service to peripheral manager
        peripheralManager?.add(service)
    }
    
    /// Start advertising with the given data
    public func startAdvertising(_ data: AdvertisementData) async throws {
        guard let peripheralManager = peripheralManager else {
            throw BleuError.bluetoothUnavailable
        }
        
        // Build advertisement dictionary
        var advertisementDict: [String: Any] = [:]
        
        if let localName = data.localName {
            advertisementDict[CBAdvertisementDataLocalNameKey] = localName
        }
        
        if !data.serviceUUIDs.isEmpty {
            advertisementDict[CBAdvertisementDataServiceUUIDsKey] = data.serviceUUIDs.map { CBUUID(nsuuid: $0) }
        }
        
        if let manufacturerData = data.manufacturerData {
            advertisementDict[CBAdvertisementDataManufacturerDataKey] = manufacturerData
        }
        
        if !data.serviceData.isEmpty {
            var cbServiceData: [CBUUID: Data] = [:]
            for (uuid, data) in data.serviceData {
                cbServiceData[CBUUID(nsuuid: uuid)] = data
            }
            advertisementDict[CBAdvertisementDataServiceDataKey] = cbServiceData
        }
        
        // Start advertising
        try await withCheckedThrowingContinuation { continuation in
            self.advertisingContinuation = continuation
            peripheralManager.startAdvertising(advertisementDict)
        }
    }
    
    /// Stop advertising
    public func stopAdvertising() {
        peripheralManager?.stopAdvertising()
    }
    
    /// Update a characteristic value
    public func updateValue(_ data: Data, for characteristicUUID: UUID, to centrals: [CBCentral]? = nil) async throws -> Bool {
        guard let characteristic = characteristics[characteristicUUID] else {
            throw BleuError.characteristicNotFound(characteristicUUID)
        }
        
        let centralsToUpdate = centrals ?? Array(subscribedCentrals[characteristicUUID] ?? [])
        
        return peripheralManager?.updateValue(
            data,
            for: characteristic,
            onSubscribedCentrals: centralsToUpdate.isEmpty ? nil : centralsToUpdate
        ) ?? false
    }
    
    /// Get event stream
    public var events: AsyncStream<BLEEvent> {
        messageChannel.stream
    }
    
    /// Wait for powered on state
    private func waitForPoweredOn() async -> CBManagerState {
        guard let peripheralManager = peripheralManager else {
            return .unknown
        }
        
        if peripheralManager.state == .poweredOn {
            return .poweredOn
        }
        
        return await withCheckedContinuation { continuation in
            self.stateContinuations.append(continuation)
        }
    }
}

// MARK: - Delegate Support Methods

extension LocalPeripheralActor {
    /// Get the current value for a characteristic
    public func currentValue(for characteristicUUID: CBUUID) -> Data? {
        let uuid = UUID(uuidString: characteristicUUID.uuidString) ?? UUID.deterministic(from: characteristicUUID.uuidString)
        return characteristics[uuid]?.value
    }
    
    /// Track a read request for logging/monitoring
    public func trackReadRequest(characteristicUUID: String, serviceUUID: String?) async {
        guard let charUUID = UUID(uuidString: characteristicUUID) else { return }
        let svcUUID = serviceUUID.flatMap(UUID.init(uuidString:)) ?? UUID()
        
        // Send event for tracking
        await messageChannel.send(.readRequestReceived(
            UUID(),  // We don't have central ID here
            svcUUID,
            charUUID
        ))
    }
}

// MARK: - Delegate Handlers

extension LocalPeripheralActor {
    func handleStateUpdate(_ state: CBManagerState) async {
        await messageChannel.send(.stateChanged(state))
        
        if state == .poweredOn && !stateContinuations.isEmpty {
            stateContinuations.forEach { $0.resume(returning: state) }
            stateContinuations.removeAll()
        }
    }
    
    func handleServiceAdded(_ service: CBService, error: Error?) async {
        // Service added notification
        // This can be extended to handle service addition callbacks if needed
        if let error = error {
            BleuLogger.peripheral.error("Error adding service: \(error.localizedDescription)")
        }
    }
    
    func handleAdvertisingStarted(error: Error?) async {
        if let continuation = advertisingContinuation {
            if let error = error {
                continuation.resume(throwing: error)
            } else {
                continuation.resume()
            }
            advertisingContinuation = nil
        }
    }
    
    
    func handleWriteRequests(
        _ extractedRequests: [(serviceUUID: String?, characteristicUUID: String, value: Data?, offset: Int)]
    ) async {
        // Process the extracted requests
        for (serviceUUID, characteristicUUID, value, _) in extractedRequests {
            guard let charUUID = UUID(uuidString: characteristicUUID) else { continue }
            let svcUUID = serviceUUID.flatMap(UUID.init(uuidString:)) ?? UUID()
            
            // Send event
            if let value = value {
                // Check if this is an RPC characteristic
                if rpcCharacteristics.contains(charUUID) {
                    // Use BLETransport to reassemble fragmented messages
                    let transport = BLETransport.shared
                    if let completeData = await transport.receive(value) {
                        // We have a complete message, process it
                        await handleRPCInvocation(data: completeData, characteristicUUID: charUUID)
                    }
                    // If nil, packet is part of a larger message, wait for more
                } else {
                    // Regular characteristic write
                    await messageChannel.send(.writeRequestReceived(
                        UUID(),  // We don't have central ID here
                        svcUUID,
                        charUUID,
                        value
                    ))
                }
            }
        }
    }
    
    // Add RPC invocation handler
    private func handleRPCInvocation(data: Data, characteristicUUID: UUID) async {
        do {
            // Decode the invocation envelope
            let envelope = try JSONDecoder().decode(InvocationEnvelope.self, from: data)
            
            // Use BLEActorSystem to handle the RPC
            let actorSystem = BLEActorSystem.shared
            let responseEnvelope = await actorSystem.handleIncomingRPC(envelope)
            
            // Encode response
            let responseData = try JSONEncoder().encode(responseEnvelope)
            
            // Use BLETransport to fragment response if needed
            let transport = BLETransport.shared
            let packets = await transport.fragment(responseData)
            
            // Send each packet
            for packet in packets {
                // Use BLETransport's binary packing for consistency
                let packetData = await transport.packPacket(packet)
                let success = try await updateValue(packetData, for: characteristicUUID)
                
                if !success {
                    // Queue the response for later if the central isn't ready
                    BleuLogger.rpc.warning("Could not send RPC response packet immediately, central may not be ready")
                    break
                }
                
                // Small delay between packets
                if packets.count > 1 {
                    try await Task.sleep(nanoseconds: 10_000_000) // 10ms
                }
            }
            
        } catch {
            BleuLogger.rpc.error("Error handling RPC invocation: \(error.localizedDescription)")
            // Don't send response for invalid data - central will timeout
        }
    }
    
    func handleSubscription(
        central: CBCentral,
        characteristicUUID: String,
        serviceUUID: String?,
        subscribed: Bool
    ) async {
        guard let charUUID = UUID(uuidString: characteristicUUID) else {
            return
        }
        
        let svcUUID = serviceUUID.flatMap(UUID.init(uuidString:)) ?? UUID()
        
        if subscribed {
            var centrals = subscribedCentrals[charUUID] ?? []
            centrals.insert(central)
            subscribedCentrals[charUUID] = centrals
            
            await messageChannel.send(.centralSubscribed(
                UUID(),  // We don't have central ID - this is a limitation of CoreBluetooth
                svcUUID,
                charUUID
            ))
        } else {
            subscribedCentrals[charUUID]?.remove(central)
            
            await messageChannel.send(.centralUnsubscribed(
                UUID(),  // We don't have central ID - this is a limitation of CoreBluetooth
                svcUUID,
                charUUID
            ))
        }
    }
    
    func handleReadyToUpdateSubscribers() async {
        // Called when peripheral manager is ready to send more updates
        // Can be used to resume sending queued notifications
    }
}