import Foundation
@preconcurrency import CoreBluetooth
import ActorRuntime

/// Production implementation of BLEPeripheralManagerProtocol wrapping CBPeripheralManager
/// This implementation provides real CoreBluetooth functionality and requires TCC permissions
public actor CoreBluetoothPeripheralManager: BLEPeripheralManagerProtocol {

    // MARK: - Private Properties

    private var peripheralManager: CBPeripheralManager?
    private var delegateProxy: CoreBluetoothPeripheralManagerDelegateProxy?
    private let eventChannel = AsyncChannel<BLEEvent>()
    private var _state: CBManagerState = .unknown
    private var _isAdvertising = false

    // Service and characteristic tracking
    private var services: [UUID: CBMutableService] = [:]
    private var characteristics: [UUID: CBMutableCharacteristic] = [:]
    private var subscribedCentrals: [UUID: Set<CBCentral>] = [:]
    private var subscribedCentralIDs: [UUID: Set<UUID>] = [:]  // Track central UUIDs for API compatibility
    private var rpcCharacteristics: Set<UUID> = []  // Track RPC characteristics

    // Continuations for async operations
    private var stateContinuations: [CheckedContinuation<CBManagerState, Never>] = []
    private var advertisingContinuation: CheckedContinuation<Void, Error>?
    private var serviceAddContinuation: CheckedContinuation<Void, Error>?

    // MARK: - Initialization

    public init() {
        // Do NOT create CBPeripheralManager here (no TCC check)
        // Will be created in initialize()
    }

    // MARK: - BLEPeripheralManagerProtocol Implementation

    public func initialize() async {
        // TCC check occurs HERE when CBPeripheralManager is created
        delegateProxy = CoreBluetoothPeripheralManagerDelegateProxy(actor: self)
        peripheralManager = CBPeripheralManager(
            delegate: delegateProxy,
            queue: nil
        )
    }

    public nonisolated var events: AsyncStream<BLEEvent> {
        eventChannel.stream
    }

    public var state: CBManagerState {
        get async {
            return _state
        }
    }

    public func waitForPoweredOn() async -> CBManagerState {
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

    public func add(_ service: ServiceMetadata) async throws {
        // Wait for powered on state
        let state = await waitForPoweredOn()
        guard state == .poweredOn else {
            throw BleuError.bluetoothPoweredOff
        }

        // Create service
        let cbService = CBMutableService(
            type: CBUUID(nsuuid: service.uuid),
            primary: service.isPrimary
        )

        // Create characteristics
        var cbCharacteristics: [CBMutableCharacteristic] = []
        for charMetadata in service.characteristics {
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

        cbService.characteristics = cbCharacteristics
        services[service.uuid] = cbService

        // Add service to peripheral manager and wait for completion
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            serviceAddContinuation = continuation
            peripheralManager?.add(cbService)
        }
    }

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
            for (uuid, dataValue) in data.serviceData {
                cbServiceData[CBUUID(nsuuid: uuid)] = dataValue
            }
            advertisementDict[CBAdvertisementDataServiceDataKey] = cbServiceData
        }

        // Start advertising
        try await withCheckedThrowingContinuation { continuation in
            self.advertisingContinuation = continuation
            peripheralManager.startAdvertising(advertisementDict)
        }

        _isAdvertising = true
    }

    public func stopAdvertising() async {
        peripheralManager?.stopAdvertising()
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
        guard let characteristic = characteristics[characteristicUUID] else {
            throw BleuError.characteristicNotFound(characteristicUUID)
        }

        guard let peripheralManager = peripheralManager else {
            throw BleuError.bluetoothUnavailable
        }

        // Convert UUID array to CBCentral array if provided
        // Filter by central.identifier to respect the centrals parameter
        let centralsToUpdate: [CBCentral]
        if let requestedCentralIDs = centrals {
            let allSubscribed = subscribedCentrals[characteristicUUID] ?? []
            // Filter to only centrals whose identifier is in the requested list
            let filtered = Array(allSubscribed.filter { requestedCentralIDs.contains($0.identifier) })

            // CRITICAL SECURITY FIX: If filter result is empty, DO NOT send to anyone
            // Sending nil to CoreBluetooth broadcasts to ALL subscribers (privacy leak!)
            if filtered.isEmpty {
                BleuLogger.peripheral.error("No matching centrals found for UUIDs \(requestedCentralIDs) - refusing to broadcast")
                throw BleuError.peripheralNotFound(requestedCentralIDs.first ?? UUID())
            }

            centralsToUpdate = filtered
        } else {
            // No filter specified - send to all subscribers
            centralsToUpdate = Array(subscribedCentrals[characteristicUUID] ?? [])
        }

        // CRITICAL: Retry on failure to prevent dropped RPC responses
        // When updateValue returns false, the queue is full and the notification was NOT sent
        let maxRetries = 3
        for attempt in 0..<maxRetries {
            let success = peripheralManager.updateValue(
                data,
                for: characteristic,
                onSubscribedCentrals: centralsToUpdate.isEmpty ? nil : centralsToUpdate
            )

            if success {
                return true
            }

            // Queue full - wait and retry
            if attempt < maxRetries - 1 {
                BleuLogger.peripheral.warning("updateValue failed (queue full), retrying (\(attempt + 1)/\(maxRetries))...")
                try await Task.sleep(nanoseconds: 10_000_000)  // 10ms
            }
        }

        // All retries exhausted - this is a critical error for RPC
        BleuLogger.peripheral.error("updateValue failed after \(maxRetries) retries - notification dropped!")
        throw BleuError.rpcFailed("Failed to send notification after \(maxRetries) retries")
    }

    public func subscribedCentrals(for characteristicUUID: UUID) async -> [UUID] {
        return Array(subscribedCentralIDs[characteristicUUID] ?? [])
    }
}

