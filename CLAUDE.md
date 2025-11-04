# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Bleu 2 is a Swift framework for Bluetooth Low Energy (BLE) communication that leverages Swift's Distributed Actor system. It uses [swift-actor-runtime](https://github.com/1amageek/swift-actor-runtime) for transport-agnostic RPC infrastructure.

**Core Philosophy**: "Make BLE communication as simple as calling a function"

## Understanding swift-actor-runtime

### What swift-actor-runtime Provides

`swift-actor-runtime` is a **shared library** that provides:

1. **Envelope Types** (`InvocationEnvelope`, `ResponseEnvelope`)
   - Codable RPC message structures
   - Transport-agnostic (can be sent over BLE, gRPC, HTTP, etc.)

2. **Codec System**
   - `CodableInvocationEncoder`: Encodes method calls
   - `CodableInvocationDecoder`: Decodes method calls
   - `CodableResultHandler`: Handles results

3. **Actor Registry** (`ActorRegistry`)
   - Maps actor IDs to actor instances
   - Thread-safe with `Synchronization.Mutex`

4. **Error Types** (`RuntimeError`)
   - Standardized Codable errors

### What swift-actor-runtime Does NOT Provide

- Network/transport layer
- Connection management
- Message delivery
- Timeout handling

**Your transport implementation (Bleu) handles these.**

## Correct Architecture

### Two Deployment Modes

#### 1. Same-Process Mode (for testing/mocking)

When peripheral and central are in the **same process**:

```swift
// NO envelopes, NO transport, NO serialization
distributed actor TemperatureSensor {
    typealias ActorSystem = BLEActorSystem
    distributed func readTemperature() -> Double { 22.5 }
}

// In remoteCall():
func remoteCall(...) async throws -> Res {
    // 1. Find actor in registry (same process!)
    guard let targetActor = registry.find(id: actor.id) else {
        throw BleuError.actorNotFound(actor.id)
    }

    // 2. Execute directly with Swift runtime
    var encoder = invocation
    encoder.recordTarget(target)
    let envelope = try encoder.makeInvocationEnvelope(recipientID: actor.id)
    var decoder = try CodableInvocationDecoder(envelope: envelope)

    var capturedResult: Result<Res, Error>?
    let handler = CodableResultHandler(callID: envelope.callID) { response in
        switch response.result {
        case .success(let data):
            capturedResult = .success(try JSONDecoder().decode(Res.self, from: data))
        case .void:
            capturedResult = .success(() as! Res)
        case .failure(let error):
            capturedResult = .failure(error)
        }
    }

    // 3. Direct execution (no network!)
    try await executeDistributedTarget(
        on: targetActor,
        target: target,
        invocationDecoder: &decoder,
        handler: handler
    )

    return try capturedResult!.get()
}
```

**Key point**: InMemoryActorSystem in swift-actor-runtime does this exactly (see Tests/ActorRuntimeTests/InMemoryTransportTests.swift:38-78)

#### 2. Cross-Process Mode (real BLE)

When peripheral and central are in **different processes** (different devices):

```swift
// Central side
func remoteCall(...) async throws -> Res {
    // 1. Create invocation envelope
    var encoder = invocation
    encoder.recordTarget(target)
    let envelope = try encoder.makeInvocationEnvelope(
        recipientID: actor.id.uuidString,
        senderID: nil
    )

    // 2. Serialize and send via BLE
    let data = try JSONEncoder().encode(envelope)
    try await bleTransport.send(data, to: actor.id)

    // 3. Wait for response with timeout
    return try await withThrowingTaskGroup { group in
        group.addTask {
            try await withCheckedThrowingContinuation { continuation in
                self.pendingCalls[envelope.callID] = continuation
            }
        }
        group.addTask {
            try await Task.sleep(nanoseconds: 10_000_000_000)
            throw BleuError.connectionTimeout
        }
        let response = try await group.next()!
        group.cancelAll()
        return response
    }
}

// Peripheral side - receive loop
Task {
    for await data in bleTransport.incomingData {
        let envelope = try JSONDecoder().decode(InvocationEnvelope.self, from: data)

        // Find actor and execute
        guard let actor = registry.find(id: envelope.recipientID) else {
            let error = ResponseEnvelope(
                callID: envelope.callID,
                result: .failure(.actorNotFound(envelope.recipientID))
            )
            try await bleTransport.sendResponse(error)
            continue
        }

        var decoder = try CodableInvocationDecoder(envelope: envelope)
        let handler = CodableResultHandler(callID: envelope.callID) { response in
            // Send response back over BLE
            try await bleTransport.sendResponse(response)
        }

        try await executeDistributedTarget(
            on: actor,
            target: RemoteCallTarget(envelope.target),
            invocationDecoder: &decoder,
            handler: handler
        )
    }
}
```

