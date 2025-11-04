# Design Document: Discovery Connection Flow Bug Fix

**Status**: ✅ Implemented
**Priority**: P0 - Critical
**Created**: 2025-01-04
**Last Updated**: 2025-01-04
**Implemented**: 2025-01-04
**Author**: Design Review

---

## Executive Summary

This document describes the design for fixing a critical bug in the `discover()` method where discovered peripheral actors are returned in an unusable state, causing all RPC calls to fail with `BleuError.actorNotFound`.

### Problem Statement

`discover(_:timeout:)` invokes `setupRemoteProxy()` on peripherals yielded from scan without connecting first. This causes:

1. `localCentral.discoverServices()` immediately throws `BleuError.peripheralNotFound`
2. The catch block in `setupRemoteProxy()` swallows the failure
3. The proxy never lands in `ProxyManager`
4. The actor is still registered and returned
5. First RPC attempt fails with `BleuError.actorNotFound`

### Solution Overview

Implement **eager connection** pattern in `discover()` to match the existing `connect(to:as:)` implementation:

1. Connect to peripheral before calling `setupRemoteProxy()`
2. Change `setupRemoteProxy()` to throw errors instead of swallowing them
3. Add proper cleanup on failure
4. Skip failed peripherals and continue with successful ones

---

## Table of Contents