// MARK: - Delegate Support Methods

extension CoreBluetoothPeripheralManager {
    /// Get the current value for a characteristic (for delegate callbacks)
    func currentValue(for characteristicUUID: CBUUID) -> Data? {
        let uuid = UUID(uuidString: characteristicUUID.uuidString) ?? UUID.deterministic(from: characteristicUUID.uuidString)
        return characteristics[uuid]?.value
    }

    /// Track a read request for logging/monitoring
    func trackReadRequest(centralID: UUID, characteristicUUID: String, serviceUUID: String?) async {
        guard let charUUID = UUID(uuidString: characteristicUUID) else { return }
        let svcUUID = serviceUUID.flatMap(UUID.init(uuidString:)) ?? UUID()

        // Send event for tracking
        await eventChannel.send(.readRequestReceived(
            centralID,  // Real central identifier from CBCentral
            svcUUID,
            charUUID
        ))
    }
}

// MARK: - Delegate Handlers

extension CoreBluetoothPeripheralManager {
    func handleStateUpdate(_ state: CBManagerState) async {
        _state = state
        await eventChannel.send(.stateChanged(state))

        if state == .poweredOn && !stateContinuations.isEmpty {
            stateContinuations.forEach { $0.resume(returning: state) }
            stateContinuations.removeAll()
        }
    }

    func handleServiceAdded(_ service: CBService, error: Error?) async {
        if let continuation = serviceAddContinuation {
            if let error = error {
                BleuLogger.peripheral.error("Error adding service: \(error.localizedDescription)")
                continuation.resume(throwing: error)
            } else {
                BleuLogger.peripheral.debug("Successfully added service: \(service.uuid)")
                continuation.resume()
            }
            serviceAddContinuation = nil
        } else {
            // If no continuation is waiting, just log (shouldn't happen in normal flow)
            if let error = error {
                BleuLogger.peripheral.error("Error adding service (no continuation): \(error.localizedDescription)")
            }
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
        _ extractedRequests: [(centralID: UUID, serviceUUID: String?, characteristicUUID: String, value: Data?, offset: Int)]
    ) async {
        // Process the extracted requests
        for (centralID, serviceUUID, characteristicUUID, value, _) in extractedRequests {
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
                        await handleRPCInvocation(data: completeData, characteristicUUID: charUUID, centralID: centralID)
                    }
                    // If nil, packet is part of a larger message, wait for more
                } else {
                    // Regular characteristic write
                    await eventChannel.send(.writeRequestReceived(
                        centralID,  // Real central identifier from CBCentral
                        svcUUID,
                        charUUID,
                        value
                    ))
                }
            }
        }
    }

    private func handleRPCInvocation(data: Data, characteristicUUID: UUID, centralID: UUID) async {
        // Emit write event to EventBridge for RPC processing
        // EventBridge has the correct BLEActorSystem instance registered via setRPCRequestHandler()
        // This maintains proper separation of concerns and instance isolation
        await eventChannel.send(.writeRequestReceived(
            centralID,           // Real central identifier from CBCentral
            UUID(),              // service UUID (would need to be tracked separately)
            characteristicUUID,
            data                 // Complete RPC data (already reassembled from fragments by BLETransport)
        ))
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
        let centralID = central.identifier  // Extract real central identifier

        if subscribed {
            var centrals = subscribedCentrals[charUUID] ?? []
            centrals.insert(central)
            subscribedCentrals[charUUID] = centrals

            var centralIDs = subscribedCentralIDs[charUUID] ?? []
            centralIDs.insert(centralID)
            subscribedCentralIDs[charUUID] = centralIDs

            // CRITICAL: Update MTU for this central in BLETransport
            // This enables optimal packet fragmentation for responses to this central
            let maxUpdateValueLength = central.maximumUpdateValueLength
            let transport = BLETransport.shared
            await transport.updateMaxPayloadSize(for: centralID, maxWriteLength: maxUpdateValueLength)

            BleuLogger.peripheral.debug("Updated MTU for central \(centralID): \(maxUpdateValueLength) bytes")

            await eventChannel.send(.centralSubscribed(
                centralID,  // Real central identifier from CBCentral
                svcUUID,
                charUUID
            ))
        } else {
            subscribedCentrals[charUUID]?.remove(central)
            subscribedCentralIDs[charUUID]?.remove(centralID)

            // Clean up MTU entry when central disconnects
            let transport = BLETransport.shared
            await transport.removeMTU(for: centralID)

            await eventChannel.send(.centralUnsubscribed(
                centralID,  // Real central identifier from CBCentral
                svcUUID,
                charUUID
            ))
        }
    }
}

