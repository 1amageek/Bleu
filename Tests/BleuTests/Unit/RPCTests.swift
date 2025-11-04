import Testing
import Foundation
import Distributed
import ActorRuntime
@testable import Bleu

/// Test suite for RPC functionality
@Suite("RPC Tests")
struct RPCTests {
    
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
    
    @Test("BLEActorSystem Distributed Actor Method Calls")
    func testBLEActorSystemRPC() async throws {
        // Use mock system - no TCC required
        let system = await BLEActorSystem.mock()

        // Register the actor in instance registry
        let instanceRegistry = InstanceRegistry.shared

        // Create a dummy distributed actor for testing
        distributed actor TestActor: PeripheralActor {
            typealias ActorSystem = BLEActorSystem

            distributed func testMethod() async -> String {
                return "Test Result"
            }

            distributed func addNumbers(_ a: Int, _ b: Int) async -> Int {
                return a + b
            }
        }

        let testActor = TestActor(actorSystem: system)
        let actorID = testActor.id
        await instanceRegistry.registerLocal(testActor)

        // Test calling distributed methods
        let result1 = try await testActor.testMethod()
        #expect(result1 == "Test Result")

        let result2 = try await testActor.addNumbers(5, 3)
        #expect(result2 == 8)

        // Clean up
        await instanceRegistry.unregister(actorID)
    }
}