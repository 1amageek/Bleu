# Distributed Method Execution Architecture

## Overview

This document describes how Bleu executes distributed actor methods over BLE connections. It addresses the fundamental challenge that **Swift does not provide public APIs to execute distributed actor methods by name**.

## The Problem

When a central connects to a peripheral and calls a distributed method:

```swift
// Central side
let sensor = try await system.connect(to: peripheralID, as: SensorActor.self)
let temp = try await sensor.readTemperature()  // RPC call
```

The peripheral receives an `InvocationEnvelope` containing:
- `actorID`: UUID of the target actor
- `methodName`: Mangled Swift method name (e.g., `"$s9Bleu11SensorActorC15readTemperatureSdyYaKFTE"`)
- `arguments`: Serialized method arguments

The system must:
1. Find the actor instance by ID
2. Execute the method by name
3. Return the serialized result

**Swift's limitation**: The `executeDistributedTarget` API exists but delegates to internal runtime APIs that are not publicly accessible.

## Solution Architecture

Bleu uses a **dual-registry approach** inspired by actor-edge:

### 1. ActorRegistry - Instance Tracking

Maps actor IDs to actor instances for invocation routing.

```
┌─────────────────────────────────────┐
│        ActorRegistry                │
├─────────────────────────────────────┤
│  actors: [UUID: DistributedActor]   │
│  mutex: Mutex<State>                │
├─────────────────────────────────────┤
│  + register(actor, id)              │
│  + find(id) -> Actor?               │
│  + unregister(id)                   │
└─────────────────────────────────────┘
```

**Key Design Decisions**:
- **`final class` not `actor`**: Must be synchronously accessible from `BLEActorSystem`
- **`Mutex<State>` not `NSLock`**: Provides Sendable safety without `@unchecked`
- **Thread-safe**: Multiple systems may access concurrently

### 2. MethodRegistry - Method Execution

Maps mangled method names to executable closures.

```
┌──────────────────────────────────────────────────┐
│           MethodRegistry                         │
├──────────────────────────────────────────────────┤
│  methods: [String: MethodHandler]                │
│  mutex: Mutex<State>                             │
├──────────────────────────────────────────────────┤
│  + register(methodName, handler)                 │
│  + execute(methodName, args) -> Result          │
│  + unregister(methodName)                        │
└──────────────────────────────────────────────────┘

MethodHandler = @Sendable (Data) async throws -> Data
```

**Key Design Decisions**:
- **Closure-based execution**: Bypasses Swift's reflection limitations
- **Type erasure**: All arguments/results as `Data` (Codable)
- **Actor-specific**: Each actor registers its own methods
- **Automatic registration**: Via `PeripheralActor` protocol requirement

## Data Flow

### Peripheral Side (Method Registration)

```swift
distributed actor SensorActor: PeripheralActor {
    typealias ActorSystem = BLEActorSystem

    distributed func readTemperature() async -> Double {
        return 22.5
    }

    // PeripheralActor protocol requirement
    func registerMethods(with registry: MethodRegistry) async {
        // Register each distributed method
        await registry.register("readTemperature") { [weak self] argsData in
            guard let self = self else {
                throw BleuError.actorDeallocated
            }

            // Decode arguments (none in this case)
            // Execute method
            let result = try await self.readTemperature()

            // Encode result
            return try JSONEncoder().encode(result)
        }
    }
}
```

### Central Side (Method Invocation)

```swift
// 1. Central sends InvocationEnvelope via BLE write
let envelope = InvocationEnvelope(
    id: UUID(),
    actorID: sensorActorID,
    methodName: "readTemperature",
    arguments: Data()  // Empty for no args
)

// 2. Peripheral receives via EventBridge.handleWriteRequest()
//    - BLETransport unpacks fragmented data
//    - Decodes InvocationEnvelope
//    - Routes to BLEActorSystem.handleRPCRequest()

// 3. BLEActorSystem.handleRPCRequest()
let actor = actorRegistry.find(id: envelope.actorID)
let methodRegistry = actorMethodRegistries[envelope.actorID]
let resultData = try await methodRegistry.execute(
    envelope.methodName,
    arguments: envelope.arguments
)

// 4. Send ResponseEnvelope back via BLE notification
let response = ResponseEnvelope(
    id: envelope.id,
    result: .success(resultData)
)
```

