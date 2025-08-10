import Foundation
import CoreBluetooth
import Distributed

/// Distributed Actor System for Bluetooth Low Energy communication
public final class BLEActorSystem: DistributedActorSystem {
    public typealias ActorID = UUID
    public typealias InvocationDecoder = BLEInvocationDecoder
    public typealias InvocationEncoder = BLEInvocationEncoder
    public typealias ResultHandler = BLEResultHandler
    public typealias SerializationRequirement = Codable
    
    private let encoder = BLEInvocationEncoder()
    private let decoder = BLEInvocationDecoder()
    
    // Actor registry for managing remote actors
    private var actorRegistry: [ActorID: any DistributedActor] = [:]
    private var peripheralActors: [CBPeripheral: ActorID] = [:]
    private var centralActors: [CBCentral: ActorID] = [:]
    
    // BLE communication managers
    private var peripheralManager: CBPeripheralManager?
    private var centralManager: CBCentralManager?
    
    // Communication state management
    private var pendingRequests: [UUID: CheckedContinuation<Data, Error>] = [:]
    private var requestTimeouts: [UUID: Task<Void, Never>] = [:]
    private let requestTimeout: TimeInterval = 30.0
    
    // Serialization/Deserialization support
    private let jsonEncoder = JSONEncoder()
    private let jsonDecoder = JSONDecoder()
    
    private let queue = DispatchQueue(label: "com.bleu.actorsystem", qos: .userInteractive)
    private let lock = NSLock()
    
    public init() {
        jsonEncoder.dateEncodingStrategy = .iso8601
        jsonDecoder.dateDecodingStrategy = .iso8601
    }
    
    // MARK: - BLE Manager Setup
    
    public func setupPeripheralManager(delegate: CBPeripheralManagerDelegate, queue: DispatchQueue? = nil) {
        peripheralManager = CBPeripheralManager(delegate: delegate, queue: queue)
    }
    
    public func setupCentralManager(delegate: CBCentralManagerDelegate, queue: DispatchQueue? = nil) {
        centralManager = CBCentralManager(delegate: delegate, queue: queue)
    }
    
    // MARK: - DistributedActorSystem Protocol
    
    public func resolve<Act>(id: ActorID, as actorType: Act.Type) throws -> Act?
        where Act : DistributedActor, Act.ID == ActorID {
        return actorRegistry[id] as? Act
    }
    
    public func assignID<Act>(_ actorType: Act.Type) -> ActorID
        where Act : DistributedActor, Act.ID == ActorID {
        return UUID()
    }
    
    public func actorReady<Act>(_ actor: Act)
        where Act : DistributedActor, Act.ID == ActorID, Act.ActorSystem == BLEActorSystem {
        actorRegistry[actor.id] = actor
    }
    
    public func resignID(_ id: ActorID) {
        actorRegistry.removeValue(forKey: id)
        
        // Clean up BLE references
        peripheralActors = peripheralActors.filter { $0.value != id }
        centralActors = centralActors.filter { $0.value != id }
        
        // Cancel any pending requests for this actor
        lock.lock()
        let requestsToCancel = pendingRequests.filter { _ in
            // In a more sophisticated implementation, we'd track which requests belong to which actor
            // For now, we'll leave pending requests as they may complete normally
            return false
        }
        
        for (requestId, continuation) in requestsToCancel {
            pendingRequests.removeValue(forKey: requestId)
            if let timeoutTask = requestTimeouts.removeValue(forKey: requestId) {
                timeoutTask.cancel()
            }
            continuation.resume(throwing: BleuError.remoteActorUnavailable)
        }
        lock.unlock()
    }
    
    // MARK: - Remote Invocation
    
