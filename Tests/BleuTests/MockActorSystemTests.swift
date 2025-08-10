import Testing
import CoreBluetooth
@testable import Bleu

/// Mock Distributed Actor System for testing purposes
public final class MockBLEActorSystem: DistributedActorSystem {
    public typealias ActorID = UUID
    public typealias InvocationDecoder = BLEInvocationDecoder  
    public typealias InvocationEncoder = BLEInvocationEncoder
    public typealias ResultHandler = BLEResultHandler
    public typealias SerializationRequirement = Codable
    
    private var actors: [ActorID: any DistributedActor] = [:]
    public var mockBluetoothState: CBManagerState = .poweredOn
    public var mockResponses: [String: Data] = [:]
    
    public func resolve<Act>(id: ActorID, as actorType: Act.Type) throws -> Act? where Act : DistributedActor, Act.ID == UUID {
        return actors[id] as? Act
    }
    
    public func assignID<Act>(_ actorType: Act.Type) -> UUID where Act : DistributedActor, Act.ID == UUID {
        return UUID()
    }
    
    public func actorReady<Act>(_ actor: Act) where Act : DistributedActor, Act.ID == UUID, Act.ActorSystem == MockBLEActorSystem {
        actors[actor.id] = actor
    }
    
    public func resignID(_ id: UUID) {
        actors.removeValue(forKey: id)
    }
    
    public func remoteCall<Act, Err, Res>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: InvocationEncoder,
        throwing: Err.Type,
        returning: Res.Type
    ) async throws -> Res where Act : DistributedActor, Act.ID == UUID, Err : Error, Res : SerializationRequirement {
        
        // Simulate network delay
        try await Task.sleep(nanoseconds: 10_000_000) // 0.01 seconds
        
        // Return mock response if available
        let key = "\(target.method)_\(target.characteristicUUID)"
        if let mockData = mockResponses[key] {
            let decoder = JSONDecoder()
            return try decoder.decode(Res.self, from: mockData)
        }
        
        throw BleuError.invalidRequest
    }
    
    public func remoteCallVoid<Act, Err>(
        on actor: Act,
        target: RemoteCallTarget,
        invocation: InvocationEncoder,
        throwing: Err.Type
    ) async throws where Act : DistributedActor, Act.ID == UUID, Err : Error {
        
        // Simulate network delay
        try await Task.sleep(nanoseconds: 5_000_000) // 0.005 seconds
        
        // Mock void calls always succeed
    }
    
    // MARK: - Mock Configuration
    
    public func setMockBluetoothState(_ state: CBManagerState) {
        mockBluetoothState = state
    }
    
    public func setMockResponse<T: Codable>(_ response: T, for method: String, characteristicUUID: UUID) throws {
        let encoder = JSONEncoder()
        let data = try encoder.encode(response)
        let key = "\(method)_\(characteristicUUID)"
        mockResponses[key] = data
    }
    
    public func clearMockResponses() {
        mockResponses.removeAll()
    }
}

@Suite("Mock Actor System Tests")
struct MockActorSystemTests {
    
    @Test("Mock system initialization")
    func mockSystemInitialization() {
        let mockSystem = MockBLEActorSystem()
        
        // Test ID assignment
        let id1 = mockSystem.assignID(PeripheralActor.self)
        let id2 = mockSystem.assignID(CentralActor.self)
        
        #expect(id1 != id2)
    }
    
    @Test("Mock response configuration", .serialized)
    func mockResponseConfiguration() throws {
        let mockSystem = MockBLEActorSystem()
        let characteristicUUID = UUID()
        
        let mockResponse = GetDeviceInfoRequest.Response(
            deviceName: "Mock Device",
            firmwareVersion: "Mock 1.0",
            batteryLevel: 75
        )
        
        try mockSystem.setMockResponse(
            mockResponse,
            for: "getDeviceInfo",
            characteristicUUID: characteristicUUID
        )
        
        // The mock system should now be configured
        #expect(mockSystem.mockResponses.count == 1)
    }
    
    @Test("Mock Bluetooth state management")
    func mockBluetoothStateManagement() {
        let mockSystem = MockBLEActorSystem()
        
        mockSystem.setMockBluetoothState(.poweredOff)
        #expect(mockSystem.mockBluetoothState == .poweredOff)
        
        mockSystem.setMockBluetoothState(.poweredOn)
        #expect(mockSystem.mockBluetoothState == .poweredOn)
    }
    
    @Test("Mock response clearing")
    func mockResponseClearing() throws {
        let mockSystem = MockBLEActorSystem()
        
        let response = GetDeviceInfoRequest.Response(
            deviceName: "Test",
            firmwareVersion: "1.0",
            batteryLevel: 50
        )
        
        try mockSystem.setMockResponse(
            response,
            for: "test",
            characteristicUUID: UUID()
        )
        
        #expect(mockSystem.mockResponses.count == 1)
        
        mockSystem.clearMockResponses()
        #expect(mockSystem.mockResponses.isEmpty)
    }
}