## Component Responsibilities

### ActorRegistry

**Purpose**: Track which actor instances exist in this system

**Lifecycle**:
- `register()`: Called in `BLEActorSystem.startAdvertising()` for peripherals
- `find()`: Called in `BLEActorSystem.handleRPCRequest()` to route invocations
- `unregister()`: Called when actor is deallocated or connection lost

**Thread Safety**: Mutex-protected state, safe for concurrent access from multiple BLE connections

### MethodRegistry

**Purpose**: Execute methods by mangled name without Swift runtime access

**Lifecycle**:
- Created per-actor when peripheral starts advertising
- `register()`: Called by actor's `registerMethods()` during setup
- `execute()`: Called for each incoming RPC invocation
- Destroyed when actor unregisters

**Thread Safety**: Mutex-protected method map

### BLEActorSystem Integration

```swift
public final class BLEActorSystem: DistributedActorSystem {
    // Actor instance tracking
    private let actorRegistry = ActorRegistry()

    // Method execution tracking (one registry per actor)
    private let actorMethodRegistries: Mutex<[UUID: MethodRegistry]>

    // Called when peripheral starts advertising
    public func startAdvertising<T: PeripheralActor>(_ peripheral: T) async throws {
        // 1. Register actor instance
        actorRegistry.register(peripheral, id: peripheral.id)

        // 2. Create method registry for this actor
        let methodRegistry = MethodRegistry()
        actorMethodRegistries.withLock { $0[peripheral.id] = methodRegistry }

        // 3. Let actor register its methods
        await peripheral.registerMethods(with: methodRegistry)

        // 4. Set up BLE service/characteristics
        let metadata = ServiceMapper.createServiceMetadata(from: T.self)
        try await peripheralManager.add(metadata)
        try await peripheralManager.startAdvertising()
    }

    // Called when RPC request arrives
    func handleRPCRequest(_ envelope: InvocationEnvelope) async -> ResponseEnvelope {
        do {
            // 1. Find actor instance
            guard let actor = actorRegistry.find(id: envelope.actorID) else {
                throw BleuError.actorNotFound(envelope.actorID)
            }

            // 2. Find method registry
            guard let methodRegistry = actorMethodRegistries.withLock({ $0[envelope.actorID] }) else {
                throw BleuError.methodRegistryNotFound(envelope.actorID)
            }

            // 3. Execute method
            let resultData = try await methodRegistry.execute(
                envelope.methodName,
                arguments: envelope.arguments
            )

            // 4. Return success response
            return ResponseEnvelope(
                id: envelope.id,
                result: .success(resultData)
            )
        } catch {
            // Return error response
            return ResponseEnvelope(
                id: envelope.id,
                result: .failure(error)
            )
        }
    }
}
```

## Type Safety Considerations

### Compile-Time Safety

❌ **Lost**: No compile-time verification that registered methods match distributed declarations

```swift
// Compiler cannot verify this matches the actual signature
await registry.register("readTemprature") { ... }  // Typo!
```

### Runtime Safety

✅ **Preserved**:
- Codable type checking during encode/decode
- Actor isolation via `[weak self]` captures
- Error propagation via throws

### Mitigation Strategies

