import Testing
import Foundation
import Distributed
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
        let envelope = InvocationEnvelope(
            actorID: actorID,
            methodName: "testMethod",
            arguments: [Data([1, 2, 3])]
        )
        
        #expect(envelope.actorID == actorID)
        #expect(envelope.methodName == "testMethod")
        #expect(envelope.arguments.count == 1)
        #expect(envelope.version == "1.0")
        
        // Test serialization
        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(InvocationEnvelope.self, from: data)
        
        #expect(decoded.actorID == actorID)
        #expect(decoded.methodName == "testMethod")
        #expect(decoded.arguments == envelope.arguments)
    }
    
    @Test("Response Envelope")
    func testResponseEnvelope() throws {
        let id = UUID()
        let resultData = Data([4, 5, 6])
        let envelope = ResponseEnvelope(
            id: id,
            result: resultData
        )
        
        #expect(envelope.id == id)
        #expect(envelope.result == resultData)
        #expect(envelope.error == nil)
        #expect(envelope.version == "1.0")
        
        // Test error envelope
        let errorData = Data([7, 8, 9])
        let errorEnvelope = ResponseEnvelope(
            id: id,
            error: errorData
        )
        
        #expect(errorEnvelope.result == nil)
        #expect(errorEnvelope.error == errorData)
    }
    
    @Test("BLEActorSystem RPC Handling")
    func testBLEActorSystemRPC() async throws {
        let system = BLEActorSystem.shared
        let registry = MethodRegistry.shared
        
        struct TestData: Codable, Sendable {
            let message: String
        }
        
        // Register the actor in instance registry
        let instanceRegistry = InstanceRegistry.shared
        // Create a dummy distributed actor for testing
        distributed actor TestActor {
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
        let envelope = InvocationEnvelope(
            actorID: actorID,
            methodName: "getMessage",
            arguments: []
        )
        
        // Handle the RPC
        let response = await system.handleIncomingRPC(envelope)
        
        // Verify response
        #expect(response.id == envelope.id)
        #expect(response.error == nil)
        #expect(response.result != nil)
        
        if let resultData = response.result {
            let result = try JSONDecoder().decode(TestData.self, from: resultData)
            #expect(result.message == "RPC works!")
        }
        
        // Clean up
        await registry.unregister(actorID: actorID)
        await instanceRegistry.unregister(actorID)
    }
}