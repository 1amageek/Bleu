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

        let envelope = InvocationEnvelope(
            recipientID: actorID.uuidString,
            senderID: nil,
            target: "testMethod",
            arguments: arguments
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

        // Actor is automatically registered in ActorRegistry via actorReady()
        // No manual registration needed

        // Test calling distributed methods
        let result1 = try await testActor.testMethod()
        #expect(result1 == "Test Result")

        let result2 = try await testActor.addNumbers(5, 3)
        #expect(result2 == 8)

        // Actor is automatically unregistered when it deinitializes
    }

    @Test("Same-process void RPC does not crash")
    func testSameProcessVoidRPC() async throws {
        // Regression test: a void-returning distributed method invoked through the
        // registry-backed same-process path used to trap on `() as! VoidResult`.
        let system = await BLEActorSystem.mock()

        distributed actor VoidActor: PeripheralActor {
            typealias ActorSystem = BLEActorSystem

            private var value: Int = 0

            distributed func setValue(_ newValue: Int) async {
                value = newValue
            }

            distributed func getValue() async -> Int {
                value
            }
        }

        let local = VoidActor(actorSystem: system)

        // Resolve a proxy with the same ID in the same system to force the
        // registry-backed same-process remoteCall path (not direct local dispatch).
        let proxy = try VoidActor.resolve(id: local.id, using: system)

        // Must not trap on the `.void` result branch.
        try await proxy.setValue(42)

        let stored = try await proxy.getValue()
        #expect(stored == 42)
    }
}