1. **Protocol Requirement**: Force implementation via `PeripheralActor`
2. **Testing**: Integration tests verify all methods work end-to-end
3. **Future**: Code generation macro (like actor-edge's `@Resolvable`)

## Comparison with Actor-Edge

| Aspect | Actor-Edge | Bleu |
|--------|------------|------|
| **Approach** | Protocol + Macro code generation | Manual method registration |
| **Type Safety** | Full compile-time safety | Runtime only |
| **Boilerplate** | None (generated) | `registerMethods()` required |
| **Flexibility** | Protocol-based RPC | Direct actor instances |
| **Transport** | gRPC, pluggable | BLE (CoreBluetooth) |
| **Use Case** | General distributed systems | BLE-specific IoT |

## Future Improvements

### Phase 1: Manual Registration (Current)
```swift
func registerMethods(with registry: MethodRegistry) async {
    await registry.register("readTemperature") { ... }
}
```

### Phase 2: Macro-Based Generation (Future)
```swift
@BLEPeripheral
distributed actor SensorActor {
    distributed func readTemperature() async -> Double
}
// Macro generates registerMethods() automatically
```

### Phase 3: Swift Runtime API (When Available)
```swift
// If Swift ever exposes distributed actor introspection
public func executeDistributedTarget(...) async throws -> Res {
    return try await SwiftRuntime.executeMethod(
        on: actor,
        named: target.identifier,
        with: decoder
    )
}
```

## Error Handling

### New Error Cases

```swift
public enum BleuError: Error {
    // Existing errors...

    // Actor execution errors
    case actorNotFound(UUID)
    case actorDeallocated
    case methodRegistryNotFound(UUID)
    case methodNotRegistered(String)
    case methodExecutionFailed(String, Error)
}
```

### Error Flow

```
Central Call → Peripheral Receives → Error Occurs
                                           ↓
                                   ResponseEnvelope.failure
                                           ↓
                                   BLE Notification
                                           ↓
                                   Central throws error
```

## Performance Considerations

### Registry Lookups

- **ActorRegistry**: O(1) dictionary lookup with mutex lock
- **MethodRegistry**: O(1) dictionary lookup with mutex lock
- **Overhead**: ~1-2μs for mutex lock/unlock (negligible vs BLE latency)

### Memory

- Each actor: 1 ActorRegistry entry + 1 MethodRegistry instance
- Each method: 1 closure in MethodRegistry (~100 bytes)
- Typical peripheral: 1 actor × 5 methods = ~500 bytes overhead

### BLE Latency Comparison

- Mutex overhead: ~1-2μs
- BLE characteristic write: ~10-50ms
- BLE notification: ~10-50ms
- **Ratio**: Mutex is <0.01% of total RPC time

## Thread Safety Model

### Mutex vs NSLock vs Actor

```swift
// ❌ NSLock - requires @unchecked Sendable
final class Registry: @unchecked Sendable {
    private let lock = NSLock()
}

// ❌ Actor - forces async access
actor Registry {
    // Cannot use synchronously in BLEActorSystem
}

// ✅ Mutex - Sendable + synchronous
final class Registry: Sendable {
    private let mutex = Mutex<State>()

    func find(id: UUID) -> Actor? {
        mutex.withLock { $0.actors[id] }
    }
}
```

### Mutex Implementation

```swift
import Synchronization

final class ActorRegistry: Sendable {
    private struct State {
        var actors: [UUID: any DistributedActor] = [:]
    }

    private let mutex = Mutex(State())

    func register(_ actor: any DistributedActor, id: UUID) {
        mutex.withLock { state in
            state.actors[id] = actor
        }
    }

    func find(id: UUID) -> (any DistributedActor)? {
        mutex.withLock { state in
            state.actors[id]
        }
    }
}
```

## Implementation Checklist

- [ ] Create `ActorRegistry` with Mutex
- [ ] Create `MethodRegistry` with Mutex
- [ ] Add `registerMethods()` requirement to `PeripheralActor`
- [ ] Update `BLEActorSystem.startAdvertising()` to register actors/methods
- [ ] Implement `BLEActorSystem.handleRPCRequest()` using registries
- [ ] Wire `EventBridge.handleWriteRequest()` to call `handleRPCRequest()`
- [ ] Add new error cases to `BleuError`
- [ ] Update test actors to implement `registerMethods()`
- [ ] Add integration tests for method execution
- [ ] Document usage in README

## References

- [actor-edge](https://github.com/1amageek/actor-edge) - Protocol-based distributed actors with macro generation
- [Swift Distributed Actors](https://github.com/apple/swift-evolution/blob/main/proposals/0336-distributed-actor-isolation.md) - SE-0336
- [Swift Synchronization](https://github.com/apple/swift-evolution/blob/main/proposals/0433-mutex.md) - SE-0433 Mutex
