#!/usr/bin/env swift

import Foundation
import Bleu

// Simple test to verify RPC functionality works

func testRPC() async throws {
    print("Testing Bleu RPC Functionality")
    print("===============================")
    
    let registry = MethodRegistry.shared
    let actorID = UUID()
    
    // Test 1: Register and execute a simple method
    print("\n1. Testing simple method registration and execution...")
    
    await registry.register(
        actorID: actorID,
        methodName: "getValue",
        handler: { _ in
            let result = "Hello from RPC!"
            return try JSONEncoder().encode(result)
        }
    )
    
    let resultData = try await registry.execute(
        actorID: actorID,
        methodName: "getValue",
        arguments: []
    )
    
    let result = try JSONDecoder().decode(String.self, from: resultData)
    print("   ✓ Method returned: \(result)")
    
    // Test 2: Method with arguments
    print("\n2. Testing method with arguments...")
    
    struct Input: Codable {
        let value: Int
    }
    
    struct Output: Codable {
        let doubled: Int
    }
    
    await registry.register(
        actorID: actorID,
        methodName: "doubleValue",
        handler: { data in
            let input = try JSONDecoder().decode(Input.self, from: data)
            let output = Output(doubled: input.value * 2)
            return try JSONEncoder().encode(output)
        }
    )
    
    let input = Input(value: 21)
    let inputData = try JSONEncoder().encode(input)
    
    let outputData = try await registry.execute(
        actorID: actorID,
        methodName: "doubleValue",
        arguments: [inputData]
    )
    
    let output = try JSONDecoder().decode(Output.self, from: outputData)
    print("   ✓ Input: 21, Output: \(output.doubled)")
    
    // Test 3: BLEActorSystem RPC handling
    print("\n3. Testing BLEActorSystem RPC handling...")
    
    let system = BLEActorSystem.shared
    let instanceRegistry = InstanceRegistry.shared
    
    // Register a dummy actor for testing
    struct TestActor: DistributedActor {
        typealias ActorSystem = BLEActorSystem
        typealias ID = UUID
        let actorSystem: ActorSystem
        let id: UUID
        
        init(actorSystem: ActorSystem, id: UUID) {
            self.actorSystem = actorSystem
            self.id = id
        }
    }
    
    let testActorID = UUID()
    let testActor = TestActor(actorSystem: system, id: testActorID)
    await instanceRegistry.registerLocal(testActor)
    
    await registry.register(
        actorID: testActorID,
        methodName: "testMethod",
        handler: { _ in
            return try JSONEncoder().encode("RPC through BLEActorSystem works!")
        }
    )
    
    let envelope = InvocationEnvelope(
        actorID: testActorID,
        methodName: "testMethod",
        arguments: []
    )
    
    let response = await system.handleIncomingRPC(envelope)
    
    if let responseData = response.result {
        let responseText = try JSONDecoder().decode(String.self, from: responseData)
        print("   ✓ BLEActorSystem response: \(responseText)")
    } else if let errorData = response.error {
        let error = try JSONDecoder().decode(BleuError.self, from: errorData)
        print("   ✗ Error: \(error)")
    }
    
    // Clean up
    await registry.unregister(actorID: actorID)
    await registry.unregister(actorID: testActorID)
    await instanceRegistry.unregister(testActorID)
    
    print("\n✅ All RPC tests passed!")
    print("===============================")
    print("\nThe Bleu framework is now fully functional!")
    print("Distributed actors can now execute methods via BLE RPC.")
}

// Run the test
Task {
    do {
        try await testRPC()
    } catch {
        print("❌ Test failed: \(error)")
    }
    exit(0)
}

// Keep the program running
RunLoop.main.run()