    public func remoteCall<Act, Err, Res>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: InvocationEncoder,
        throwing: Err.Type,
        returning: Res.Type
    ) async throws -> Res
        where Act : DistributedActor,
              Act.ID == ActorID,
              Err : Error,
              Res : SerializationRequirement {
        
        // Encode the invocation
        guard let invocationData = invocation.data else {
            throw BleuError.serializationFailed
        }
        
        // Create a message for BLE transmission
        let message = BleuMessage(
            serviceUUID: target.serviceUUID,
            characteristicUUID: target.characteristicUUID,
            data: invocationData,
            method: .write
        )
        
        // Send via BLE and await response
        let responseData = try await sendBLEMessage(message, to: actor.id)
        
        // Deserialize response
        guard let response = try? jsonDecoder.decode(Res.self, from: responseData) else {
            throw BleuError.deserializationFailed
        }
        
        return response
    }
    
    public func remoteCallVoid<Act, Err>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: InvocationEncoder,
        throwing: Err.Type
    ) async throws
        where Act : DistributedActor,
              Act.ID == ActorID,
              Err : Error {
        
        guard let invocationData = invocation.data else {
            throw BleuError.serializationFailed
        }
        
        let message = BleuMessage(
            serviceUUID: target.serviceUUID,
            characteristicUUID: target.characteristicUUID,
            data: invocationData,
            method: .writeWithoutResponse
        )
        
        _ = try await sendBLEMessage(message, to: actor.id)
    }
    
    // MARK: - BLE Communication
    
    private func sendBLEMessage(_ message: BleuMessage, to actorID: ActorID) async throws -> Data {
        // Find the corresponding peripheral/central for this actor
        if let peripheral = peripheralActors.first(where: { $0.value == actorID })?.key {
            return try await sendToPeripheral(peripheral, message: message)
        } else if let central = centralActors.first(where: { $0.value == actorID })?.key {
            return try await sendToCentral(central, message: message)
        } else {
            throw BleuError.remoteActorUnavailable
        }
    }
    
    private func sendToPeripheral(_ peripheral: CBPeripheral, message: BleuMessage) async throws -> Data {
        return try await withCheckedThrowingContinuation { continuation in
            let requestId = message.id
            
            lock.lock()
            pendingRequests[requestId] = continuation
            lock.unlock()
            
            // Set up timeout
            let timeoutTask = Task {
                try await Task.sleep(nanoseconds: UInt64(requestTimeout * 1_000_000_000))
                
                lock.lock()
                if let pendingContinuation = pendingRequests.removeValue(forKey: requestId) {
                    requestTimeouts.removeValue(forKey: requestId)
                    lock.unlock()
                    pendingContinuation.resume(throwing: BleuError.communicationTimeout)
                } else {
                    lock.unlock()
                }
            }
            
            lock.lock()
            requestTimeouts[requestId] = timeoutTask
            lock.unlock()
            
            // Perform actual BLE communication
            queue.async { [weak self] in
                self?.performPeripheralCommunication(peripheral: peripheral, message: message)
            }
        }
    }
    
    private func sendToCentral(_ central: CBCentral, message: BleuMessage) async throws -> Data {
        // For central communication, we're responding to requests from peripheral manager
        // This typically involves updating characteristic values that centrals can read
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                self?.performCentralCommunication(central: central, message: message, completion: { result in
                    switch result {
                    case .success(let data):
                        continuation.resume(returning: data)
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                })
            }
        }
    }
    
    // MARK: - Peripheral Communication Implementation
    
    private func performPeripheralCommunication(peripheral: CBPeripheral, message: BleuMessage) {
        // Ensure peripheral is connected
        guard peripheral.state == .connected else {
            completeRequest(id: message.id, with: .failure(BleuError.deviceNotFound))
            return
        }
        
        // Find the target service and characteristic
        let serviceUUID = CBUUID(nsuuid: message.serviceUUID)
        let characteristicUUID = CBUUID(nsuuid: message.characteristicUUID)
        
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }),
              let characteristic = service.characteristics?.first(where: { $0.uuid == characteristicUUID }) else {
            completeRequest(id: message.id, with: .failure(BleuError.characteristicNotFound(message.characteristicUUID)))
            return
        }
        
        // Perform the requested operation
        switch message.method {
        case .read:
            peripheral.readValue(for: characteristic)
        case .write:
            if let data = message.data {
                peripheral.writeValue(data, for: characteristic, type: .withResponse)
            } else {
                completeRequest(id: message.id, with: .failure(BleuError.invalidRequest))
            }
        case .writeWithoutResponse:
            if let data = message.data {
                peripheral.writeValue(data, for: characteristic, type: .withoutResponse)
                // For writes without response, complete immediately
                completeRequest(id: message.id, with: .success(Data()))
            } else {
                completeRequest(id: message.id, with: .failure(BleuError.invalidRequest))
            }
        case .notify, .indicate:
            peripheral.setNotifyValue(true, for: characteristic)
            completeRequest(id: message.id, with: .success(Data()))
        }
    }
    
    // MARK: - Central Communication Implementation
    
    private func performCentralCommunication(
        central: CBCentral,
        message: BleuMessage,
        completion: @escaping (Result<Data, Error>) -> Void
    ) {
        guard let peripheralManager = peripheralManager,
              peripheralManager.state == .poweredOn else {
            completion(.failure(BleuError.bluetoothUnavailable))
            return
        }
        
        // Find the characteristic to update
        let characteristicUUID = CBUUID(nsuuid: message.characteristicUUID)
        var targetCharacteristic: CBMutableCharacteristic?
        
        for service in peripheralManager.services ?? [] {
            if let characteristics = service.characteristics {
                for characteristic in characteristics {
                    if characteristic.uuid == characteristicUUID {
                        targetCharacteristic = characteristic as? CBMutableCharacteristic
                        break
                    }
                }
            }
            if targetCharacteristic != nil { break }
        }
        
        guard let characteristic = targetCharacteristic else {
            completion(.failure(BleuError.characteristicNotFound(message.characteristicUUID)))
            return
        }
        
        // Update characteristic value for central to read
        if let data = message.data {
            let success = peripheralManager.updateValue(data, for: characteristic, onSubscribedCentrals: [central])
            if success {
                completion(.success(data))
            } else {
                completion(.failure(BleuError.communicationTimeout))
            }
        } else {
            // For read operations, return current value
            completion(.success(characteristic.value ?? Data()))
        }
    }
    
    // MARK: - Request Completion Management
    
    private func completeRequest(id: UUID, with result: Result<Data, Error>) {
        lock.lock()
        guard let continuation = pendingRequests.removeValue(forKey: id) else {
            lock.unlock()
            return
        }
        
        // Cancel timeout task
        if let timeoutTask = requestTimeouts.removeValue(forKey: id) {
            timeoutTask.cancel()
        }
        lock.unlock()
        
        switch result {
        case .success(let data):
            continuation.resume(returning: data)
        case .failure(let error):
            continuation.resume(throwing: error)
        }
    }
    
    // MARK: - Public Callback Methods
    
    /// Called when a peripheral characteristic value is updated
    public func handlePeripheralValueUpdate(characteristic: CBCharacteristic, data: Data?, error: Error?) {
        // Find pending requests that match this characteristic
        let characteristicUUID = UUID(uuidString: characteristic.uuid.uuidString)
        
        lock.lock()
        let matchingRequests = pendingRequests.filter { (requestId, _) in
            // In a real implementation, you'd track which request corresponds to which characteristic
            // For now, we'll complete the first pending request
            return true
        }
        lock.unlock()
        
        // Complete the first matching request
        if let (requestId, _) = matchingRequests.first {
            if let error = error {
                completeRequest(id: requestId, with: .failure(error))
            } else {
                completeRequest(id: requestId, with: .success(data ?? Data()))
            }
        }
    }
    
    /// Called when a peripheral write operation completes
    public func handlePeripheralWriteCompletion(characteristic: CBCharacteristic, error: Error?) {
        // Find and complete write requests
        lock.lock()
        let matchingRequests = pendingRequests.filter { (requestId, _) in
            return true // In real implementation, match by characteristic
        }
        lock.unlock()
        
        if let (requestId, _) = matchingRequests.first {
            if let error = error {
                completeRequest(id: requestId, with: .failure(error))
            } else {
                completeRequest(id: requestId, with: .success(Data()))
            }
        }
    }
    
    // MARK: - BLE Device Management
    
    public func registerPeripheral(_ peripheral: CBPeripheral, for actorID: ActorID) {
        peripheralActors[peripheral] = actorID
    }
    
    public func registerCentral(_ central: CBCentral, for actorID: ActorID) {
        centralActors[central] = actorID
    }
}