### Current Problems in Bleu

1. **EventBridge is overengineered**
   - Tries to handle both same-process events AND cross-process RPC
   - Should be split into two separate concerns

2. **MockBLEBridge is too complex**
   - Uses async routing between mock managers
   - Should use direct in-memory calls (like InMemoryActorSystem)

3. **Missing clear separation**
   - Need to detect: "Is this actor in the same process?"
   - If yes: use direct `executeDistributedTarget`
   - If no: use BLE transport

## Recommended Implementation

### Simple Mock Mode

```swift
public actor BLEActorSystem: DistributedActorSystem {
    private let registry = ActorRegistry()
    private let mode: Mode

    enum Mode {
        case mock  // Same process - direct calls
        case real  // Different process - BLE transport
    }

    public func remoteCall<Act, Err, Res>(...) async throws -> Res {
        switch mode {
        case .mock:
            // Same process - direct execution (like InMemoryActorSystem)
            return try await executeDirect(on: actor, target: target, ...)

        case .real:
            // Different process - use BLE transport
            return try await executeViaBLE(on: actor, target: target, ...)
        }
    }

    private func executeDirect(...) async throws -> Res {
        // Exactly like InMemoryActorSystem:38-78
        guard let targetActor = registry.find(id: actor.id) else {
            throw BleuError.actorNotFound(actor.id)
        }

        var encoder = invocation
        encoder.recordTarget(target)
        let envelope = try encoder.makeInvocationEnvelope(recipientID: actor.id.uuidString)
        var decoder = try CodableInvocationDecoder(envelope: envelope)

        var capturedResult: Result<Res, Error>?
        let handler = CodableResultHandler(callID: envelope.callID) { response in
            // Handle response immediately (in-memory)
            switch response.result {
            case .success(let data):
                capturedResult = .success(try JSONDecoder().decode(Res.self, from: data))
            case .void:
                capturedResult = .success(() as! Res)
            case .failure(let error):
                capturedResult = .failure(error)
            }
        }

        try await executeDistributedTarget(
            on: targetActor,
            target: target,
            invocationDecoder: &decoder,
            handler: handler
        )

        return try capturedResult!.get()
    }

    private func executeViaBLE(...) async throws -> Res {
        // Real BLE transport with timeouts
        var encoder = invocation
        encoder.recordTarget(target)
        let envelope = try encoder.makeInvocationEnvelope(
            recipientID: actor.id.uuidString,
            senderID: nil
        )

        let data = try JSONEncoder().encode(envelope)

        return try await withThrowingTaskGroup { group in
            group.addTask { [weak self] in
                try await withCheckedThrowingContinuation { continuation in
                    self?.pendingCalls[envelope.callID] = continuation
                    try await self?.bleTransport.send(data, to: actor.id)
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 10_000_000_000)
                throw BleuError.connectionTimeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }
}
```

### For Tests

```swift
// Same process - both actors in same BLEActorSystem
let system = await BLEActorSystem.mock()

let sensor = TemperatureSensor(actorSystem: system)
let proxy = try TemperatureSensor.resolve(id: sensor.id, using: system)

// Direct in-memory call - no BLE, no delays
let temp = try await proxy.readTemperature()  // Instant!
```

## Key Takeaways

1. **swift-actor-runtime provides data structures, not transport**
   - Use its Envelope types for serialization
   - Use its Codec types for encoding/decoding
   - Use its ActorRegistry for actor lookup
   - **Don't** expect it to handle networking

2. **Mock mode should be instant**
   - No async delays
   - No MockBLEBridge routing
   - Direct `executeDistributedTarget` calls
   - Just like InMemoryActorSystem in swift-actor-runtime

3. **Real mode uses BLE transport**
   - Serialize InvocationEnvelope to Data
   - Send via CoreBluetooth
   - Wait for ResponseEnvelope
   - Handle timeouts properly

4. **EventBridge should be removed or simplified**
   - Current design mixes local events with RPC management
   - BLEActorSystem should manage RPC directly
   - BLE events (connection, discovery) are separate from RPC

## Reference Implementation

See `swift-actor-runtime/Tests/ActorRuntimeTests/InMemoryTransportTests.swift` for the correct pattern of same-process distributed actor calls.
