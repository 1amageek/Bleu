import Foundation
import CoreBluetooth
import Distributed

// MARK: - Continuation Management

/// Wrapper for managing CheckedContinuation with timeout and cleanup
private class ContinuationWrapper<T> {
    private let continuation: CheckedContinuation<T, Error>
    private var isCompleted: Bool = false
    private let lock = NSLock()
    
    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }
    
    func complete(with result: Result<T, Error>) {
        lock.lock()
        defer { lock.unlock() }
        
        guard !isCompleted else { return }
        isCompleted = true
        
        switch result {
        case .success(let value):
            continuation.resume(returning: value)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
    
    func completeIfNeeded(with error: Error) {
        lock.lock()
        defer { lock.unlock() }
        
        guard !isCompleted else { return }
        isCompleted = true
        continuation.resume(throwing: error)
    }
}

/// Distributed actor representing a BLE Central (Client)
public distributed actor CentralActor {
    public typealias ActorSystem = BLEActorSystem
    
    private let serviceUUIDs: [UUID]
    private let options: ConnectionOptions
    private var centralManager: CBCentralManager?
    private var delegate: CentralDelegate?
    
    // Device management
    private var discoveredPeripherals: [UUID: DeviceInfo] = [:]
    private var connectedPeripherals: [UUID: CBPeripheral] = [:]
    private var peripheralActors: [UUID: PeripheralActor] = [:]
    
    // Operation management
    private var isScanning: Bool = false
    private var scanContinuation: CheckedContinuation<[DeviceInfo], Error>?
    private var connectionContinuations: [UUID: ContinuationWrapper<Void>] = [:]
    private var requestContinuations: [UUID: ContinuationWrapper<Data?>] = [:]
    
    // Notification streams
    private var notificationStreams: [UUID: AsyncStream<Data>.Continuation] = [:]
    
    // Timeout management
    private var timeoutTasks: [UUID: Task<Void, Never>] = [:]
    private let continuationLock = NSLock()
    
    public init(
        actorSystem: ActorSystem,
        serviceUUIDs: [UUID] = [],
        options: ConnectionOptions = ConnectionOptions()
    ) {
        self.serviceUUIDs = serviceUUIDs
        self.options = options
        self.actorSystem = actorSystem
        
        Task { @BluetoothActor in
            await setupCentral()
        }
    }
    
    // MARK: - Setup
    
    @BluetoothActor
    private func setupCentral() async {
        delegate = CentralDelegate(actor: self)
        centralManager = CBCentralManager(
            delegate: delegate,
            queue: DispatchQueue(label: "com.bleu.central.\(id)")
        )
    }
    
    // MARK: - Distributed Methods
    
    /// Scan for peripherals
    public distributed func scanForPeripherals(
        timeout: TimeInterval = 10.0
    ) async throws -> [DeviceInfo] {
        guard let centralManager = centralManager,
              centralManager.state == .poweredOn else {
            throw BleuError.bluetoothUnavailable
        }
        
        guard !isScanning else {
            throw BleuError.invalidRequest
        }
        
        return try await withCheckedThrowingContinuation { continuation in
            scanContinuation = continuation
            isScanning = true
            
            // Start scanning
            let cbuuids = serviceUUIDs.isEmpty ? nil : serviceUUIDs.map { CBUUID(nsuuid: $0) }
            centralManager.scanForPeripherals(withServices: cbuuids, options: nil)
            
            // Set timeout
            Task {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                await stopScanning()
                continuation.resume(returning: Array(discoveredPeripherals.values))
            }
        }
    }
    
    /// Stop scanning
    public distributed func stopScanning() async {
        centralManager?.stopScan()
        isScanning = false
        
        if let continuation = scanContinuation {
            scanContinuation = nil
            continuation.resume(returning: Array(discoveredPeripherals.values))
        }
    }
    
    /// Connect to a peripheral
    public distributed func connect(to deviceId: DeviceIdentifier) async throws -> PeripheralActor {
        guard let centralManager = centralManager else {
            throw BleuError.bluetoothUnavailable
        }
        
        // Check if already connected
        if let existingActor = peripheralActors[deviceId.uuid] {
            return existingActor
        }
        
        // Find discovered peripheral
        guard let deviceInfo = discoveredPeripherals[deviceId.uuid],
              let peripheral = findPeripheral(uuid: deviceId.uuid) else {
            throw BleuError.deviceNotFound
        }
        
        // Connect
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let wrapper = ContinuationWrapper(continuation)
            
            continuationLock.lock()
            connectionContinuations[deviceId.uuid] = wrapper
            continuationLock.unlock()
            
            // Set timeout
            let timeoutTask = Task {
                try await Task.sleep(nanoseconds: UInt64(options.timeout * 1_000_000_000))
                
                continuationLock.lock()
                let continuationWrapper = connectionContinuations.removeValue(forKey: deviceId.uuid)
                timeoutTasks.removeValue(forKey: deviceId.uuid)
                continuationLock.unlock()
                
                continuationWrapper?.completeIfNeeded(with: BleuError.communicationTimeout)
            }
            
            continuationLock.lock()
            timeoutTasks[deviceId.uuid] = timeoutTask
            continuationLock.unlock()
            
            centralManager.connect(peripheral, options: nil)
        }
        
        // Create remote peripheral actor
        let config = ServiceConfiguration(
            serviceUUID: serviceUUIDs.first ?? UUID(),
            characteristicUUIDs: []
        )
        let peripheralActor = PeripheralActor(
            actorSystem: actorSystem,
            configuration: config,
            advertisementData: deviceInfo.advertisementData
        )
        
        peripheralActors[deviceId.uuid] = peripheralActor
        connectedPeripherals[deviceId.uuid] = peripheral
        
        // Register with actor system
        actorSystem.registerPeripheral(peripheral, for: peripheralActor.id)
        
        return peripheralActor
    }
    
    /// Disconnect from a peripheral
    public distributed func disconnect(from deviceId: DeviceIdentifier) async throws {
        guard let centralManager = centralManager,
              let peripheral = connectedPeripherals[deviceId.uuid] else {
            throw BleuError.deviceNotFound
        }
        
        centralManager.cancelPeripheralConnection(peripheral)
        
        // Clean up
        peripheralActors.removeValue(forKey: deviceId.uuid)
        connectedPeripherals.removeValue(forKey: deviceId.uuid)
    }
    
    /// Send a request to a connected peripheral
    public distributed func sendRequest(
        to deviceId: DeviceIdentifier,
        message: BleuMessage
    ) async throws -> Data? {
        guard let peripheral = connectedPeripherals[deviceId.uuid] else {
            throw BleuError.deviceNotFound
        }
        
        // Discover services and characteristics if needed
        try await discoverServicesAndCharacteristics(for: peripheral, message: message)
        
        // Find the characteristic
        guard let characteristic = findCharacteristic(
            serviceUUID: message.serviceUUID,
            characteristicUUID: message.characteristicUUID,
            in: peripheral
        ) else {
            throw BleuError.characteristicNotFound(message.characteristicUUID)
        }
        
        // Send request based on method
        switch message.method {
        case .read:
            return try await performRead(peripheral: peripheral, characteristic: characteristic)
        case .write, .writeWithoutResponse:
            try await performWrite(
                peripheral: peripheral,
                characteristic: characteristic,
                data: message.data ?? Data(),
                withResponse: message.method == .write
            )
            return nil
        case .notify, .indicate:
            try await performNotification(
                peripheral: peripheral,
                characteristic: characteristic,
                enabled: true
            )
            return nil
        }
    }
    
    /// Subscribe to notifications from a characteristic
    public distributed func subscribeToNotifications(
        from deviceId: DeviceIdentifier,
        characteristicUUID: UUID
    ) async throws -> AsyncStream<Data> {
        guard let peripheral = connectedPeripherals[deviceId.uuid] else {
            throw BleuError.deviceNotFound
        }
        
        return AsyncStream<Data> { continuation in
            notificationStreams[characteristicUUID] = continuation
            
            Task {
                // Enable notifications
                let message = BleuMessage(
                    serviceUUID: serviceUUIDs.first ?? UUID(),
                    characteristicUUID: characteristicUUID,
                    method: .notify
                )
                
                try await discoverServicesAndCharacteristics(for: peripheral, message: message)
                
                guard let characteristic = findCharacteristic(
                    serviceUUID: message.serviceUUID,
                    characteristicUUID: characteristicUUID,
                    in: peripheral
                ) else {
                    continuation.finish()
                    return
                }
                
                try await performNotification(
                    peripheral: peripheral,
                    characteristic: characteristic,
                    enabled: true
                )
            }
        }
    }
    
    /// Get connected peripherals
    public distributed var connectedPeripherals: [DeviceIdentifier] { get async
        return connectedPeripherals.keys.compactMap { uuid in
            discoveredPeripherals[uuid]?.identifier
        }
    }
    
    // MARK: - Internal Operations
    
    private func discoverServicesAndCharacteristics(for peripheral: CBPeripheral, message: BleuMessage) async throws {
        // Check if service exists
        let serviceUUID = CBUUID(nsuuid: message.serviceUUID)
        let service = peripheral.services?.first { $0.uuid == serviceUUID }
        
        if service == nil {
            // Discover services
            peripheral.discoverServices([serviceUUID])
            // In real implementation, this would wait for delegate callback
            try await Task.sleep(nanoseconds: 100_000_000) // 0.1 second
        }
        
        guard let discoveredService = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            throw BleuError.serviceNotFound(message.serviceUUID)
        }
        
        // Check if characteristic exists
        let characteristicUUID = CBUUID(nsuuid: message.characteristicUUID)
        let characteristic = discoveredService.characteristics?.first { $0.uuid == characteristicUUID }
        
        if characteristic == nil {
            // Discover characteristics
            peripheral.discoverCharacteristics([characteristicUUID], for: discoveredService)
            // In real implementation, this would wait for delegate callback
            try await Task.sleep(nanoseconds: 100_000_000) // 0.1 second
        }
    }
    
    private func performRead(peripheral: CBPeripheral, characteristic: CBCharacteristic) async throws -> Data? {
        return try await withCheckedThrowingContinuation { continuation in
            let requestId = UUID()
            let wrapper = ContinuationWrapper(continuation)
            
            continuationLock.lock()
            requestContinuations[requestId] = wrapper
            continuationLock.unlock()
            
            // Timeout
            let timeoutTask = Task {
                try await Task.sleep(nanoseconds: UInt64(options.timeout * 1_000_000_000))
                
                continuationLock.lock()
                let continuationWrapper = requestContinuations.removeValue(forKey: requestId)
                timeoutTasks.removeValue(forKey: requestId)
                continuationLock.unlock()
                
                continuationWrapper?.completeIfNeeded(with: BleuError.communicationTimeout)
            }
            
            continuationLock.lock()
            timeoutTasks[requestId] = timeoutTask
            continuationLock.unlock()
            
            peripheral.readValue(for: characteristic)
        }
    }
    
    private func performWrite(
        peripheral: CBPeripheral,
        characteristic: CBCharacteristic,
        data: Data,
        withResponse: Bool
    ) async throws {
        if withResponse {
            // For write with response, we need to wait for write completion callback
            _ = try await performWriteWithResponse(peripheral: peripheral, characteristic: characteristic, data: data)
        } else {
            peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
        }
    }
    
    private func performWriteWithResponse(peripheral: CBPeripheral, characteristic: CBCharacteristic, data: Data) async throws -> Data? {
        return try await withCheckedThrowingContinuation { continuation in
            let requestId = UUID()
            let wrapper = ContinuationWrapper(continuation)
            
            continuationLock.lock()
            requestContinuations[requestId] = wrapper
            continuationLock.unlock()
            
            // Timeout
            let timeoutTask = Task {
                try await Task.sleep(nanoseconds: UInt64(options.timeout * 1_000_000_000))
                
                continuationLock.lock()
                let continuationWrapper = requestContinuations.removeValue(forKey: requestId)
                timeoutTasks.removeValue(forKey: requestId)
                continuationLock.unlock()
                
                continuationWrapper?.completeIfNeeded(with: BleuError.communicationTimeout)
            }
            
            continuationLock.lock()
            timeoutTasks[requestId] = timeoutTask
            continuationLock.unlock()
            
            peripheral.writeValue(data, for: characteristic, type: .withResponse)
        }
    }
    
    private func performNotification(
        peripheral: CBPeripheral,
        characteristic: CBCharacteristic,
        enabled: Bool
    ) async throws {
        peripheral.setNotifyValue(enabled, for: characteristic)
        // In real implementation, would wait for delegate callback
    }
    
    private func findPeripheral(uuid: UUID) -> CBPeripheral? {
        return connectedPeripherals[uuid] ?? 
               centralManager?.retrievePeripherals(withIdentifiers: [uuid]).first
    }
    
    private func findCharacteristic(
        serviceUUID: UUID,
        characteristicUUID: UUID,
        in peripheral: CBPeripheral
    ) -> CBCharacteristic? {
        let serviceUUID = CBUUID(nsuuid: serviceUUID)
        let characteristicUUID = CBUUID(nsuuid: characteristicUUID)
        
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            return nil
        }
        
        return service.characteristics?.first { $0.uuid == characteristicUUID }
    }
    
    // MARK: - Delegate Communication
    
    internal func handleDiscoveredPeripheral(
        peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi: NSNumber
    ) async {
        let deviceInfo = DeviceInfo(
            identifier: DeviceIdentifier(uuid: peripheral.identifier, name: peripheral.name),
            rssi: rssi.intValue,
            advertisementData: parseAdvertisementData(advertisementData),
            isConnectable: true
        )
        
        discoveredPeripherals[peripheral.identifier] = deviceInfo
    }
    
    internal func handleConnectionSuccess(peripheral: CBPeripheral) async {
        continuationLock.lock()
        let wrapper = connectionContinuations.removeValue(forKey: peripheral.identifier)
        let timeoutTask = timeoutTasks.removeValue(forKey: peripheral.identifier)
        continuationLock.unlock()
        
        timeoutTask?.cancel()
        wrapper?.complete(with: .success(()))
    }
    
    internal func handleConnectionFailure(peripheral: CBPeripheral, error: Error?) async {
        continuationLock.lock()
        let wrapper = connectionContinuations.removeValue(forKey: peripheral.identifier)
        let timeoutTask = timeoutTasks.removeValue(forKey: peripheral.identifier)
        continuationLock.unlock()
        
        timeoutTask?.cancel()
        wrapper?.complete(with: .failure(error ?? BleuError.connectionFailed("Unknown error")))
    }
    
    internal func handleCharacteristicUpdate(characteristic: CBCharacteristic, error: Error?) async {
        if let error = error {
            // Handle error
            return
        }
        
        guard let data = characteristic.value,
              let characteristicUUID = UUID(uuidString: characteristic.uuid.uuidString) else {
            return
        }
        
        // Send to notification stream
        if let continuation = notificationStreams[characteristicUUID] {
            continuation.yield(data)
        }
        
        // Complete read/write requests
        continuationLock.lock()
        let pendingRequests = Array(requestContinuations.keys)
        continuationLock.unlock()
        
        // Complete the first pending request (in a real implementation, we'd match by characteristic)
        if let requestId = pendingRequests.first {
            continuationLock.lock()
            let wrapper = requestContinuations.removeValue(forKey: requestId)
            let timeoutTask = timeoutTasks.removeValue(forKey: requestId)
            continuationLock.unlock()
            
            timeoutTask?.cancel()
            wrapper?.complete(with: .success(data))
        }
    }
    
    internal func handleWriteCompletion(characteristic: CBCharacteristic, error: Error?) async {\n        // Complete write requests\n        continuationLock.lock()\n        let pendingRequests = Array(requestContinuations.keys)\n        continuationLock.unlock()\n        \n        // Complete write request (in a real implementation, we'd match by characteristic)\n        if let requestId = pendingRequests.first {\n            continuationLock.lock()\n            let wrapper = requestContinuations.removeValue(forKey: requestId)\n            let timeoutTask = timeoutTasks.removeValue(forKey: requestId)\n            continuationLock.unlock()\n            \n            timeoutTask?.cancel()\n            if let error = error {\n                wrapper?.complete(with: .failure(error))\n            } else {\n                wrapper?.complete(with: .success(Data())) // Write operations return empty data on success\n            }\n        }\n    }\n    \n    internal func handleServiceDiscovery(peripheral: CBPeripheral, error: Error?) async {\n        // In a production implementation, this would notify waiting operations\n        // that service discovery is complete\n        if let error = error {\n            print(\"Service discovery failed: \\(error)\")\n        }\n    }\n    \n    internal func handleCharacteristicDiscovery(peripheral: CBPeripheral, service: CBService, error: Error?) async {\n        // In a production implementation, this would notify waiting operations\n        // that characteristic discovery is complete\n        if let error = error {\n            print(\"Characteristic discovery failed for service \\(service.uuid): \\(error)\")\n        }\n    }\n    \n    private func parseAdvertisementData(_ data: [String: Any]) -> AdvertisementData {
        let localName = data[CBAdvertisementDataLocalNameKey] as? String
        let serviceUUIDs = (data[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.map { 
            UUID(uuidString: $0.uuidString) ?? UUID() 
        } ?? []
        let manufacturerData = data[CBAdvertisementDataManufacturerDataKey] as? Data
        
        return AdvertisementData(
            localName: localName,
            serviceUUIDs: serviceUUIDs,
            manufacturerData: manufacturerData
        )
    }
    
    // MARK: - Lifecycle
    
    public distributed func shutdown() async {
        await stopScanning()
        
        // Disconnect all peripherals
        for peripheral in connectedPeripherals.values {
            centralManager?.cancelPeripheralConnection(peripheral)
        }
        
        // Clean up device tracking
        connectedPeripherals.removeAll()
        peripheralActors.removeAll()
        discoveredPeripherals.removeAll()
        
        // Complete pending continuations with proper locking
        continuationLock.lock()
        
        // Complete connection continuations
        for wrapper in connectionContinuations.values {
            wrapper.completeIfNeeded(with: BleuError.remoteActorUnavailable)
        }
        connectionContinuations.removeAll()
        
        // Complete request continuations
        for wrapper in requestContinuations.values {
            wrapper.completeIfNeeded(with: BleuError.remoteActorUnavailable)
        }
        requestContinuations.removeAll()
        
        // Cancel all timeout tasks
        for task in timeoutTasks.values {
            task.cancel()
        }
        timeoutTasks.removeAll()
        
        continuationLock.unlock()
        
        // Finish notification streams
        for continuation in notificationStreams.values {
            continuation.finish()
        }
        notificationStreams.removeAll()
        
        centralManager = nil
        delegate = nil
    }
}

// MARK: - Central Delegate

private class CentralDelegate: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    weak var actor: CentralActor?
    
    init(actor: CentralActor) {
        self.actor = actor
    }
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @BluetoothActor in
            await BluetoothActor.shared.updateBluetoothState(central.state)
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        guard let actor = actor else { return }
        Task {
            await actor.handleDiscoveredPeripheral(
                peripheral: peripheral,
                advertisementData: advertisementData,
                rssi: RSSI
            )
        }
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        guard let actor = actor else { return }
        Task {
            await actor.handleConnectionSuccess(peripheral: peripheral)
        }
    }
    
    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        guard let actor = actor else { return }
        Task {
            await actor.handleConnectionFailure(peripheral: peripheral, error: error)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let actor = actor else { return }
        Task {
            await actor.handleCharacteristicUpdate(characteristic: characteristic, error: error)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let actor = actor else { return }
        Task {
            await actor.handleWriteCompletion(characteristic: characteristic, error: error)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let actor = actor else { return }
        Task {
            await actor.handleServiceDiscovery(peripheral: peripheral, error: error)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let actor = actor else { return }
        Task {
            await actor.handleCharacteristicDiscovery(peripheral: peripheral, service: service, error: error)
        }
    }
}