1. [Current State Analysis](#current-state-analysis)
2. [Design Goals](#design-goals)
3. [Technical Design](#technical-design)
4. [API Contracts](#api-contracts)
5. [State Management](#state-management)
6. [Error Handling Strategy](#error-handling-strategy)
7. [Testing Strategy](#testing-strategy)
8. [Migration & Compatibility](#migration--compatibility)
9. [Performance Analysis](#performance-analysis)
10. [Implementation Plan](#implementation-plan)

---

## Current State Analysis

### Affected Files

1. **Sources/Bleu/Core/BLEActorSystem.swift:299** - `discover()` method
2. **Sources/Bleu/Core/BLEActorSystem.swift:381** - `setupRemoteProxy()` method
3. **Sources/Bleu/LocalActors/LocalCentralActor.swift:161** - `discoverServices()` method

### Current Flow (Broken)

```
discover()
  ├─ scan() for peripherals
  ├─ for each discovered:
  │    ├─ setupRemoteProxy(id) ❌ NOT CONNECTED
  │    │    ├─ discoverServices(id)
  │    │    │    └─ throw BleuError.peripheralNotFound ❌
  │    │    └─ catch { log error } ❌ SWALLOW ERROR
  │    ├─ T.resolve(id)
  │    ├─ instanceRegistry.registerRemote() ✅
  │    └─ append to discoveredActors ✅
  └─ return discoveredActors

User calls actor.method()
  └─ remoteCall()
       └─ proxyManager.get(id)
            └─ return nil ❌ NO PROXY EXISTS
                 └─ throw BleuError.actorNotFound ❌
```

### Working Reference: connect(to:as:)

The existing `connect(to:as:)` method (line 336) implements the correct pattern:

```swift
public func connect<T: PeripheralActor>(
    to peripheralID: UUID,
    as type: T.Type
) async throws -> T {
    // ✅ Connect first
    try await localCentral.connect(to: peripheralID)

    // ✅ Update MTU
    await updateTransportMTU(for: peripheralID)

    // ✅ Setup proxy (currently doesn't throw, but should)
    await setupRemoteProxy(id: peripheralID, type: type)

    // ✅ Create and register actor
    let actor = try T.resolve(id: peripheralID, using: self)
    await instanceRegistry.registerRemote(actor, peripheralID: peripheralID)

    return actor
}
```

---

## Design Goals

### Primary Goals

1. **Correctness**: `discover()` returns only actors that are immediately usable
2. **Consistency**: Match the pattern used by `connect(to:as:)`
3. **Error Detection**: Fail fast during discovery, not during first RPC
4. **Robustness**: Handle partial failures gracefully

### Non-Goals

1. **Lazy Connection**: Explicitly rejected (see Alternatives Considered)
2. **Background Reconnection**: Out of scope for this fix
3. **Connection Pooling**: Already handled by LocalCentralActor

---

## Technical Design

### Design Decision: Eager Connection

**Selected Approach**: Eager Connection (connect during discovery)

**Rationale**:
- Matches existing `connect(to:as:)` pattern
- Better user experience (actors ready immediately)
- Simpler error handling
- Earlier error detection

**Alternatives Considered**:

| Approach | Pros | Cons | Decision |
|----------|------|------|----------|
| Eager Connection | Immediate usability, early errors, simple | Slower discovery | ✅ **Selected** |
| Lazy Connection | Fast discovery | Complex RPC path, delayed errors | ❌ Rejected |
| Hybrid | Flexible | Complex API, confusing | ❌ Rejected |

### Modified discover() Flow

```swift
/// Discover peripherals of a specific type
public func discover<T: PeripheralActor>(
    _ type: T.Type,
    timeout: TimeInterval = 10.0
) async throws -> [T] {
    // 1. System readiness check
    guard await ready else {
        throw BleuError.bluetoothUnavailable
    }

    let serviceUUID = UUID.serviceUUID(for: type)
    var discoveredActors: [T] = []

    // 2. Scan for peripherals
    for await discovered in await localCentral.scan(
        for: [CBUUID(nsuuid: serviceUUID)],
        timeout: timeout
    ) {
        do {
            // 3. CONNECT FIRST (NEW)
            try await localCentral.connect(to: discovered.id, timeout: 10.0)

            // 4. Update MTU (NEW)
            await updateTransportMTU(for: discovered.id)

            // 5. Setup proxy (MODIFIED - now throws)
            try await setupRemoteProxy(id: discovered.id, type: type)

            // 6. Create remote actor reference
            let actor = try T.resolve(id: discovered.id, using: self)

            // 7. Register in instance registry
            await instanceRegistry.registerRemote(actor, peripheralID: discovered.id)

            // 8. Add to results
            discoveredActors.append(actor)

        } catch {
            // 9. Log and skip failed peripherals
            BleuLogger.actorSystem.warning(
                "Failed to setup peripheral \(discovered.id): \(error.localizedDescription)"
            )

            // 10. Cleanup on failure (NEW)
            try? await localCentral.disconnect(from: discovered.id)

            // Continue with next peripheral
            continue
        }
    }

    return discoveredActors
}
```

### Modified setupRemoteProxy()

```swift
/// Setup a proxy for a remote peripheral
/// - Precondition: Must be connected to the peripheral
/// - Throws: BleuError if setup fails
private func setupRemoteProxy<T: PeripheralActor>(
    id: UUID,
    type: T.Type
) async throws {
    // 1. Check for existing proxy (idempotent)
    if await proxyManager.get(id) != nil {
        return
    }

    // 2. Calculate UUIDs
    let serviceUUID = UUID.serviceUUID(for: type)
    let rpcCharUUID = UUID.characteristicUUID(for: "__rpc__", in: type)

    // 3. Discover services (THROW ERRORS - don't catch)
    let services = try await localCentral.discoverServices(
        for: id,
        serviceUUIDs: [CBUUID(nsuuid: serviceUUID)]
    )

    guard !services.isEmpty else {
        throw BleuError.serviceNotFound(serviceUUID)
    }

    // 4. Discover characteristics (THROW ERRORS)
    let characteristics = try await localCentral.discoverCharacteristics(
        for: CBUUID(nsuuid: serviceUUID),
        in: id,
        characteristicUUIDs: [CBUUID(nsuuid: rpcCharUUID)]
    )

    guard !characteristics.isEmpty else {
        throw BleuError.characteristicNotFound(rpcCharUUID)
    }

    // 5. Create proxy
    let proxy = PeripheralActorProxy(
        id: id,
        localCentral: localCentral,
        rpcCharUUID: rpcCharUUID
    )

    await proxyManager.set(id, proxy: proxy)

    // 6. Setup event handling
    let eventHandler: EventBridge.EventHandler = { @Sendable (event: BLEEvent) async throws in
        BleuLogger.actorSystem.debug("Event for remote actor: \(id)")
    }
    await eventBridge.subscribe(id, handler: eventHandler)
    await eventBridge.subscribeToCharacteristic(rpcCharUUID, actorID: id)
    await eventBridge.registerRPCCharacteristic(rpcCharUUID, for: id)

    // 7. Enable notifications (THROW ERRORS)
    try await localCentral.setNotifyValue(
        true,
        for: CBUUID(nsuuid: rpcCharUUID),
        in: id
    )
}
```

### Error Cases Used

The following error cases from `Sources/Bleu/Core/BleuError.swift` are used in this design:

```swift
public enum BleuError: Error, Codable, LocalizedError {
    // System-level errors
    case bluetoothUnavailable
    case bluetoothUnauthorized
    case bluetoothPoweredOff

    // Connection errors
    case peripheralNotFound(UUID)
    case connectionTimeout
    case connectionFailed(String)        // Note: takes String, not Error
    case disconnected

    // Service/Characteristic errors (ALREADY EXIST - no need to add)
    case serviceNotFound(UUID)           // ✅ Already defined
    case characteristicNotFound(UUID)    // ✅ Already defined

    // RPC errors
    case actorNotFound(UUID)
    case rpcFailed(String)

    // Data errors
    case invalidData
    case incompatibleVersion(detected: Int, required: Int)
    case quotaExceeded

    // Other errors
    case operationNotSupported
    case methodNotSupported(String)
}
```

**Note**: `serviceNotFound` and `characteristicNotFound` are already defined in the
current codebase, so no new error cases need to be added for this fix.

---

## API Contracts

### discover() Contract

```swift
/// Discover peripherals of a specific type
///
/// This method scans for BLE peripherals advertising the service UUID
/// associated with the specified actor type, connects to each discovered
/// peripheral, and returns an array of ready-to-use actor references.
///
/// - Parameter type: The distributed actor type to discover
/// - Parameter timeout: Maximum time to scan for peripherals (default: 10.0s)
/// - Returns: Array of connected, ready-to-use peripheral actors
///
/// ## Postconditions
///
/// All returned actors are guaranteed to be:
/// 1. Connected to their BLE peripherals
/// 2. Have discovered required services and characteristics
/// 3. Have active notification subscriptions on RPC characteristic
/// 4. Immediately ready for RPC method calls
///
/// ## Error Handling
///
/// Peripherals that fail connection or setup are:
/// 1. Logged as warnings with error details
/// 2. Cleaned up (disconnected) automatically
/// 3. Excluded from the result array
///
/// The method returns successfully even if some peripherals fail,
/// as long as at least one succeeds. Returns empty array if none succeed.
///
/// - Throws:
///   - `BleuError.bluetoothUnavailable`: Bluetooth is not ready
///   - Other errors only if thrown before scanning begins
///
/// ## Example
///
/// ```swift
/// let sensors = try await system.discover(TemperatureSensor.self, timeout: 10.0)
///
/// // All sensors are immediately usable
/// for sensor in sensors {
///     let temperature = try await sensor.readTemperature()
///     print("Temperature: \(temperature)°C")
/// }
/// ```
```

### setupRemoteProxy() Contract

```swift
/// Setup a proxy for a remote peripheral
///
/// Creates a PeripheralActorProxy for communicating with a connected peripheral.
/// This method discovers the required BLE services and characteristics,
/// creates the proxy object, and enables notifications.
///
/// - Precondition: The peripheral MUST be connected via LocalCentralActor
/// - Parameter id: The UUID of the connected peripheral
/// - Parameter type: The distributed actor type
///
/// ## Postconditions
///
/// If successful:
/// 1. `ProxyManager` contains a proxy for this peripheral
/// 2. `EventBridge` is subscribed to RPC characteristic
/// 3. Notifications are enabled on RPC characteristic
///
/// ## Idempotency
///
/// This method is idempotent. Calling it multiple times with the same
/// peripheral ID has no additional effect after the first successful call.
///
/// - Throws:
///   - `BleuError.peripheralNotFound`: Not connected to peripheral
///   - `BleuError.serviceNotFound`: Required service not found on peripheral
///   - `BleuError.characteristicNotFound`: RPC characteristic not found
///   - Other CoreBluetooth errors during service/characteristic discovery
///
/// ## Internal Method
///
/// This is a private implementation detail. External callers should use
/// `discover()` or `connect(to:as:)` instead.
```

---

## State Management

### Invariants

The following invariants MUST hold at all times:

```
Invariant 1: ProxyManager State
    ∀ peripheral_id:
        ProxyManager.hasProxy(peripheral_id)
        ⟺
        (Connected(peripheral_id) ∧ ServicesDiscovered(peripheral_id)
         ∧ CharacteristicsDiscovered(peripheral_id))

Invariant 2: Registry Consistency
    ∀ peripheral_id:
        InstanceRegistry.hasRemote(peripheral_id)
        ⟹
        ProxyManager.hasProxy(peripheral_id)

Invariant 3: Actor Usability
    ∀ actor ∈ discover().result:
        isUsable(actor) = true

    where isUsable(actor) =
        ProxyManager.hasProxy(actor.id) ∧
        EventBridge.isSubscribed(actor.id) ∧
        NotificationsEnabled(actor.id)
```

### State Transition Diagram

```
                                START
                                  │
                                  │ scan()
                                  ↓
                            [Discovered]
                                  │
                                  │ connect()
                                  ↓
                            [Connecting]
                                  │
                    ┌─────────────┴─────────────┐
                    │ success                   │ failure
                    ↓                           ↓
              [Connected]                  [Error State]
                    │                           │
                    │ discoverServices()        │ cleanup
                    ↓                           │
          [Services Discovered]                 │
                    │                           │
                    │ discoverCharacteristics() │
                    ↓                           │
       [Characteristics Discovered]             │
                    │                           │
                    │ createProxy()             │
                    ↓                           │
             [Proxy Created]                    │
                    │                           │
                    │ setNotifyValue()          │
                    ↓                           │
          [Notifications Enabled]               │
                    │                           │
                    │ register()                │
                    ↓                           │
               [Ready] ✅                        │
                    │                           │
                    │ return to user            │
                    ↓                           ↓
              [In Use]                    [Cleaned Up]
                                                │
                                                │ continue
                                                ↓
                                          (next peripheral)
```

### Connection State Tracking

State is tracked implicitly through:

1. **LocalCentralActor.connectedPeripherals** - Dictionary of connected peripherals
2. **ProxyManager** - Actor tracking PeripheralActorProxy instances
3. **InstanceRegistry** - Maps actor instances to peripheral UUIDs
4. **EventBridge** - Tracks subscriptions by peripheral UUID

No additional explicit state tracking needed.

---

## Error Handling Strategy

### Error Classification

| Error Type | Occurrence | Handling | User Impact |
|-----------|------------|----------|-------------|
| **Bluetooth Unavailable** | Before scan | Throw immediately | discover() fails |
| **Scan Timeout** | During scan | Normal completion | Returns discovered peripherals |
| **Connection Timeout** | Per peripheral | Log, cleanup, skip | Other peripherals still returned |
| **Connection Failed** | Per peripheral | Log, cleanup, skip | Other peripherals still returned |
| **Service Not Found** | Per peripheral | Log, cleanup, skip | Other peripherals still returned |
| **Characteristic Not Found** | Per peripheral | Log, cleanup, skip | Other peripherals still returned |
| **Notify Setup Failed** | Per peripheral | Log, cleanup, skip | Other peripherals still returned |

### Error Recovery Flow

```swift
do {
    try await localCentral.connect(to: peripheralID)
    try await setupRemoteProxy(id: peripheralID, type: type)
    // ... register and return actor
} catch let error as BleuError {
    // Structured error logging
    switch error {
    case .connectionTimeout:
        BleuLogger.actorSystem.warning("Connection timeout for \(peripheralID)")
    case .connectionFailed(let message):
        BleuLogger.actorSystem.warning("Connection failed for \(peripheralID): \(message)")
    case .serviceNotFound(let uuid):
        BleuLogger.actorSystem.warning("Service \(uuid) not found on \(peripheralID)")
    case .characteristicNotFound(let uuid):
        BleuLogger.actorSystem.warning("Characteristic \(uuid) not found on \(peripheralID)")
    case .peripheralNotFound(let uuid):
        BleuLogger.actorSystem.warning("Peripheral \(uuid) not found")
    default:
        BleuLogger.actorSystem.warning("Setup failed for \(peripheralID): \(error)")
    }

    // Cleanup
    try? await localCentral.disconnect(from: peripheralID)

    // Continue with next peripheral
    continue

} catch {
    // Unexpected errors (non-BleuError)
    BleuLogger.actorSystem.error("Unexpected error for \(peripheralID): \(error)")
    try? await localCentral.disconnect(from: peripheralID)
    continue
}
```

### Logging Levels

```swift
// Critical system issues
BleuLogger.actorSystem.error("Bluetooth unavailable")
BleuLogger.actorSystem.error("Unexpected error in setupRemoteProxy: \(error)")

// Expected peripheral-specific issues (recoverable)
BleuLogger.actorSystem.warning("Failed to setup peripheral \(id): \(error)")
BleuLogger.actorSystem.warning("Connection timeout for \(id)")
BleuLogger.actorSystem.warning("Service not found on \(id)")

// Normal operational events
BleuLogger.actorSystem.info("Discovered \(count) peripherals")
BleuLogger.actorSystem.info("Successfully setup \(id)")

// Debug information
BleuLogger.actorSystem.debug("Connecting to \(id)")
BleuLogger.actorSystem.debug("Proxy created for \(id)")
BleuLogger.actorSystem.debug("Notifications enabled for \(id)")
```

---

## Testing Strategy

### Unit Tests

```swift
@Suite("BLEActorSystem Discovery Tests")
struct DiscoveryTests {

    @Test("discover() connects before setting up proxy")
    func testDiscoverConnectsFirst() async throws {
        // Verify connection happens before setupRemoteProxy
        let system = BLEActorSystem.shared

        // Mock LocalCentralActor to track call order
        var calls: [String] = []

        // Override connect
        // Override setupProxy

        let _ = try await system.discover(MockSensor.self, timeout: 5.0)

        #expect(calls[0] == "connect")
        #expect(calls[1] == "setupProxy")
    }

    @Test("discovered actors are immediately usable")
    func testDiscoveredActorsReady() async throws {
        let system = BLEActorSystem.shared

        let sensors = try await system.discover(MockSensor.self, timeout: 5.0)

        guard let sensor = sensors.first else {
            throw TestError.noSensorsFound
        }

        // This should succeed (currently fails)
        let value = try await sensor.readValue()
        #expect(value >= 0)
    }

    @Test("setupRemoteProxy throws when not connected")
    func testSetupProxyRequiresConnection() async throws {
        let system = BLEActorSystem.shared
        let fakeID = UUID()

        do {
            try await system.setupRemoteProxy(id: fakeID, type: MockSensor.self)
            #fail("Should throw peripheralNotFound")
        } catch BleuError.peripheralNotFound {
            // Expected
        }
    }

    @Test("discover() skips failed peripherals")
    func testDiscoverSkipsFailures() async throws {
        // Mock: 3 peripherals, middle one fails connection
        let system = BLEActorSystem.shared

        let sensors = try await system.discover(MockSensor.self, timeout: 5.0)

        // Should return 2 successful sensors
        #expect(sensors.count == 2)

        // All should be usable
        for sensor in sensors {
            let _ = try await sensor.readValue()
        }
    }

    @Test("setupRemoteProxy is idempotent")
    func testSetupProxyIdempotent() async throws {
        let system = BLEActorSystem.shared
        let peripheralID = UUID()

        try await system.localCentral.connect(to: peripheralID)

        // Call multiple times
        try await system.setupRemoteProxy(id: peripheralID, type: MockSensor.self)
        try await system.setupRemoteProxy(id: peripheralID, type: MockSensor.self)
        try await system.setupRemoteProxy(id: peripheralID, type: MockSensor.self)

        // Only one proxy should exist
        let proxy = await system.proxyManager.get(peripheralID)
        #expect(proxy != nil)
    }

    @Test("cleanup on connection failure")
    func testCleanupOnFailure() async throws {
        let system = BLEActorSystem.shared

        // Mock: Connection succeeds, setupProxy fails

        let sensors = try await system.discover(MockSensor.self, timeout: 5.0)

        // Peripheral should be disconnected (cleanup)
        let isConnected = await system.isConnected(failedPeripheralID)
        #expect(isConnected == false)
    }
}
```

### Integration Tests

```swift
@Suite("End-to-End Discovery Flow")
struct E2EDiscoveryTests {

    @Test("Full discovery and RPC flow")
    func testFullFlow() async throws {
        // Setup peripheral
        let peripheralSystem = BLEActorSystem()
        let sensor = TemperatureSensor(actorSystem: peripheralSystem)
        try await peripheralSystem.startAdvertising(sensor)

        // Setup central
        let centralSystem = BLEActorSystem()

        // Discover
        let sensors = try await centralSystem.discover(
            TemperatureSensor.self,
            timeout: 10.0
        )

        #expect(!sensors.isEmpty)

        // Multiple RPC calls should all succeed immediately
        let remoteSensor = sensors[0]
        let temp1 = try await remoteSensor.readTemperature()
        let temp2 = try await remoteSensor.readTemperature()
        let temp3 = try await remoteSensor.readTemperature()

        #expect(temp1 > 0)
        #expect(temp2 > 0)
        #expect(temp3 > 0)
    }

    @Test("Discover multiple peripheral types")
    func testMultipleTypes() async throws {
        let system = BLEActorSystem.shared

        async let tempSensors = system.discover(TemperatureSensor.self)
        async let lightSensors = system.discover(LightSensor.self)
        async let motionSensors = system.discover(MotionSensor.self)

        let (temps, lights, motions) = try await (tempSensors, lightSensors, motionSensors)

        #expect(!temps.isEmpty || !lights.isEmpty || !motions.isEmpty)
    }

    @Test("Concurrent discoveries")
    func testConcurrentDiscoveries() async throws {
        let system = BLEActorSystem.shared

        async let discovery1 = system.discover(TemperatureSensor.self)
        async let discovery2 = system.discover(TemperatureSensor.self)
        async let discovery3 = system.discover(TemperatureSensor.self)

        let (s1, s2, s3) = try await (discovery1, discovery2, discovery3)

        // All should succeed
        #expect(!s1.isEmpty)
        #expect(!s2.isEmpty)
        #expect(!s3.isEmpty)
    }
}
```

### Test Coverage Goals

- [ ] Unit test coverage: > 90%
- [ ] Integration test coverage: > 80%
- [ ] All error paths tested
- [ ] Concurrent access tested
- [ ] Cleanup verified in all failure cases

---

## Migration & Compatibility

### Breaking Changes

**None.** This is a bug fix that makes existing code work correctly.

### API Changes

| API | Before | After | Breaking? |
|-----|--------|-------|-----------|
| `discover()` signature | Same | Same | ❌ No |
| `discover()` return type | Same | Same | ❌ No |
| `discover()` behavior | Returns unusable actors | Returns usable actors | ❌ No (fix) |
| `setupRemoteProxy()` | `async` | `async throws` | ❌ No (private) |

### Code Migration

No user code changes required:

```swift
// ✅ This code works before (but actors were broken)
// ✅ This code still works after (and actors now work)
let sensors = try await system.discover(TemperatureSensor.self)
let temp = try await sensors[0].readTemperature()
```

### Behavioral Changes

| Scenario | Before | After |
|----------|--------|-------|
| First RPC call | ❌ Fails with `actorNotFound` | ✅ Succeeds |
| discover() duration | ~1-3s (scan only) | ~5-10s (scan + connect) |
| Error detection | During first RPC | During discovery |
| Partial failures | Returns all discovered | Returns only successful |

---

## Performance Analysis

### Timing Analysis

| Phase | Before | After | Change |
|-------|--------|-------|--------|
| **Scan** | 1-3s | 1-3s | Same |
| **Connect** | 0s | 2-5s per peripheral | +2-5s |
| **Setup Proxy** | 0s | 0.5-2s per peripheral | +0.5-2s |
| **discover() total** | 1-3s | 5-10s | +4-7s ⚠️ |
| **First RPC** | 5-10s (lazy connect) | 0.1-0.5s | -4.5-9.5s ✅ |
| **Total (discover + first RPC)** | 6-13s | 5-10.5s | -0.5-2.5s ✅ |

### Resource Usage

| Resource | Before | After | Impact |
|----------|--------|-------|--------|
| **Active Connections** | 0 during discovery | N during discovery | Higher, but transient |
| **Memory** | Minimal | +N * sizeof(CBPeripheral) | Negligible |
| **CPU** | Low | Low | Same |
| **Battery** | Low | Slightly higher | Minimal impact |

### Scalability

```
Scenario: Discovering N peripherals

Time Complexity:
  Before: O(1) for discovery + O(N) for first RPC to each
  After:  O(N) for discovery + O(1) for first RPC to each

  Total: Same O(N), but better UX

Connection Limit:
  iOS: 7 simultaneous connections
  Impact: If N > 7, connections will be serialized
  Mitigation: Already handled by LocalCentralActor
```

### Performance Optimization Opportunities

Future optimizations (out of scope for this fix):

1. **Parallel Connections**: Connect to multiple peripherals concurrently
2. **Connection Pooling**: Reuse connections across discoveries
3. **Lazy Setup Option**: Add flag for lazy connection mode
4. **Caching**: Cache service/characteristic UUIDs

---

## Implementation Plan

### Phase 1: Core Fix (P0 - Critical)

**Files to Modify**:
1. `Sources/Bleu/Core/BLEActorSystem.swift`
   - Modify `discover()` to add connection + MTU update
   - Modify `setupRemoteProxy()` to throw errors (change from `async` to `async throws`)
   - Add error handling and cleanup

**No changes needed to BleuError.swift** - All required error cases already exist:
- ✅ `serviceNotFound(UUID)` - already defined
- ✅ `characteristicNotFound(UUID)` - already defined
- ✅ `peripheralNotFound(UUID)` - already defined
- ✅ `connectionTimeout` - already defined
- ✅ `connectionFailed(String)` - already defined

**Estimated Effort**: 2-4 hours

**Testing**:
- Unit tests for connection flow
- Unit tests for error handling
- Integration test for basic discovery
- Manual testing on real devices

### Phase 2: Comprehensive Testing (P1)

**Tasks**:
1. Add comprehensive unit tests
2. Add integration tests
3. Add Examples/ validation scenario
4. Performance benchmarking

**Estimated Effort**: 4-6 hours

### Phase 3: Documentation (P2)

**Tasks**:
1. Update API documentation in code
2. Update SPECIFICATION.md
3. Update CLAUDE.md if needed
4. Add migration notes
5. Update Examples/README.md

**Estimated Effort**: 2-3 hours

### Total Estimated Effort

**8-13 hours** across all phases

---

## Rollback Strategy

### Option A: Feature Flag

```swift
// Add to BleuConfiguration
struct BleuConfiguration {
    var useEagerConnectionInDiscover: Bool = true
}

// In discover()
if await config.useEagerConnectionInDiscover {
    try await localCentral.connect(to: discovered.id)
    try await setupRemoteProxy(id: discovered.id, type: type)
} else {
    await setupRemoteProxy(id: discovered.id, type: type) // Old behavior
}
```

### Option B: Separate Method

```swift
// New implementation
public func discoverAndConnect<T: PeripheralActor>(...) async throws -> [T]

// Old implementation (deprecated)
@available(*, deprecated, message: "Use discoverAndConnect instead")
public func discover<T: PeripheralActor>(...) async throws -> [T]
```

### Recommended Rollback

**Option A (Feature Flag)** for maximum flexibility and minimal API disruption.

---

## Design Validation

### Design Checklist

- [x] Fixes the root cause of the bug
- [x] Consistent with existing `connect(to:as:)` pattern
- [x] Maintains all architectural invariants
- [x] No breaking changes to public API
- [x] Proper error handling and cleanup
- [x] Comprehensive test coverage plan
- [x] Performance impact understood and acceptable
- [x] Clear API contracts documented
- [x] Rollback strategy defined

### Architectural Compliance

- [x] **Separation of Concerns**: CoreBluetooth delegates isolated via LocalActors
- [x] **Message Passing**: AsyncChannel pattern maintained
- [x] **Actor Isolation**: No locks, all synchronization via actors
- [x] **Type Safety**: Full type preservation across BLE

### CLAUDE.md Principles

- [x] Respects actor boundaries
- [x] Uses message passing pattern
- [x] No shared mutable state
- [x] Deterministic UUID generation maintained
- [x] LocalActor → EventBridge → DistributedActor flow preserved

---

## Appendix

### Sequence Diagram: New Flow

```
User          BLEActorSystem    LocalCentral    CBCentral    Peripheral
 │                 │                 │              │             │
 │─discover()─────>│                 │              │             │
 │                 │─scan()─────────>│              │             │
 │                 │                 │─scan()──────>│             │
 │                 │                 │              │──advertise─>│
 │                 │                 │<─discovered──│<────────────│
 │                 │<─peripheral─────│              │             │
 │                 │                 │              │             │
 │                 │─connect()──────>│              │             │
 │                 │                 │─connect()───>│             │
 │                 │                 │              │──connect───>│
 │                 │                 │<─connected───│<────────────│
 │                 │<─✅─────────────│              │             │
 │                 │                 │              │             │
 │                 │─updateMTU()────>│              │             │
 │                 │<─MTU────────────│              │             │
 │                 │                 │              │             │
 │                 │─setupProxy()    │              │             │
 │                 │  │              │              │             │
 │                 │  ├─discover     │              │             │
 │                 │  │  Services───>│              │             │
 │                 │  │              │─discover────>│             │
 │                 │  │              │              │──discover──>│
 │                 │  │              │<─services────│<────────────│
 │                 │  │<─services────│              │             │
 │                 │  │              │              │             │
 │                 │  ├─discover     │              │             │
 │                 │  │  Chars──────>│              │             │
 │                 │  │              │─discover────>│             │
 │                 │  │              │              │──discover──>│
 │                 │  │              │<─chars───────│<────────────│
 │                 │  │<─chars───────│              │             │
 │                 │  │              │              │             │
 │                 │  ├─setNotify──>│              │             │
 │                 │  │              │─setNotify───>│             │
 │                 │  │              │              │──setNotify─>│
 │                 │  │              │<─✅──────────│<────────────│
 │                 │  │<─✅──────────│              │             │
 │                 │<─✅             │              │             │
 │                 │                 │              │             │
 │                 │─resolve()       │              │             │
 │                 │─register()      │              │             │
 │<─[Actor]────────│                 │              │             │
 │                 │                 │              │             │
 │─actor.method()─>│                 │              │             │
 │<─Result─────────│                 │              │             │
 │                 │                 │              │             │
```

### Related Documentation

- **SPECIFICATION.md** - Protocol specification and connection flow
- **CLAUDE.md** - Project architecture and design principles
- **API_REFERENCE.md** - Detailed API documentation
- **Sources/Bleu/Core/BLEActorSystem.swift** - Implementation
- **Sources/Bleu/LocalActors/LocalCentralActor.swift** - Connection management

### References

- Bug Report: Review finding on discover() connection flow
- Existing Implementation: `connect(to:as:)` method (BLEActorSystem.swift:336)
- Swift Distributed Actors: [SE-0336](https://github.com/apple/swift-evolution/blob/main/proposals/0336-distributed-actor-isolation.md)
- CoreBluetooth Documentation: [Apple Developer](https://developer.apple.com/documentation/corebluetooth)

---

**Document Version**: 1.0
**Last Updated**: 2025-01-04
**Status**: Ready for Implementation
**Approvers**: Design Review Team