// MARK: - Delegate Proxy

/// Delegate proxy for CBPeripheralManager to forward callbacks to CoreBluetoothPeripheralManager
fileprivate final class CoreBluetoothPeripheralManagerDelegateProxy: NSObject, CBPeripheralManagerDelegate, @unchecked Sendable {
    weak var actor: CoreBluetoothPeripheralManager?

    init(actor: CoreBluetoothPeripheralManager) {
        self.actor = actor
        super.init()
    }

    // MARK: - CBPeripheralManagerDelegate

    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        Task { [weak actor] in
            await actor?.handleStateUpdate(peripheral.state)
        }
    }

    public func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        Task { [weak actor] in
            await actor?.handleAdvertisingStarted(error: error)
        }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        Task { [weak actor] in
            await actor?.handleServiceAdded(service, error: error)
        }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        // Extract necessary data before Task
        let characteristicUUID = request.characteristic.uuid
        let centralID = request.central.identifier  // Extract real central identifier

        // Handle the response in the delegate to avoid passing non-Sendable objects
        Task { [weak actor] in
            // Get the current value from the actor
            let value = await actor?.currentValue(for: characteristicUUID)

            // Apply offset if needed
            if let value = value, request.offset < value.count {
                request.value = value.subdata(in: request.offset..<value.count)
                peripheral.respond(to: request, withResult: .success)
            } else if request.offset == 0 && value == nil {
                // No value available
                peripheral.respond(to: request, withResult: .readNotPermitted)
            } else {
                // Invalid offset or other error
                peripheral.respond(to: request, withResult: .invalidOffset)
            }

            // Notify the actor about the read request (for logging/tracking)
            let charUUIDString = characteristicUUID.uuidString
            let serviceUUIDString = request.characteristic.service?.uuid.uuidString
            await actor?.trackReadRequest(
                centralID: centralID,
                characteristicUUID: charUUIDString,
                serviceUUID: serviceUUIDString
            )
        }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        // Extract data from requests to avoid Sendable issues
        // CRITICAL: Extract central.identifier for proper multi-client RPC support
        let extractedRequests: [(centralID: UUID, serviceUUID: String?, characteristicUUID: String, value: Data?, offset: Int)] =
            requests.map { request in
                (
                    centralID: request.central.identifier,
                    serviceUUID: request.characteristic.service?.uuid.uuidString,
                    characteristicUUID: request.characteristic.uuid.uuidString,
                    value: request.value,
                    offset: request.offset
                )
            }

        // Respond immediately (as per Apple's documentation)
        if let firstRequest = requests.first {
            peripheral.respond(to: firstRequest, withResult: .success)
        }

        // Process requests asynchronously
        Task { [weak actor] in
            await actor?.handleWriteRequests(extractedRequests)
        }
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didSubscribeTo characteristic: CBCharacteristic
    ) {
        let characteristicUUID = characteristic.uuid.uuidString
        let serviceUUID = characteristic.service?.uuid.uuidString

        Task { [weak actor] in
            await actor?.handleSubscription(
                central: central,
                characteristicUUID: characteristicUUID,
                serviceUUID: serviceUUID,
                subscribed: true
            )
        }
    }

    public func peripheralManager(
        _ peripheral: CBPeripheralManager,
        central: CBCentral,
        didUnsubscribeFrom characteristic: CBCharacteristic
    ) {
        let characteristicUUID = characteristic.uuid.uuidString
        let serviceUUID = characteristic.service?.uuid.uuidString

        Task { [weak actor] in
            await actor?.handleSubscription(
                central: central,
                characteristicUUID: characteristicUUID,
                serviceUUID: serviceUUID,
                subscribed: false
            )
        }
    }
}
