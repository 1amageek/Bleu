# Bleu 2 Architecture

**Version**: 2.0
**Date**: 2025-01-04
**Status**: Design Document

## Executive Summary

Bleu 2 is a Swift framework that enables distributed actor communication over Bluetooth Low Energy (BLE). It leverages [swift-actor-runtime](https://github.com/1amageek/swift-actor-runtime) for RPC infrastructure and focuses exclusively on BLE transport implementation.

**Core Philosophy**: "Make BLE communication as simple as calling a function"

## 1. Architectural Principles

### 1.1 Separation of Concerns

```
┌─────────────────────────────────────────────────────┐
│  swift-actor-runtime (Shared Library)               │
│  - InvocationEnvelope / ResponseEnvelope            │
│  - Codec System (Encoder/Decoder/ResultHandler)     │
│  - ActorRegistry (actor instance management)        │
│  - RuntimeError (standardized errors)               │
└─────────────────────────────────────────────────────┘
                        ▲
                        │ Uses
                        │
┌─────────────────────────────────────────────────────┐
│  Bleu (BLE Transport Implementation)                │
│  - BLEActorSystem (transport integration)           │
│  - CoreBluetooth wrappers (BLE I/O)                 │
│  - BLETransport (fragmentation/reassembly)          │
│  - Mock implementations (testing)                   │
└─────────────────────────────────────────────────────┘
```

### 1.2 What swift-actor-runtime Provides

**Data Structures** (transport-agnostic):
- `InvocationEnvelope`: Serializable RPC request
- `ResponseEnvelope`: Serializable RPC response
- `InvocationResult`: Success/Void/Failure enum

**Codec System** (encoding/decoding):
- `CodableInvocationEncoder`: Encode method calls
- `CodableInvocationDecoder`: Decode method calls
- `CodableResultHandler`: Handle execution results

**Actor Registry**:
- `ActorRegistry`: Thread-safe actor instance tracking
- Strong references (must explicitly unregister)

**Error Types**:
- `RuntimeError`: Codable, serializable errors

### 1.3 What Bleu Provides

**BLE Transport Layer**:
- CoreBluetooth integration (CBCentralManager/CBPeripheralManager)
- Connection management and state tracking
- Service/characteristic discovery
- Message fragmentation and reassembly

**Actor System Implementation**:
- `BLEActorSystem`: DistributedActorSystem conformance
- Two execution modes: same-process and cross-process
- Timeout handling for remote calls
- Error conversion between RuntimeError and BleuError

**Testing Infrastructure**:
- Mock implementations (MockCentralManager/MockPeripheralManager)
- Same-process direct execution (no BLE hardware needed)

## 2. Core Components

### 2.1 BLEActorSystem

The central actor system implementation that bridges Swift's distributed actor runtime with BLE transport.

#### Two Execution Modes

**Mode 1: Same-Process (Mock/Testing)**
```swift
// Both actors in the same BLEActorSystem
let system = await BLEActorSystem.mock()
let sensor = TemperatureSensor(actorSystem: system)
let proxy = try TemperatureSensor.resolve(id: sensor.id, using: system)

// Direct in-memory execution - no BLE involved
let temp = try await proxy.readTemperature()  // Instant!
```

**Implementation**:
- Uses `ActorRegistry.find()` to locate actor in same process
- Creates envelope but doesn't serialize to wire format
- Calls `executeDistributedTarget()` directly
- No network delay, no timeout needed
- Pattern from `InMemoryActorSystem` in swift-actor-runtime

**Mode 2: Cross-Process (Real BLE)**
```swift
// Peripheral device (Device A)
let peripheralSystem = BLEActorSystem.production()
let sensor = TemperatureSensor(actorSystem: peripheralSystem)
try await peripheralSystem.startAdvertising(sensor)

// Central device (Device B - different process/device)
let centralSystem = BLEActorSystem.production()
let proxies = try await centralSystem.discover(TemperatureSensor.self)
let temp = try await proxies[0].readTemperature()  // BLE transport!
```

**Implementation**:
- Serializes `InvocationEnvelope` to Data
- Sends via BLE (CoreBluetooth)
- Waits for `ResponseEnvelope` with timeout
- Handles connection failures and retries

#### Key Methods

**Same-Process Detection**:
```swift
public func remoteCall<Act, Err, Res>(...) async throws -> Res {
    // Check if actor is local (same process)
    if let targetActor = registry.find(id: actor.id.uuidString) {
        // Mode 1: Direct execution
        return try await executeDirect(targetActor, ...)
    } else {
        // Mode 2: BLE transport
        return try await executeViaBLE(actor, ...)
    }
}
```

**Direct Execution** (lines 263-290 in BLEActorSystem.swift):
```swift
// 1. Create envelope (for consistency)
var encoder = invocation
encoder.recordTarget(target)
let envelope = try encoder.makeInvocationEnvelope(recipientID: actor.id.uuidString)

// 2. Create decoder
var decoder = try CodableInvocationDecoder(envelope: envelope)

// 3. Capture result synchronously
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

// 4. Execute directly via Swift runtime
try await executeDistributedTarget(
    on: targetActor,
    target: target,
    invocationDecoder: &decoder,
    handler: handler
)

// 5. Return result
return try capturedResult!.get()
```

### 2.2 Actor Registries

#### ActorRegistry (from swift-actor-runtime)

**Purpose**: Track distributed actor instances
**Thread Safety**: `Synchronization.Mutex`
**Memory**: Strong references (must unregister!)

```swift
private let registry = ActorRegistry()

// Register
public func actorReady<Act>(_ actor: Act) where Act: DistributedActor {
    registry.register(actor, id: actor.id.uuidString)
}

// Unregister
public func resignID(_ id: ActorID) {
    registry.unregister(id: id.uuidString)
}
```

#### InstanceRegistry (Bleu-specific)

**Purpose**: Additional BLE-specific metadata
**Implementation**: Actor (async isolation)
**Features**:
- Track local vs remote actors
- Map actors to peripheral IDs
- Type indexing for discovery

**Current Status**: May be redundant with ActorRegistry. Consider removal or consolidation.

### 2.3 BLE Transport Layer

#### CoreBluetooth Wrappers

**Purpose**: Abstract CoreBluetooth APIs for testability

```
BLEManagerProtocols
├── BLECentralManagerProtocol
│   └── CoreBluetoothCentralManager (production)
│   └── MockCentralManager (testing)
└── BLEPeripheralManagerProtocol
    └── CoreBluetoothPeripheralManager (production)
    └── MockPeripheralManager (testing)
```

**Key Features**:
- Async/await APIs (no delegate callbacks exposed)
- Event streams for state changes
- Timeout support
- Power state management

#### BLETransport

**Purpose**: Message fragmentation and reassembly
**MTU Handling**: Adapts to connection's maximum write length
**Protocol**: Custom header for multi-packet messages

**Current Implementation**: Handles large messages that exceed BLE MTU

### 2.4 Service Mapping

**ServiceMapper**: Converts Swift types to BLE GATT structure

```swift
distributed actor TemperatureSensor {
    distributed func readTemperature() -> Double { 22.5 }
    distributed func setThreshold(_ value: Double) async throws { }
}

// Maps to:
Service UUID: deterministic from type name
├── Characteristic "__rpc__" (RPC channel)
│   ├── Properties: Read, Write, Notify
│   └── Used for all distributed method calls
└── [Future: Per-method characteristics for optimization]
```

**Current Design**: Single RPC characteristic for all methods
**Rationale**: Simplicity, leverages swift-actor-runtime's method dispatch

## 3. Data Flow

### 3.1 Same-Process Call (Mock Mode)

```
Central                          Peripheral
  │                                  │
  ├──> resolve(id, type)             │
  │    ├─> ActorRegistry.find() ─────┤ Found!
  │    └─> Return nil (create proxy) │
  │                                   │
  ├──> proxy.method()                 │
  │    ├─> remoteCall()               │
  │    ├─> registry.find(id) ────────┤ Local actor found
  │    ├─> Create InvocationEnvelope  │
  │    ├─> CodableInvocationDecoder   │
  │    ├─> executeDistributedTarget() │
  │    │   └──> Calls sensor.method() ┤ Direct call!
  │    └─> Return result              │
  │                                   │
  └─> Result (instant, no BLE)       │
```

**No network I/O, no serialization to wire format, no timeouts.**

### 3.2 Cross-Process Call (Real BLE)

```
Central Device                              Peripheral Device
  │                                              │
  ├──> discover(type)                            │
  │    ├─> scanForPeripherals(serviceUUID)      │
  │    │   <─────── BLE Advertisement ──────────┤
  │    ├─> connect(peripheralID)                │
  │    │   <─────── BLE Connection ─────────────┤
  │    ├─> discoverServices([serviceUUID])      │
  │    │   <─────── Service Discovery ──────────┤
  │    ├─> discoverCharacteristics([rpcUUID])   │
  │    │   <─────── Characteristic Discovery ───┤
  │    └─> setNotifyValue(true, rpcUUID)        │
  │        <─────── Notification Enabled ────────┤
  │                                              │
  ├──> proxy.method()                            │
  │    ├─> remoteCall()                          │
  │    ├─> registry.find(id) ────────────────────┤ Not found (remote)
  │    ├─> Create InvocationEnvelope             │
  │    ├─> Serialize to Data                     │
  │    ├─> BLETransport.send(data)               │
  │    │   ├─> Fragment if > MTU                 │
  │    │   └─────── Write to RPC char ──────────>│
  │    │                                          ├─> Receive write
  │    │                                          ├─> Reassemble if fragmented
  │    │                                          ├─> Decode InvocationEnvelope
  │    │                                          ├─> registry.find(recipientID)
  │    │                                          ├─> CodableInvocationDecoder
  │    │                                          ├─> executeDistributedTarget()
  │    │                                          ├─> Execute method on actor
  │    │                                          ├─> CodableResultHandler
  │    │                                          ├─> Create ResponseEnvelope
  │    │                                          └─> Serialize to Data
  │    │   <─────── Notify RPC char ─────────────┤
  │    ├─> Receive notification                  │
  │    ├─> Reassemble if fragmented              │
  │    ├─> Decode ResponseEnvelope               │
  │    └─> Extract result                        │
  │                                              │
  └─> Result (with BLE latency)                  │
```

### 3.3 RPC Execution Flow

**Peripheral Side** (receives RPC):

```swift
// When data arrives on RPC characteristic
func handleIncomingRPC(_ envelope: InvocationEnvelope) async -> ResponseEnvelope {
    // 1. Find target actor
    guard let actor = await instanceRegistry.find(envelope.recipientID) else {
        return ResponseEnvelope(callID: envelope.callID,
                                result: .failure(.actorNotFound(...)))
    }

    // 2. Create decoder
    var decoder = try CodableInvocationDecoder(envelope: envelope)

    // 3. Create result handler
    var capturedResponse: ResponseEnvelope?
    let handler = CodableResultHandler(callID: envelope.callID) { response in
        capturedResponse = response
    }

    // 4. Execute method via Swift runtime
    try await executeDistributedTarget(
        on: actor,
        target: RemoteCallTarget(envelope.target),
        invocationDecoder: &decoder,
        handler: handler
    )

    // 5. Return response for transmission
    return capturedResponse!
}
```

**No manual method dispatch needed** - Swift's `executeDistributedTarget` handles it automatically based on the `RemoteCallTarget` identifier.

## 4. What Bleu Does NOT Do

### 4.1 Method Registration

**DON'T**: Create MethodRegistry or manually register methods
**WHY**: Swift's distributed actor runtime handles method dispatch automatically via `executeDistributedTarget`

**Deleted**:
- `Sources/Bleu/Mapping/MethodRegistry.swift` ❌

### 4.2 Event Bus for RPC

**DON'T**: Use EventBridge or message buses for RPC management
**WHY**: RPC flow is request/response, not publish/subscribe

**Deleted**:
- `Sources/Bleu/Core/EventBridge.swift` ❌

**EventBridge** should only handle BLE lifecycle events:
- Connection state changes
- Discovery events
- Power state changes

**NOT** for:
- RPC invocation routing
- Response delivery
- Method dispatch

### 4.3 Mock BLE Routing

**DON'T**: Route messages between MockCentralManager and MockPeripheralManager
**WHY**: Same-process mode should use direct actor calls (no transport)

**Current Issue**: MockCentralManager/MockPeripheralManager have complex routing via shared bridge
**Solution**: Remove bridge, use registry.find() for same-process detection

### 4.4 Custom Transport Protocol

**DON'T**: Invent custom RPC serialization formats
**DO**: Use InvocationEnvelope/ResponseEnvelope from swift-actor-runtime

**Benefits**:
- Standardized format across transports
- Interoperability with other swift-actor-runtime implementations
- Tested and proven serialization

## 5. Implementation Patterns

### 5.1 Actor Lifecycle

**Local Actor (Peripheral)**:
```swift
// 1. Create actor
let sensor = TemperatureSensor(actorSystem: system)

// 2. Register (automatic via actorReady)
// BLEActorSystem.actorReady() called by Swift runtime

// 3. Advertise
try await system.startAdvertising(sensor)

// 4. Handle incoming RPCs
// Automatic via handleIncomingRPC()

// 5. Cleanup
await system.stopAdvertising()
// Actor dealloc triggers resignID()
```

**Remote Actor (Central)**:
```swift
// 1. Discover
let proxies = try await system.discover(TemperatureSensor.self)

// 2. Use (transparent RPC)
let temp = try await proxies[0].readTemperature()

// 3. Disconnect
try await system.disconnect(from: proxies[0].id)
// Triggers resignID() and cleanup
```

### 5.2 Error Handling

**Error Conversion**:
```swift
// RuntimeError (from swift-actor-runtime) <-> BleuError (transport-specific)

BleuError.actorNotFound(uuid) <-> RuntimeError.actorNotFound(string)
BleuError.connectionTimeout <-> RuntimeError.timeout(duration)
BleuError.rpcFailed(message) <-> RuntimeError.executionFailed(message, underlying)
```

**Error Propagation**:
1. Actor method throws Swift error
2. `CodableResultHandler` wraps in `RuntimeError`
3. Serialized in `ResponseEnvelope`
4. Sent over BLE
5. Deserialized on central
6. Converted to `BleuError` if needed
7. Thrown to caller

### 5.3 Testing Strategy

**Unit Tests**: Use mock implementations
```swift
let system = await BLEActorSystem.mock()
// No BLE hardware, no permissions, instant execution
```

**Integration Tests**: Use real CoreBluetooth on devices
```swift
let system = BLEActorSystem.production()
// Requires hardware, permissions, slower
```

**Mock Configuration**:
```swift
let config = MockCentralManager.Configuration(
    scanDelay: 0.1,          // Simulate scan time
    connectionDelay: 0.05,   // Simulate connection
    shouldFailConnection: false
)
let system = await BLEActorSystem.mock(centralConfig: config)
```

## 6. Current Issues and Cleanup Needed

### 6.1 Redundant Registry

**Issue**: Both `ActorRegistry` (swift-actor-runtime) and `InstanceRegistry` (Bleu)

**Analysis**:
- `ActorRegistry`: Core actor lookup, used in remoteCall()
- `InstanceRegistry`: Adds peripheral ID mapping, type indexing

**Recommendation**:
- Keep `ActorRegistry` as primary
- Keep `InstanceRegistry` only if peripheral mapping is essential
- Document clear separation of concerns
- Consider: Can peripheral mapping be in ProxyManager instead?

### 6.2 EventBridge References

**Status**: EventBridge.swift deleted but still referenced

**Locations**:
- `BLEActorSystem.swift:576, 579, 657, 660` - calls to eventBridge methods

**Action Required**:
1. Remove eventBridge property from BLEActorSystem
2. Remove subscription calls (lines 654, 657, 660)
3. Remove unsubscribe calls (line 576, 579)

**Replacement**:
- Connection events → handle in connection methods directly
- RPC characteristic mapping → use ProxyManager

### 6.3 Mock Implementation Complexity

**Current**:
- MockCentralManager and MockPeripheralManager share a MockBLEBridge
- Bridge routes messages with async delays
- Simulates BLE I/O even in same-process mode

**Problem**:
- Same-process calls should be instant (no delays)
- Bridge adds unnecessary complexity
- Tests are slower than needed

**Solution**:
- Remove MockBLEBridge
- Mock managers only store state (discovered peripherals, services, etc.)
- Same-process detection in remoteCall() skips all mock BLE logic
- Tests run at full speed (like InMemoryActorSystem)

### 6.4 Missing Cross-Process Implementation

**Current**: `remoteCall()` throws error if actor not in registry (line 294)

```swift
// TODO: Real BLE transport for cross-process communication
// For now, throw error if not in same process
throw BleuError.actorNotFound(actor.id)
```

**Needed**:
1. Serialize InvocationEnvelope to Data
2. Get PeripheralActorProxy from proxyManager
3. Send via BLE (using BLETransport for fragmentation)
4. Set up pending call continuation
5. Implement timeout with TaskGroup
6. Handle ResponseEnvelope when received

**Reference**: See "3.2 Cross-Process Call" for full flow

## 7. Recommended Refactoring Steps

### Phase 1: Cleanup (Non-Breaking)

1. **Remove EventBridge references** in BLEActorSystem.swift
   - Delete eventBridge property
   - Remove subscription/unsubscribe calls
   - Move characteristic mapping to ProxyManager

2. **Simplify Mock implementations**
   - Remove MockBLEBridge (if exists)
   - Keep mocks as state stores only
   - Document that same-process mode skips mock I/O

3. **Document InstanceRegistry purpose**
   - Add clear comments explaining vs ActorRegistry
   - Consider renaming to BLEMetadataRegistry

### Phase 2: Complete Cross-Process Mode

4. **Implement real BLE transport in remoteCall()**
   - Add else branch for cross-process execution
   - Serialize envelope and send via BLE
   - Implement timeout handling
   - Handle ResponseEnvelope reception

5. **Set up response handling**
   - Add pendingCalls map: [UUID: CheckedContinuation<Res, Error>]
   - Subscribe to RPC characteristic notifications
   - Match responses to pending calls
   - Resume continuations with results

### Phase 3: Optimization (Optional)

6. **Remove InstanceRegistry if redundant**
   - Move peripheral mapping to ProxyManager
   - Use ActorRegistry exclusively for actor lookup
   - Simplify actor lifecycle

7. **Add per-method characteristics** (future)
   - Generate characteristic per distributed method
   - Optimize for method-specific properties
   - Maintain backward compatibility with RPC channel

## 8. Testing Requirements

### 8.1 Same-Process Mode Tests

**Must verify**:
- ✅ Actor registered in ActorRegistry
- ✅ remoteCall() finds actor locally
- ✅ Direct execution via executeDistributedTarget
- ✅ No BLE I/O (instant execution)
- ✅ Errors propagated correctly
- ✅ No timeouts needed

### 8.2 Cross-Process Mode Tests

**Must verify**:
- ✅ Actor NOT in registry (remote)
- ✅ Envelope serialized correctly
- ✅ Data sent via BLE transport
- ✅ Response received and deserialized
- ✅ Result extracted correctly
- ✅ Timeout enforced
- ✅ Connection failures handled

### 8.3 Integration Tests

**Scenarios**:
1. Peripheral advertises → Central discovers → Connect → RPC call → Disconnect
2. Multiple peripherals discovered simultaneously
3. Connection timeout during discovery
4. Service/characteristic not found
5. Large message fragmentation
6. Peripheral disconnects during RPC
7. Multiple concurrent RPCs

## 9. API Examples

### 9.1 Defining an Actor

```swift
import Bleu
import Distributed

distributed actor TemperatureSensor: PeripheralActor {
    typealias ActorSystem = BLEActorSystem

    private var temperature: Double = 22.5
    private var threshold: Double = 30.0

    // Distributed methods - automatically mapped to BLE RPC
    distributed func readTemperature() -> Double {
        return temperature
    }

    distributed func setThreshold(_ value: Double) async throws {
        guard value >= -50 && value <= 100 else {
            throw TemperatureError.invalidThreshold
        }
        threshold = value
    }

    distributed func startMonitoring() async throws {
        // Continuous monitoring loop
        while !Task.isCancelled {
            temperature = await simulateReading()
            try await Task.sleep(for: .seconds(1))
        }
    }

    // Private methods - not exposed via BLE
    private func simulateReading() -> Double {
        return Double.random(in: 20.0...30.0)
    }
}

enum TemperatureError: Error {
    case invalidThreshold
}
```

### 9.2 Peripheral (Advertising)

```swift
// Create actor system
let system = BLEActorSystem.production()

// Create sensor actor
let sensor = TemperatureSensor(actorSystem: system)

// Start advertising
try await system.startAdvertising(sensor)
print("Advertising as temperature sensor...")

// Keep running
try await Task.sleep(for: .seconds(60))

// Cleanup
await system.stopAdvertising()
```

### 9.3 Central (Discovering and Calling)

```swift
// Create actor system
let system = BLEActorSystem.production()

// Discover sensors
let sensors = try await system.discover(TemperatureSensor.self, timeout: 5.0)
print("Found \(sensors.count) sensors")

// Call methods on remote actor (transparent RPC)
for sensor in sensors {
    let temp = try await sensor.readTemperature()
    print("Temperature: \(temp)°C")

    try await sensor.setThreshold(35.0)
    print("Threshold updated")
}

// Disconnect
for sensor in sensors {
    try await system.disconnect(from: sensor.id)
}
```

### 9.4 Testing with Mocks

```swift
import XCTest
@testable import Bleu

class TemperatureSensorTests: XCTestCase {
    func testReadTemperature() async throws {
        // Create mock system (same process)
        let system = await BLEActorSystem.mock()

        // Create sensor
        let sensor = TemperatureSensor(actorSystem: system)

        // Create proxy (normally done by discovery)
        let proxy = try TemperatureSensor.resolve(id: sensor.id, using: system)

        // Call method - executes instantly via registry.find()
        let temp = try await proxy.readTemperature()

        // Verify
        XCTAssertEqual(temp, 22.5)
    }

    func testSetThreshold() async throws {
        let system = await BLEActorSystem.mock()
        let sensor = TemperatureSensor(actorSystem: system)
        let proxy = try TemperatureSensor.resolve(id: sensor.id, using: system)

        // Valid threshold
        try await proxy.setThreshold(35.0)

        // Invalid threshold
        do {
            try await proxy.setThreshold(150.0)
            XCTFail("Should throw error")
        } catch TemperatureError.invalidThreshold {
            // Expected
        }
    }
}
```

## 10. Performance Considerations

### 10.1 BLE MTU

**Default**: 23 bytes (ATT_MTU) - 3 bytes header = 20 bytes payload
**Negotiated**: Up to 512 bytes (iOS 10+)

**BLETransport**:
- Queries `maximumWriteValueLength` per connection
- Fragments messages automatically
- Reassembles on receiver
- Updates when MTU changes

### 10.2 Latency

**Same-Process Mode**:
- ~0.01ms (direct function call)
- No network overhead

**Cross-Process Mode**:
- ~50-200ms (BLE round trip)
- Depends on: connection interval, MTU, fragmentation

**Optimization**:
- Batch multiple calls if possible
- Use larger MTU (negotiate if supported)
- Cache frequently accessed values locally

### 10.3 Throughput

**Theoretical Max**:
- Connection interval: 7.5ms - 4000ms
- Events per interval: 1-6
- Max throughput: ~100 KB/s (depends on parameters)

**Practical**:
- Small messages (<100 bytes): 10-50 msg/s
- Large messages (>1 KB): 5-10 msg/s

**Recommendations**:
- Keep RPC payloads small
- Avoid chatty protocols
- Use streaming for continuous data

## 11. Security Considerations

### 11.1 BLE Security

**Transport Layer**:
- CoreBluetooth handles pairing/bonding
- Encryption automatic when paired
- No additional encryption in Bleu

**Authorization**:
- Service UUIDs are deterministic (can be discovered)
- No authentication in RPC layer (rely on BLE pairing)

**Future**:
- Add optional authentication token in InvocationEnvelope metadata
- Verify token in handleIncomingRPC before execution

### 11.2 Input Validation

**Actor Methods**:
- Always validate input parameters
- Throw typed errors for invalid input
- Don't trust remote callers

**Example**:
```swift
distributed func setThreshold(_ value: Double) async throws {
    guard value >= -50 && value <= 100 else {
        throw TemperatureError.invalidThreshold
    }
    threshold = value
}
```

## 12. Future Enhancements

### 12.1 Per-Method Characteristics

**Current**: Single RPC characteristic for all methods
**Future**: Generate characteristic per method

**Benefits**:
- Method-specific properties (read-only, write-only, notify)
- Better discoverability
- Potential performance optimization

**Tradeoff**:
- More characteristics = more discovery time
- More complex service structure

### 12.2 Streaming Support

**Scenario**: Continuous sensor data stream

**Current**: Repeated RPC calls
```swift
while true {
    let temp = try await sensor.readTemperature()
    try await Task.sleep(for: .seconds(1))
}
```

**Future**: AsyncSequence support
```swift
for await temp in sensor.temperatureStream() {
    print("Temperature: \(temp)°C")
}
```

**Implementation**:
- Use BLE notifications for data push
- Map to AsyncSequence in proxy
- Automatic backpressure handling

### 12.3 Multiple Transports

**Vision**: Same distributed actors over multiple transports

```swift
// BLE transport
let bleSensor = try TemperatureSensor.resolve(id: id, using: bleSystem)

// gRPC transport (same actor interface!)
let grpcSensor = try TemperatureSensor.resolve(id: id, using: grpcSystem)

// HTTP transport
let httpSensor = try TemperatureSensor.resolve(id: id, using: httpSystem)
```

**Enabled by**: swift-actor-runtime's transport-agnostic design

## 13. Conclusion

Bleu 2 is a **BLE transport implementation** for Swift's distributed actors, leveraging swift-actor-runtime for RPC infrastructure. Its responsibilities are:

**✅ DO**:
- Implement BLE I/O (CoreBluetooth wrappers)
- Handle connections and discovery
- Fragment/reassemble messages
- Convert errors between RuntimeError and BleuError
- Provide mock implementations for testing
- Detect same-process vs cross-process execution

**❌ DON'T**:
- Manually register methods (Swift runtime handles it)
- Create event buses for RPC routing
- Invent custom serialization formats
- Implement complex mock BLE routing for same-process calls
- Duplicate actor registry functionality

**Current Status**:
- ✅ Same-process mode: Working (direct execution)
- ⚠️ Cross-process mode: Partially implemented (needs completion)
- ⚠️ EventBridge: Deleted but references remain
- ⚠️ Mock implementations: Need simplification

**Next Steps**:
1. Remove EventBridge references
2. Complete cross-process BLE transport
3. Simplify mock implementations
4. Comprehensive testing

---

**References**:
- [swift-actor-runtime](https://github.com/1amageek/swift-actor-runtime)
- [Swift Distributed Actors](https://github.com/apple/swift-evolution/blob/main/proposals/0336-distributed-actor-isolation.md)
- [CoreBluetooth Framework](https://developer.apple.com/documentation/corebluetooth)