/// Mock Peripheral for testing
actor MockPeripheral {
    private let mockSystem: MockBLEActorSystem
    private let serviceUUID: UUID
    private let characteristicUUIDs: [UUID]
    
    init(serviceUUID: UUID, characteristicUUIDs: [UUID]) {
        self.mockSystem = MockBLEActorSystem()
        self.serviceUUID = serviceUUID
        self.characteristicUUIDs = characteristicUUIDs
    }
    
    func setupMockResponse<T: Codable>(_ response: T, for method: String, characteristicUUID: UUID) throws {
        try mockSystem.setMockResponse(response, for: method, characteristicUUID: characteristicUUID)
    }
    
    func simulateRequest<T: Codable>(_ requestType: T.Type, method: String, characteristicUUID: UUID) async throws -> T {
        let target = RemoteCallTarget(serviceUUID: serviceUUID, characteristicUUID: characteristicUUID, method: method)
        let encoder = BLEInvocationEncoder()
        
        return try await mockSystem.remoteCall(
            on: MockDistributedActor(id: UUID(), actorSystem: mockSystem),
            target: target,
            invocation: encoder,
            throwing: BleuError.self,
            returning: T.self
        )
    }
}

/// Mock Distributed Actor for testing
public struct MockDistributedActor: DistributedActor {
    public typealias ActorSystem = MockBLEActorSystem
    
    public let id: UUID
    public let actorSystem: MockBLEActorSystem
    
    public init(id: UUID, actorSystem: MockBLEActorSystem) {
        self.id = id
        self.actorSystem = actorSystem
    }
}

@Suite("Mock Integration Tests", .serialized)
struct MockIntegrationTests {
    
    @Test("Mock peripheral response simulation")
    func mockPeripheralResponseSimulation() async throws {
        let serviceUUID = UUID()
        let characteristicUUID = UUID()
        
        let mockPeripheral = MockPeripheral(
            serviceUUID: serviceUUID,
            characteristicUUIDs: [characteristicUUID]
        )
        
        // Setup mock response
        let expectedResponse = GetDeviceInfoRequest.Response(
            deviceName: "Mock BLE Device",
            firmwareVersion: "2.1.0",
            batteryLevel: 42
        )
        
        try await mockPeripheral.setupMockResponse(
            expectedResponse,
            for: "getDeviceInfo",
            characteristicUUID: characteristicUUID
        )
        
        // Simulate request
        let actualResponse = try await mockPeripheral.simulateRequest(
            GetDeviceInfoRequest.Response.self,
            method: "getDeviceInfo",
            characteristicUUID: characteristicUUID
        )
        
        // Verify response
        #expect(actualResponse.deviceName == expectedResponse.deviceName)
        #expect(actualResponse.firmwareVersion == expectedResponse.firmwareVersion)
        #expect(actualResponse.batteryLevel == expectedResponse.batteryLevel)
    }
    
    @Test("Mock system latency simulation")
    func mockSystemLatencySimulation() async throws {
        let mockSystem = MockBLEActorSystem()
        let actor = MockDistributedActor(id: UUID(), actorSystem: mockSystem)
        let target = RemoteCallTarget(
            serviceUUID: UUID(),
            characteristicUUID: UUID(),
            method: "ping"
        )
        
        let startTime = Date()
        
        // This should take at least 10ms due to mock delay
        do {
            let encoder = BLEInvocationEncoder()
            _ = try await mockSystem.remoteCall(
                on: actor,
                target: target,
                invocation: encoder,
                throwing: BleuError.self,
                returning: String.self
            )
        } catch {
            // Expected to fail since no mock response is set
        }
        
        let duration = Date().timeIntervalSince(startTime)
        #expect(duration >= 0.01) // At least 10ms delay
    }
}

@Suite("Error Handling in Mock System")
struct MockErrorHandlingTests {
    
    @Test("Mock system error simulation")
    func mockSystemErrorSimulation() async throws {
        let mockSystem = MockBLEActorSystem()
        let actor = MockDistributedActor(id: UUID(), actorSystem: mockSystem)
        let target = RemoteCallTarget(
            serviceUUID: UUID(),
            characteristicUUID: UUID(),
            method: "nonExistentMethod"
        )
        
        // Should throw invalidRequest since no mock response is configured
        do {
            let encoder = BLEInvocationEncoder()
            _ = try await mockSystem.remoteCall(
                on: actor,
                target: target,
                invocation: encoder,
                throwing: BleuError.self,
                returning: String.self
            )
            Issue.record("Expected BleuError.invalidRequest to be thrown")
        } catch let error as BleuError {
            #expect(error == .invalidRequest)
        } catch {
            Issue.record("Unexpected error type: \(error)")
        }
    }
    
    @Test("Mock actor lifecycle")
    func mockActorLifecycle() {
        let mockSystem = MockBLEActorSystem()
        let actorId = UUID()
        let actor = MockDistributedActor(id: actorId, actorSystem: mockSystem)
        
        // Register actor
        mockSystem.actorReady(actor)
        
        // Resolve actor
        let resolvedActor = try? mockSystem.resolve(id: actorId, as: MockDistributedActor.self)
        #expect(resolvedActor?.id == actorId)
        
        // Resign actor
        mockSystem.resignID(actorId)
        
        // Should no longer be resolvable
        let resignedActor = try? mockSystem.resolve(id: actorId, as: MockDistributedActor.self)
        #expect(resignedActor == nil)
    }
}