// MARK: - Remote Call Target

public struct RemoteCallTarget: Sendable {
    public let serviceUUID: UUID
    public let characteristicUUID: UUID
    public let method: String
    
    public init(serviceUUID: UUID, characteristicUUID: UUID, method: String) {
        self.serviceUUID = serviceUUID
        self.characteristicUUID = characteristicUUID
        self.method = method
    }
}

// MARK: - Invocation Encoder/Decoder

public struct BLEInvocationEncoder: DistributedTargetInvocationEncoder {
    public typealias SerializationRequirement = Codable
    
    private var _data: Data?
    private let encoder = JSONEncoder()
    
    public init() {
        encoder.dateEncodingStrategy = .iso8601
    }
    
    public var data: Data? {
        return _data
    }
    
    public mutating func recordGenericSubstitution<T>(_ type: T.Type) throws {}
    
    public mutating func recordArgument<Value: SerializationRequirement>(_ argument: RemoteCallArgument<Value>) throws {
        let encoded = try encoder.encode(argument.value)
        _data = encoded
    }
    
    public mutating func recordReturnType<R: SerializationRequirement>(_ type: R.Type) throws {}
    
    public mutating func recordErrorType<E: Error>(_ type: E.Type) throws {}
    
    public mutating func doneRecording() throws {}
}

public struct BLEInvocationDecoder: DistributedTargetInvocationDecoder {
    public typealias SerializationRequirement = Codable
    
    private let decoder = JSONDecoder()
    private let data: Data
    
    public init(data: Data = Data()) {
        self.data = data
        decoder.dateDecodingStrategy = .iso8601
    }
    
    public mutating func decodeGenericSubstitutions() throws -> [Any.Type] {
        return []
    }
    
    public mutating func decodeNextArgument<Argument: SerializationRequirement>() throws -> Argument {
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