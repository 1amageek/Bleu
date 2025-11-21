# Multi-Process Support for CoreBluetoothEmulator

## Status: ✅ FULLY IMPLEMENTED

**Phase 1 (Core Infrastructure)**: ✅ Complete
**Phase 2 (Transports)**: ✅ Complete
**Phase 3 (Event Routing)**: ✅ Complete

This proposal has been **fully implemented** in CoreBluetoothEmulator with complete event routing support.

### Implementation Components

**Core Infrastructure:**
- `EmulatorTransport` protocol for pluggable transports
- `EmulatorInternalEvent` Codable enum with all BLE operations (scan, connect, read, write, notify, etc.)
- `CodableValue` enum for type-safe advertisement data serialization
- `TransportMode` in `EmulatorBus` (.inProcess / .distributed)
- Event receiving loop with automatic deserialization
- Complete event routing and dispatch system

**Transport Implementations:**
- `InMemoryEmulatorTransport` with Hub-based routing for testing
- `XPCEmulatorTransport` for real cross-process communication (macOS/iOS)
- Process role support (hub, central, peripheral, both)
- Automatic client registration and cleanup

**Event Routing Integration:**
- `startScanning()` → sends `.scanStarted` event in distributed mode
- `connect()` → sends `.connectionRequested` event
- `writeValue()` → sends `.writeRequested` event
- `sendNotification()` → sends `.notificationSent` event
- Remote event handlers: `handleRemoteScanStarted`, `handleRemoteConnectionRequest`, `handleRemoteWrite`, `handleRemoteNotification`

**Testing:**
- All 32 CoreBluetoothEmulator tests passing
- 53/53 Bleu integration tests passing (including multi-process tests)
- Event serialization tests
- Transport hub routing tests
- End-to-end RPC flow verification

### Files Modified/Created

**CoreBluetoothEmulator:**
- `Sources/CoreBluetoothEmulator/Transport/EmulatorTransport.swift` (NEW)
- `Sources/CoreBluetoothEmulator/EmulatorInternalEvent.swift` (NEW)
- `Sources/CoreBluetoothEmulator/Transport/InMemoryEmulatorTransport.swift` (NEW)
- `Sources/CoreBluetoothEmulator/Transport/XPCEmulatorTransport.swift` (NEW)
- `Sources/CoreBluetoothEmulator/EmulatorBus.swift` (MODIFIED - added TransportMode, sendEvent, remote handlers)
- `Sources/CoreBluetoothEmulator/CoreBluetoothEmulator.swift` (MODIFIED - documentation)
- `README.md` (MODIFIED - added Multi-Process Support section)
- `CLAUDE.md` (MODIFIED - updated implementation status)

**Bleu:**
- `Tests/BleuTests/Integration/MultiProcessEmulatorTests.swift` (NEW)
- `Tests/BleuTests/Integration/MinimalEmulatorTest.swift` (MODIFIED - test stability fixes)
- `PROPOSAL_TO_COREBLUETOOTHEMULATOR.md` (MODIFIED - updated status)
- `Package.swift` (MODIFIED - local path dependency for development)

## Summary

Add inter-process communication capabilities to `EmulatorBus` to enable testing of distributed systems that communicate over BLE.

## Problem

CoreBluetoothEmulator currently only works within a single process because `EmulatorBus` is a process-singleton. This prevents testing of real-world BLE architectures where:

1. **Central and Peripheral run in separate processes** (different apps/devices)
2. **RPC frameworks over BLE** need to verify serialization end-to-end
3. **Distributed actor systems** require cross-process communication testing

### Current Limitation

```swift
// Test code - SAME process
let peripheral = EmulatedCBPeripheralManager(...)  // Process A
let central = EmulatedCBCentralManager(...)        // Process A
                                                   // ↑ Both in same process
// EmulatorBus.shared routes events in-memory
// Cannot test actual serialization/deserialization
```

### Real-World Use Case

**Bleu Framework**: Distributed actors over BLE using Swift's `DistributedActorSystem`

```swift
// What we need to test
Process A (iPhone):
  distributed actor TemperatureSensor { ... }

Process B (Apple Watch):
  let sensor = try await TemperatureSensor.resolve(...)
  let temp = try await sensor.readTemperature()  // ← RPC over BLE

// This requires:
// 1. Method call → InvocationEnvelope (serialize)
// 2. Send via BLE characteristic write
// 3. Receive and deserialize
// 4. Execute on actual actor
// 5. Serialize result → ResponseEnvelope
// 6. Send back via BLE notification
// 7. Deserialize and return
```

**Current state**: We can only test if both actors are in the same process, which defeats the purpose.

## Proposed Solution

### 1. Make Events Serializable

```swift
// Add to CoreBluetoothEmulator
public enum EmulatorEvent: Codable, Sendable {
    case peripheralAdvertising(PeripheralAdvertisement)
    case centralConnecting(UUID, UUID)
    case characteristicWritten(UUID, UUID, Data)
    // ... all existing events
}

public struct PeripheralAdvertisement: Codable, Sendable {
    let peripheralID: UUID
    let advertisementData: [String: CodableValue]
    let rssi: Int
}
```

### 2. Add Transport Layer

