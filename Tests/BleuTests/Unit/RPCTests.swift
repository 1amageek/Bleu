import Testing
import Foundation
import Distributed
import ActorRuntime
@testable import Bleu

/// Test suite for RPC functionality
@Suite("RPC Tests")
struct RPCTests {
    
    @Test("Method Registry Registration")
    func testMethodRegistration() async {
        let registry = MethodRegistry.shared
        let actorID = UUID()
        
        // Register a simple method
        await registry.register(
            actorID: actorID,
            methodName: "testMethod",
            handler: { _ in
                return try JSONEncoder().encode("test result")
            }
        )
        
        // Verify method is registered
        let hasMethod = await registry.hasMethod(actorID: actorID, methodName: "testMethod")
        #expect(hasMethod == true)
        
        // Verify method list
        let methods = await registry.getMethods(for: actorID)
        #expect(methods.contains("testMethod"))
        
        // Clean up
        await registry.unregister(actorID: actorID)
    }
    
    @Test("Method Execution")
    func testMethodExecution() async throws {
        let registry = MethodRegistry.shared
        let actorID = UUID()
        
        struct TestResult: Codable, Sendable {
            let value: String
        }
        
        // Register a method that returns data
        await registry.register(
            actorID: actorID,
            methodName: "getValue",
            handler: { _ in
                let result = TestResult(value: "Hello, BLE!")
                return try JSONEncoder().encode(result)
            }
        )
        
        // Execute the method
        let resultData = try await registry.execute(
            actorID: actorID,
            methodName: "getValue",
            arguments: []
        )
        
        // Decode and verify result
        let result = try JSONDecoder().decode(TestResult.self, from: resultData)
        #expect(result.value == "Hello, BLE!")
        
        // Clean up
        await registry.unregister(actorID: actorID)
    }
    
    @Test("Method with Arguments")
    func testMethodWithArguments() async throws {
        let registry = MethodRegistry.shared
        let actorID = UUID()
        
        struct TestInput: Codable, Sendable {
            let number: Int
        }
        
        struct TestOutput: Codable, Sendable {
            let doubled: Int
        }
        
        // Register a method that processes arguments
        await registry.register(
            actorID: actorID,
            methodName: "doubleValue",
            handler: { data in
                let input = try JSONDecoder().decode(TestInput.self, from: data)
                let output = TestOutput(doubled: input.number * 2)
                return try JSONEncoder().encode(output)
            }
        )
        
        // Prepare arguments
        let input = TestInput(number: 21)
        let inputData = try JSONEncoder().encode(input)
        
        // Execute the method
        let resultData = try await registry.execute(
            actorID: actorID,
            methodName: "doubleValue",
            arguments: [inputData]
        )
        
        // Decode and verify result
        let result = try JSONDecoder().decode(TestOutput.self, from: resultData)
        #expect(result.doubled == 42)
        
        // Clean up
        await registry.unregister(actorID: actorID)
    }
    
    @Test("Invocation Envelope")
    func testInvocationEnvelope() throws {
        let actorID = UUID()
        let arguments = [Data([1, 2, 3])]
        let argumentsData = try JSONEncoder().encode(arguments)

        let envelope = InvocationEnvelope(
            recipientID: actorID.uuidString,
            senderID: nil,
            target: "testMethod",
            arguments: argumentsData
        )

        #expect(envelope.recipientID == actorID.uuidString)
        #expect(envelope.target == "testMethod")
        #expect(envelope.metadata.version == "1.0")

        // Test serialization
        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(InvocationEnvelope.self, from: data)

        #expect(decoded.recipientID == actorID.uuidString)
        #expect(decoded.target == "testMethod")
        #expect(decoded.arguments == envelope.arguments)
    }
    
    @Test("Response Envelope")
    func testResponseEnvelope() throws {
        let id = UUID()
        let resultData = Data([4, 5, 6])
        let envelope = ResponseEnvelope(
            callID: id.uuidString,
            result: .success(resultData)
        )

        #expect(envelope.callID == id.uuidString)
        switch envelope.result {
        case .success(let data):
            #expect(data == resultData)
        default:
            Issue.record("Expected success result")
        }

        // Test error envelope
        let error = RuntimeError.methodNotFound("testMethod")
        let errorEnvelope = ResponseEnvelope(
            callID: id.uuidString,
            result: .failure(error)
        )

        switch errorEnvelope.result {
        case .failure(let err):
            #expect(err == error)
        default:
            Issue.record("Expected failure result")
        }
    }
    
    @Test("BLEActorSystem RPC Handling")
    func testBLEActorSystemRPC() async throws {
        // Use mock system - no TCC required
        let system = await BLEActorSystem.mock()
        let registry = MethodRegistry.shared

        struct TestData: Codable, Sendable {
            let message: String
        }

        // Register the actor in instance registry
        let instanceRegistry = InstanceRegistry.shared
        // Create a dummy distributed actor for testing
        distributed actor TestActor: PeripheralActor {
            typealias ActorSystem = BLEActorSystem

            distributed func testMethod() async -> String {
                return "Test"
            }
        }

        let testActor = TestActor(actorSystem: system)
        let actorID = testActor.id
        await instanceRegistry.registerLocal(testActor)
        
        // Register a method
        await registry.register(
            actorID: actorID,
            methodName: "getMessage",
            handler: { _ in
                let result = TestData(message: "RPC works!")
                return try JSONEncoder().encode(result)
            }
        )
        
        // Create invocation envelope
        let argumentsData = try JSONEncoder().encode([Data]())
        let envelope = InvocationEnvelope(
            recipientID: actorID.uuidString,
            senderID: nil,
            target: "getMessage",
            arguments: argumentsData
        )

        // Handle the RPC
        let response = await system.handleIncomingRPC(envelope)

        // Verify response
        #expect(response.callID == envelope.callID)

        switch response.result {
        case .success(let resultData):
            let result = try JSONDecoder().decode(TestData.self, from: resultData)
            #expect(result.message == "RPC works!")
        case .failure(let error):
            Issue.record("Expected success, got error: \(error)")
        case .void:
            Issue.record("Expected success with data, got void")
        }
        
        // Clean up
        await registry.unregister(actorID: actorID)
        await instanceRegistry.unregister(actorID)
    }
}