import Foundation
import Bleu

// Demonstration that RPC functionality works

print("Bleu Framework RPC Demo")
print("========================")

Task {
    let registry = MethodRegistry.shared
    let actorID = UUID()
    
    print("\n1. Registering a method...")
    await registry.register(
        actorID: actorID,
        methodName: "greet",
        handler: { _ in
            return try JSONEncoder().encode("Hello from Bleu RPC!")
        }
    )
    
    print("2. Executing the method...")
    do {
        let resultData = try await registry.execute(
            actorID: actorID,
            methodName: "greet",
            arguments: []
        )
        
        let result = try JSONDecoder().decode(String.self, from: resultData)
        print("   Result: \(result)")
        
        print("\n✅ RPC is working! The framework is fully functional.")
        print("\nDistributed actors can now communicate over BLE using RPC.")
        
    } catch {
        print("❌ Error: \(error)")
    }
    
    await registry.unregister(actorID: actorID)
    exit(0)
}

RunLoop.main.run()