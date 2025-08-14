import Foundation
import Distributed

/// Type-erased method handler for distributed methods
public typealias MethodHandler = @Sendable (Data) async throws -> Data

/// Registry for distributed actor methods
public actor MethodRegistry {
    /// Method registration entry
    private struct MethodEntry {
        let actorID: UUID
        let methodName: String
        let handler: MethodHandler
        let isVoid: Bool
    }
    
    // Registry storage
    private var methods: [UUID: [String: MethodEntry]] = [:]
    
    /// Shared instance
    public static let shared = MethodRegistry()
    
    private init() {}
    
    /// Register a method handler
    public func register(
        actorID: UUID,
        methodName: String,
        handler: @escaping MethodHandler,
        isVoid: Bool = false
    ) {
        if methods[actorID] == nil {
            methods[actorID] = [:]
        }
        
        methods[actorID]?[methodName] = MethodEntry(
            actorID: actorID,
            methodName: methodName,
            handler: handler,
            isVoid: isVoid
        )
        
        BleuLogger.actorSystem.debug("Registered method '\(methodName)' for actor \(actorID)")
    }
    
    /// Execute a registered method
    public func execute(
        actorID: UUID,
        methodName: String,
        arguments: [Data]
    ) async throws -> Data {
        guard let actorMethods = methods[actorID],
              let entry = actorMethods[methodName] else {
            throw BleuError.methodNotSupported(methodName)
        }
        
        // For simplicity, we'll pass the first argument or empty data
        // In a full implementation, this would handle multiple arguments
        let argumentData = arguments.first ?? Data()
        
        do {
            let result = try await entry.handler(argumentData)
            
            if entry.isVoid {
                // For void methods, return empty VoidResult
                return try JSONEncoder().encode(VoidResult())
            } else {
                return result
            }
        } catch {
            BleuLogger.actorSystem.error("Method execution failed: \(error.localizedDescription)")
            throw error
        }
    }
    
    /// Check if a method is registered
    public func hasMethod(actorID: UUID, methodName: String) -> Bool {
        return methods[actorID]?[methodName] != nil
    }
    
    /// Unregister all methods for an actor
    public func unregister(actorID: UUID) {
        methods.removeValue(forKey: actorID)
        BleuLogger.actorSystem.debug("Unregistered all methods for actor \(actorID)")
    }
    
    /// Get all registered methods for an actor
    public func getMethods(for actorID: UUID) -> [String] {
        guard let actorMethods = methods[actorID] else { return [] }
        return Array(actorMethods.keys)
    }
}

// MARK: - Helper Types

/// Empty result for void methods
private struct VoidResult: Codable {}

// MARK: - PeripheralActor Method Registration

/// Extension to help actors register their methods
public extension PeripheralActor {
    /// Register distributed methods with the method registry
    /// This should be called in the actor's init method
    func registerMethods() async {
        // This is where actors will register their specific methods
        // Each actor implementation should override this to register its methods
        // Example:
        // let registry = MethodRegistry.shared
        // let actorID = self.id
        // await registry.register(
        //     actorID: actorID,
        //     methodName: "getTemperature",
        //     handler: { _ in
        //         let result = await self.getTemperature()
        //         return try JSONEncoder().encode(result)
        //     }
        // )
    }
}

// MARK: - Method Registration Helpers

/// Helper to create a method handler from a distributed function
public func createMethodHandler<T: Codable & Sendable>(
    for function: @escaping @Sendable () async throws -> T
) -> MethodHandler {
    return { _ in
        let result = try await function()
        return try JSONEncoder().encode(result)
    }
}

/// Helper to create a method handler for void functions
public func createVoidMethodHandler(
    for function: @escaping @Sendable () async throws -> Void
) -> MethodHandler {
    return { _ in
        try await function()
        return Data() // Empty data for void
    }
}

/// Helper to create a method handler with single argument
public func createMethodHandler<Arg: Codable & Sendable, Res: Codable & Sendable>(
    for function: @escaping @Sendable (Arg) async throws -> Res
) -> MethodHandler {
    return { data in
        let arg = try JSONDecoder().decode(Arg.self, from: data)
        let result = try await function(arg)
        return try JSONEncoder().encode(result)
    }
}

/// Helper to create a void method handler with single argument
public func createVoidMethodHandler<Arg: Codable & Sendable>(
    for function: @escaping @Sendable (Arg) async throws -> Void
) -> MethodHandler {
    return { data in
        let arg = try JSONDecoder().decode(Arg.self, from: data)
        try await function(arg)
        return Data() // Empty data for void
    }
}