```swift
// Add to EmulatorBus
public actor EmulatorBus {

    public enum TransportMode {
        case inProcess           // Current behavior (default)
        case distributed(any EmulatorTransport)  // New capability
    }

    private var transport: TransportMode = .inProcess

    public func configure(transport: TransportMode) {
        self.transport = transport
    }

    internal func route(_ event: EmulatorEvent, to targetID: UUID) async throws {
        switch transport {
        case .inProcess:
            // Current implementation - direct delivery
            deliverLocally(event, to: targetID)

        case .distributed(let transport):
            // New - serialize and send via transport
            let data = try JSONEncoder().encode(event)
            try await transport.send(data, to: targetID)
        }
    }
}

// Protocol for transport implementations
public protocol EmulatorTransport: Sendable {
    func send(_ data: Data, to targetID: UUID) async throws
    func receive() -> AsyncStream<(UUID, Data)>
}
```

### 3. Reference Implementation (XPC)

```swift
// Example: XPC-based transport (for macOS/iOS)
public actor XPCEmulatorTransport: EmulatorTransport {

    private let connection: NSXPCConnection

    public func send(_ data: Data, to targetID: UUID) async throws {
        let proxy = connection.remoteObjectProxy as! EmulatorXPCProtocol
        try await proxy.deliverEvent(data, to: targetID)
    }

    public func receive() -> AsyncStream<(UUID, Data)> {
        // Return stream of incoming events from other processes
    }
}
```

## Benefits

### For Framework Authors

- **Test real distributed systems** without hardware
- **Verify serialization** end-to-end
- **Faster CI/CD** - no need for physical devices
- **Edge case testing** - simulate packet loss, delays, etc.

### For CoreBluetoothEmulator

- **Minimal API changes** - backward compatible
- **Opt-in feature** - existing tests continue to work
- **Plugin architecture** - users provide their own transport
- **Broader adoption** - enables new use cases

## Implementation Scope

### Phase 1: Core (Minimal)

1. Make internal event types `Codable`
2. Add `TransportMode` enum to `EmulatorBus`
3. Add `EmulatorTransport` protocol
4. Update event routing to support transport

**Estimated effort**: 2-3 days

### Phase 2: Reference Implementation (Optional)

1. Implement `XPCEmulatorTransport` for macOS/iOS
2. Add example multi-process test
3. Documentation

**Estimated effort**: 1-2 weeks

## Example Usage

```swift
// Test in Process A (Peripheral)
let transport = XPCEmulatorTransport(role: .peripheral)
await EmulatorBus.shared.configure(transport: .distributed(transport))

let peripheral = EmulatedCBPeripheralManager(...)
// Acts as peripheral, events routed via XPC

// Test in Process B (Central)
let transport = XPCEmulatorTransport(role: .central)
await EmulatorBus.shared.configure(transport: .distributed(transport))

let central = EmulatedCBCentralManager(...)
// Acts as central, communicates with peripheral in Process A

// Now we can test REAL distributed communication!
```

## Backward Compatibility

**100% backward compatible**

- Default behavior unchanged (`.inProcess`)
- Existing tests continue to work
- Opt-in for multi-process testing

## Alternative Approaches Considered

### 1. Keep single-process only
- ❌ Cannot test distributed systems
- ❌ Limited value for modern BLE frameworks

### 2. Fork CoreBluetoothEmulator
- ❌ Fragments ecosystem
- ❌ Maintenance burden

### 3. Build separate framework
- ❌ Duplicates existing work
- ❌ Users need two emulators

### 4. This proposal (Extend CoreBluetoothEmulator)
- ✅ Minimal changes
- ✅ Backward compatible
- ✅ Benefits entire community
- ✅ Unlocks new use cases

## Request

We would like to contribute this feature to CoreBluetoothEmulator. The changes are minimal, backward-compatible, and enable testing of distributed BLE systems.

**Would you be interested in a pull request implementing Phase 1?**

We can provide:
- Implementation
- Tests
- Documentation
- Example XPC transport (optional)

## Contact

This proposal is from the [Bleu](https://github.com/1amageek/Bleu) project - a distributed actor framework over BLE.

We're happy to discuss the design and implementation approach.

---

## Appendix: Technical Details

### Event Serialization Format

Events are encoded as JSON for human readability and debugging:

```json
{
  "type": "characteristicWritten",
  "peripheralID": "550e8400-e29b-41d4-a716-446655440000",
  "characteristicID": "550e8400-e29b-41d4-a716-446655440001",
  "value": "eyJjYWxsSUQiOiI...",
  "timestamp": 1704067200.0
}
```

### Transport Protocol

The `EmulatorTransport` protocol is intentionally minimal:

```swift
public protocol EmulatorTransport: Sendable {
    // Send event to specific target
    func send(_ data: Data, to targetID: UUID) async throws

    // Receive events from any source
    func receive() -> AsyncStream<(sourceID: UUID, data: Data)>
}
```

This allows multiple implementations:
- XPC (macOS/iOS production)
- Unix sockets (cross-platform)
- Distributed actors (self-hosted)
- File-based (simple testing)

### API Surface Changes

**Added**:
- `EmulatorBus.configure(transport:)` - opt-in transport
- `EmulatorTransport` protocol - for custom transports
- `EmulatorEvent` enum - codable events

**Unchanged**:
- All `EmulatedCB*` class APIs
- Default behavior (single-process)
- Test helper functions

**Breaking changes**: None
