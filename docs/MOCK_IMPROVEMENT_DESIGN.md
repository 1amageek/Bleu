# Mock Implementation Improvement Design

## Document Version
- **Version**: 1.0
- **Date**: 2025-11-20
- **Status**: Draft for Review

## Executive Summary

This document outlines the design for improving `MockCentralManager` and `MockPeripheralManager` to more accurately simulate real CoreBluetooth behavior. The goal is to increase test fidelity and catch production issues that current mocks miss.

### Key Objectives

1. **Behavioral Accuracy**: Match CoreBluetooth's error handling, state management, and timing
2. **Test Coverage**: Enable testing of error scenarios and edge cases
3. **Backward Compatibility**: Maintain existing test compatibility where possible
4. **Configurability**: Allow tests to simulate various conditions
5. **Production Parity**: Reduce false positives (tests pass but production fails)

---

## Current State Analysis

### Critical Gaps Identified

| Category | Issue | Impact | Priority |
|----------|-------|--------|----------|
| State Management | Auto-transitions to `.poweredOn` | Misses authorization/power issues | **HIGH** |
| Connection | No timeout cancellation | Resource leak potential | **HIGH** |
| MTU | Fixed 512 bytes | Misses fragmentation issues | **HIGH** |
| Error Handling | No ATT error simulation | Misses error recovery bugs | **HIGH** |
| Write Operations | No type differentiation | Misses confirmation logic | **MEDIUM** |
| Queue Management | No queue full/retry | Misses buffer overflow | **MEDIUM** |
| Fragmentation | No BLETransport usage | Misses reassembly bugs | **HIGH** |
| Read Requests | Not implemented | Incomplete peripheral testing | **MEDIUM** |
| Subscription | No MTU updates | Misses MTU negotiation | **LOW** |
| Timing | Instant operations | Misses race conditions | **LOW** |

---

## Design Principles

### 1. Opt-In Realism
```swift
// Default: Fast, predictable (existing behavior)
let mock = MockCentralManager()

// Opt-in: Realistic behavior
var config = MockCentralManager.Configuration()
config.realisticBehavior = true
config.simulatedMTU = .realistic(min: 23, max: 512)
let mock = MockCentralManager(configuration: config)
```

### 2. Error Injection
```swift
var config = MockCentralManager.Configuration()
config.errorInjection = .enabled([
    .serviceDiscovery: .attError(.insufficientAuthentication),
    .writeOperation: .timeout,
    .notification: .queueFull
])
```

### 3. State Machine Fidelity
```swift
// Follow real CoreBluetooth state transitions
.unknown → .resetting → .poweredOff → .poweredOn
                     ↘ .unauthorized
                     ↘ .unsupported
```

---

## MockCentralManager Design

### Enhanced Configuration

```swift
public struct Configuration: Sendable {
    // MARK: - Existing Properties (unchanged)
    public var initialState: CBManagerState = .poweredOn
    public var skipWaitForPoweredOn: Bool = false
    public var scanDelay: TimeInterval = 0.1
    public var connectionDelay: TimeInterval = 0.1
    public var discoveryDelay: TimeInterval = 0.05
    public var shouldFailConnection: Bool = false
    public var connectionTimeout: Bool = false
    public var bridge: MockBLEBridge? = nil

    // MARK: - NEW: Behavioral Realism

    /// Enable realistic CoreBluetooth behavior (vs fast predictable mock)
    public var realisticBehavior: Bool = false

    /// State transition behavior
    public enum StateTransitionMode: Sendable {
        case instant                    // Current behavior: immediate
        case realistic(duration: TimeInterval)  // Simulates real state changes
        case stuck(CBManagerState)      // Never transitions from this state
    }
    public var stateTransition: StateTransitionMode = .instant

    /// MTU simulation mode
    public enum MTUMode: Sendable {
        case fixed(Int)                 // Current: always 512
        case realistic(min: Int, max: Int)  // Varies per connection
        case actual                     // Queries real device (testing only)
    }
    public var mtuMode: MTUMode = .fixed(512)

    /// Error injection configuration
    public struct ErrorInjection: Sendable {
        public var serviceDiscovery: Error? = nil
        public var characteristicDiscovery: Error? = nil
        public var readOperation: Error? = nil
        public var writeOperation: Error? = nil
        public var notificationSubscription: Error? = nil
        public var connectionFailureRate: Double = 0.0  // 0.0-1.0

        public static var none: ErrorInjection { ErrorInjection() }
        public static func random(failureRate: Double = 0.1) -> ErrorInjection {
            ErrorInjection(connectionFailureRate: failureRate)
        }
    }
    public var errorInjection: ErrorInjection = .none

    /// Connection behavior
    public var cancelConnectionOnTimeout: Bool = true  // NEW: Match real behavior

    /// Write operation behavior
    public var differentiateWriteTypes: Bool = true  // NEW: .withResponse vs .withoutResponse

    /// Fragmentation behavior
    public var useFragmentation: Bool = true  // NEW: Use BLETransport like real implementation

    public init() {}
}
```

### Key Behavioral Changes

#### 1. State Management

**Current (Incorrect)**:
```swift
func waitForPoweredOn() async -> CBManagerState {
    if _state != .poweredOn {
        _state = .poweredOn  // ❌ Always succeeds
    }
    return .poweredOn
}
```

**Proposed (Correct)**:
```swift
func waitForPoweredOn() async -> CBManagerState {
    switch config.stateTransition {
    case .instant:
        // Existing fast behavior for most tests
        if _state != .poweredOn {
            _state = .poweredOn
            await eventChannel.send(.stateChanged(.poweredOn))
        }
        return .poweredOn

    case .realistic(let duration):
        // Simulate real state transition timing
        if _state != .poweredOn {
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            if shouldTransitionToPoweredOn() {  // Can fail!
                _state = .poweredOn
                await eventChannel.send(.stateChanged(.poweredOn))
            }
        }
        return _state

    case .stuck(let state):
        // Never transitions - tests authorization failures
        _state = state
        return state
    }
}

private func shouldTransitionToPoweredOn() -> Bool {
    // Simulate possible failure scenarios
    switch _state {
    case .unauthorized, .unsupported:
        return false  // Cannot transition
    case .poweredOff, .resetting:
        return true   // Can transition
    default:
        return false
    }
}
```

#### 2. Connection Timeout with Cancellation

**Current (Incorrect)**:
```swift
func connect(to peripheralID: UUID, timeout: TimeInterval) async throws {
    if config.connectionTimeout {
        try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        throw BleuError.connectionTimeout  // ❌ No cancellation
    }
    // ...
}
```

**Proposed (Correct)**:
```swift
func connect(to peripheralID: UUID, timeout: TimeInterval) async throws {
    if config.connectionTimeout {
        try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))

        // ✅ Cancel connection before throwing (matches real CoreBluetooth)
        if config.cancelConnectionOnTimeout {
            pendingConnections.remove(peripheralID)
            await eventChannel.send(.peripheralDisconnected(peripheralID, BleuError.connectionTimeout))
        }

        throw BleuError.connectionTimeout
    }

    // Track pending connection
    pendingConnections.insert(peripheralID)

    // ... existing connection logic ...

    // Remove from pending on success
    pendingConnections.remove(peripheralID)
}

private var pendingConnections: Set<UUID> = []  // NEW: Track pending connections
```

#### 3. MTU Variation

**Current (Incorrect)**:
```swift
func maximumWriteValueLength(for peripheralID: UUID, type: CBCharacteristicWriteType) async -> Int? {
    return 512  // ❌ Always same value
}
```

**Proposed (Correct)**:
```swift
func maximumWriteValueLength(for peripheralID: UUID, type: CBCharacteristicWriteType) async -> Int? {
    guard connectedPeripherals.contains(peripheralID) else {
        return nil
    }

    switch config.mtuMode {
    case .fixed(let value):
        return value

    case .realistic(let min, let max):
        // Vary MTU per peripheral (simulates different devices)
        if let cached = peripheralMTU[peripheralID] {
            return cached
        }

        // Common real-world MTU values: 23, 27, 158, 185, 247, 251, 512
        let realisticValues = [23, 27, 158, 185, 247, 251, 512].filter { $0 >= min && $0 <= max }
        let mtu = realisticValues.randomElement() ?? min
        peripheralMTU[peripheralID] = mtu
        return mtu

    case .actual:
        // For testing: could query real device MTU
        return 185  // iOS default
    }
}

private var peripheralMTU: [UUID: Int] = [:]  // NEW: Cache per peripheral
```

#### 4. Error Injection

**Current (Incorrect)**:
```swift
func discoverServices(for peripheralID: UUID, serviceUUIDs: [UUID]?) async throws -> [ServiceMetadata] {
    // ... always succeeds ...
    return services  // ❌ No error scenarios
}
```

**Proposed (Correct)**:
```swift
func discoverServices(for peripheralID: UUID, serviceUUIDs: [UUID]?) async throws -> [ServiceMetadata] {
    guard connectedPeripherals.contains(peripheralID) else {
        throw BleuError.peripheralNotFound(peripheralID)
    }

    // ✅ Error injection
    if let error = config.errorInjection.serviceDiscovery {
        if config.discoveryDelay > 0 {
            try await Task.sleep(nanoseconds: UInt64(config.discoveryDelay * 1_000_000_000))
        }
        throw error
    }

    // Random failure simulation
    if config.errorInjection.connectionFailureRate > 0 {
        if Double.random(in: 0...1) < config.errorInjection.connectionFailureRate {
            throw BleuError.operationFailed("Random discovery failure")
        }
    }

    // ... existing success path ...
}
```

#### 5. Write Type Differentiation

**Current (Incorrect)**:
```swift
func writeValue(_ data: Data, for characteristicUUID: UUID, in peripheralID: UUID, type: CBCharacteristicWriteType) async throws {
    // ... same handling for both types ...  ❌
}
```

**Proposed (Correct)**:
```swift
func writeValue(_ data: Data, for characteristicUUID: UUID, in peripheralID: UUID, type: CBCharacteristicWriteType) async throws {
    guard connectedPeripherals.contains(peripheralID) else {
        throw BleuError.peripheralNotFound(peripheralID)
    }

    if config.differentiateWriteTypes {
        switch type {
        case .withResponse:
            // ✅ Simulate confirmation wait
            if let error = config.errorInjection.writeOperation {
                throw error
            }

            // Store and wait for confirmation (simulate real behavior)
            try await withCheckedThrowingContinuation { continuation in
                Task {
                    // Simulate confirmation delay
                    try? await Task.sleep(nanoseconds: 10_000_000)  // 10ms

                    // Store the value
                    if characteristicValues[peripheralID] == nil {
                        characteristicValues[peripheralID] = [:]
                    }
                    characteristicValues[peripheralID]?[characteristicUUID] = data

                    continuation.resume()
                }
            }

        case .withoutResponse:
            // ✅ No wait, just store (matches real behavior)
            if characteristicValues[peripheralID] == nil {
                characteristicValues[peripheralID] = [:]
            }
            characteristicValues[peripheralID]?[characteristicUUID] = data

        @unknown default:
            throw BleuError.operationNotSupported
        }
    } else {
        // Existing behavior for backward compatibility
        if characteristicValues[peripheralID] == nil {
            characteristicValues[peripheralID] = [:]
        }
        characteristicValues[peripheralID]?[characteristicUUID] = data
    }

    // Forward to bridge if enabled
    if config.useBridge, let bridge = config.bridge {
        try await bridge.centralWrite(
            from: centralID,
            to: peripheralID,
            characteristicUUID: characteristicUUID,
            value: data
        )
    }
}
```

#### 6. Fragmentation Support

**Current (Incorrect)**:
```swift
// No fragmentation - sends data directly  ❌
```

**Proposed (Correct)**:
```swift
func writeValue(_ data: Data, for characteristicUUID: UUID, in peripheralID: UUID, type: CBCharacteristicWriteType) async throws {
    // ... validation ...

    if config.useFragmentation && data.count > 20 {
        // ✅ Use BLETransport like real implementation
        let transport = BLETransport.shared
        let packets = transport.fragment(data, for: peripheralID)

        for packet in packets {
            let packetData = transport.pack(packet)

            // Send each packet
            if config.useBridge, let bridge = config.bridge {
                try await bridge.centralWrite(
                    from: centralID,
                    to: peripheralID,
                    characteristicUUID: characteristicUUID,
                    value: packetData
                )
            } else {
                // Store locally
                if characteristicValues[peripheralID] == nil {
                    characteristicValues[peripheralID] = [:]
                }
                // For fragmentation, only final packet updates value
                if packet.sequenceNumber == packet.totalPackets - 1 {
                    characteristicValues[peripheralID]?[characteristicUUID] = data
                }
            }
        }
    } else {
        // Small data - send directly
        // ... existing logic ...
    }
}
```

---

## MockPeripheralManager Design

### Enhanced Configuration

```swift
public struct Configuration: Sendable {
    // MARK: - Existing Properties (unchanged)
    public var initialState: CBManagerState = .poweredOn
    public var skipWaitForPoweredOn: Bool = false
    public var shouldFailServiceAdd: Bool = false
    public var shouldFailAdvertising: Bool = false
    public var writeResponseDelay: TimeInterval = 0.0
    public var bridge: MockBLEBridge? = nil

    // MARK: - NEW: Behavioral Realism

    /// Enable realistic CoreBluetooth behavior
    public var realisticBehavior: Bool = false

    /// State transition behavior (same as MockCentralManager)
    public var stateTransition: StateTransitionMode = .instant

    /// UpdateValue queue behavior
    public enum QueueBehavior: Sendable {
        case infinite              // Current: never fails
        case realistic(capacity: Int, retries: Int)  // Matches real queue behavior
    }
    public var queueBehavior: QueueBehavior = .infinite

    /// Error injection
    public struct ErrorInjection: Sendable {
        public var serviceAddition: Error? = nil
        public var advertisingStart: Error? = nil
        public var updateValue: Error? = nil
        public var queueFullProbability: Double = 0.0  // 0.0-1.0

        public static var none: ErrorInjection { ErrorInjection() }
    }
    public var errorInjection: ErrorInjection = .none

    /// Subscription MTU updates (match real behavior)
    public var updateMTUOnSubscription: Bool = true

    /// Read request support
    public var supportReadRequests: Bool = true

    /// Fragmentation support
    public var useFragmentation: Bool = true

    public init() {}
}
```

### Key Behavioral Changes

#### 1. Queue Full Simulation

**Current (Incorrect)**:
```swift
func updateValue(_ data: Data, for characteristicUUID: UUID, to centrals: [UUID]?) async throws -> Bool {
    // ... always succeeds ...
    return true  // ❌ Never queue full
}
```

**Proposed (Correct)**:
```swift
func updateValue(_ data: Data, for characteristicUUID: UUID, to centrals: [UUID]?) async throws -> Bool {
    // ... validation ...

    switch config.queueBehavior {
    case .infinite:
        // Existing behavior: always succeeds
        // ... send notification ...
        return true

    case .realistic(let capacity, let maxRetries):
        // ✅ Simulate queue behavior
        var retries = 0

        while retries < maxRetries {
            // Check if queue is full (random simulation)
            let queueFullChance = config.errorInjection.queueFullProbability
            let isQueueFull = Double.random(in: 0...1) < queueFullChance

            if !isQueueFull {
                // Queue has space - send notification
                // ... send notification ...
                return true
            }

            // Queue full - wait and retry (matches real CoreBluetooth)
            retries += 1
            if retries < maxRetries {
                try await Task.sleep(nanoseconds: 10_000_000)  // 10ms between retries
            }
        }

        // Max retries exhausted
        if let error = config.errorInjection.updateValue {
            throw error
        }
        return false  // Indicates queue still full
    }
}
```

#### 2. Subscription MTU Updates

**Current (Incorrect)**:
```swift
func simulateSubscription(central: UUID, to characteristic: UUID) async {
    // ... just updates subscription state ...  ❌
}
```

**Proposed (Correct)**:
```swift
func simulateSubscription(central: UUID, to characteristic: UUID) async {
    var centrals = subscribedCentrals[characteristic] ?? []
    centrals.insert(central)
    subscribedCentrals[characteristic] = centrals

    // ✅ Update MTU like real CoreBluetoothPeripheralManager
    if config.updateMTUOnSubscription {
        // Get realistic MTU for this central (varies by device)
        let mtu: Int
        switch config.realisticBehavior {
        case true:
            // Realistic variation
            let realisticMTUs = [23, 27, 158, 185, 247, 251, 512]
            mtu = realisticMTUs.randomElement() ?? 185
        case false:
            // Fast/predictable
            mtu = 512
        }

        // Register with BLETransport
        await BLETransport.shared.updateMaxPayloadSize(for: central, maxWriteLength: mtu)
    }

    await eventChannel.send(.centralSubscribed(central, UUID(), characteristic))
}

func simulateUnsubscription(central: UUID, from characteristic: UUID) async {
    subscribedCentrals[characteristic]?.remove(central)

    // ✅ Remove MTU like real implementation
    if config.updateMTUOnSubscription {
        await BLETransport.shared.removeMTU(for: central)
    }

    await eventChannel.send(.centralUnsubscribed(central, UUID(), characteristic))
}
```

#### 3. Read Request Handling

**Current**: Not implemented

**Proposed (New)**:
```swift
/// Simulate a read request from a central
/// - Parameters:
///   - central: Central UUID requesting the read
///   - characteristic: Characteristic UUID being read
///   - offset: Byte offset for read (0 for complete read)
/// - Returns: Data at the characteristic, or throws ATT error
public func simulateReadRequest(
    from central: UUID,
    for characteristic: UUID,
    offset: Int = 0
) async throws -> Data {
    guard config.supportReadRequests else {
        throw BleuError.operationNotSupported
    }

    // Get characteristic value
    guard let value = characteristicValues[characteristic] else {
        // No value set - return ATT error
        let error = NSError(
            domain: CBATTErrorDomain,
            code: CBATTError.readNotPermitted.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "Characteristic has no value"]
        )
        throw error
    }

    // Validate offset
    guard offset >= 0 && offset < value.count else {
        let error = NSError(
            domain: CBATTErrorDomain,
            code: CBATTError.invalidOffset.rawValue,
            userInfo: [NSLocalizedDescriptionKey: "Invalid offset \(offset)"]
        )
        throw error
    }

    // Return value from offset
    let result = value[offset...]

    // Send event
    await eventChannel.send(.readRequestReceived(central, UUID(), characteristic, Data(result)))

    return Data(result)
}
```

#### 4. Service Addition State Validation

**Current (Incorrect)**:
```swift
func add(_ service: ServiceMetadata) async throws {
    if config.shouldFailServiceAdd {
        throw BleuError.operationNotSupported
    }
    // ... always succeeds otherwise ...  ❌
}
```

**Proposed (Correct)**:
```swift
func add(_ service: ServiceMetadata) async throws {
    // ✅ Validate state (matches real CoreBluetooth)
    if config.realisticBehavior {
        guard _state == .poweredOn else {
            throw BleuError.bluetoothPoweredOff
        }
    }

    // Error injection
    if let error = config.errorInjection.serviceAddition {
        throw error
    }

    // Simple flag for backward compatibility
    if config.shouldFailServiceAdd {
        throw BleuError.operationNotSupported
    }

    // ... success path ...
}
```

---

## Implementation Plan

### Phase 1: Foundation (Week 1)
- [ ] Add enhanced `Configuration` structs to both mocks
- [ ] Implement state transition modes
- [ ] Add error injection infrastructure
- [ ] Update existing tests to use explicit configs (ensure backward compatibility)

### Phase 2: Critical Behaviors (Week 2)
- [ ] Implement MTU variation
- [ ] Add connection timeout cancellation
- [ ] Implement write type differentiation
- [ ] Add queue full simulation
- [ ] Implement fragmentation support

### Phase 3: Advanced Features (Week 3)
- [ ] Add read request handling
- [ ] Implement subscription MTU updates
- [ ] Add service/characteristic validation
- [ ] Implement realistic timing variations

### Phase 4: Testing & Documentation (Week 4)
- [ ] Write tests for new behaviors
- [ ] Update existing tests to leverage new features
- [ ] Document migration guide for existing tests
- [ ] Performance testing of realistic mode

---

## Testing Strategy

### Backward Compatibility Tests

```swift
@Test("Existing tests work unchanged")
func testBackwardCompatibility() async throws {
    // Default config should preserve existing behavior
    let mock = MockCentralManager()

    // Fast, predictable behavior
    let state = await mock.waitForPoweredOn()
    #expect(state == .poweredOn)

    // Instant operations
    let peripheral = DiscoveredPeripheral(id: UUID(), name: "Test", rssi: -50, advertisementData: AdvertisementData())
    await mock.registerPeripheral(peripheral, services: [])

    try await mock.connect(to: peripheral.id, timeout: 1.0)
    #expect(await mock.isConnected(peripheral.id))
}
```

### Realistic Behavior Tests

```swift
@Test("Realistic mode catches authorization issues")
func testRealisticStateTransitions() async throws {
    var config = MockCentralManager.Configuration()
    config.stateTransition = .stuck(.unauthorized)

    let mock = MockCentralManager(configuration: config)

    // Should NOT auto-transition
    let state = await mock.waitForPoweredOn()
    #expect(state == .unauthorized)
}

@Test("Realistic MTU causes fragmentation")
func testRealisticMTU() async throws {
    var config = MockCentralManager.Configuration()
    config.mtuMode = .realistic(min: 23, max: 27)
    config.useFragmentation = true

    let mock = MockCentralManager(configuration: config)
    // ... setup ...

    // Large data should fragment with small MTU
    let largeData = Data(repeating: 0xFF, count: 200)
    try await mock.writeValue(largeData, for: charUUID, in: peripheralID, type: .withResponse)

    // Verify fragmentation occurred (multiple writes)
}

@Test("Error injection works")
func testErrorInjection() async throws {
    var config = MockCentralManager.Configuration()
    config.errorInjection.serviceDiscovery = BleuError.operationFailed("Simulated error")

    let mock = MockCentralManager(configuration: config)
    // ... setup ...

    // Should throw injected error
    do {
        _ = try await mock.discoverServices(for: peripheralID, serviceUUIDs: nil)
        Issue.record("Should have thrown error")
    } catch {
        #expect(error is BleuError)
    }
}
```

---

## Migration Guide

### For Existing Tests (No Changes Required)

```swift
// ✅ This continues to work as before
let mock = MockCentralManager()
```

### For New Tests (Opt Into Realism)

```swift
// New: Enable realistic behavior
var config = MockCentralManager.Configuration()
config.realisticBehavior = true
config.mtuMode = .realistic(min: 23, max: 512)
config.stateTransition = .realistic(duration: 0.5)

let mock = MockCentralManager(configuration: config)
```

### For Error Scenario Tests

```swift
// New: Test error handling
var config = MockCentralManager.Configuration()
config.errorInjection.serviceDiscovery = BleuError.attError(.insufficientAuthentication)

let mock = MockCentralManager(configuration: config)
// Test should now verify error handling
```

---

## Performance Considerations

### Fast Mode (Default)
- **No change** from current performance
- Instant operations
- Predictable timing
- Best for unit tests

### Realistic Mode (Opt-In)
- Adds 10-500ms delays (configurable)
- Varies MTU per connection
- Random error injection
- Best for integration tests

### Recommendation
- Use **fast mode** for 90% of tests (unit tests, regression tests)
- Use **realistic mode** for 10% of tests (integration tests, error scenarios)

---

## Success Metrics

### Before Implementation
- **Mock/Real Parity**: ~60% (many behaviors missing)
- **False Positive Rate**: High (tests pass but prod fails)
- **Error Coverage**: ~30% (limited error scenarios)

### After Implementation (Goals)
- **Mock/Real Parity**: ~95% (matches critical behaviors)
- **False Positive Rate**: Low (catches most prod issues)
- **Error Coverage**: ~90% (comprehensive error testing)

### Measurable Outcomes
1. **At least 20 new error scenario tests** pass
2. **Zero regressions** in existing test suite
3. **<5% performance impact** in fast mode
4. **Production issues caught in tests** increases by 80%

---

## Open Questions

1. **Timing Realism**: How realistic should timing be? Too realistic = slow tests
2. **Random vs Deterministic**: Should error injection be random or controlled?
3. **iOS vs macOS**: Should we differentiate behavior by platform?
4. **BLE Version**: Should we simulate BLE 4.0 vs 5.0 differences?

---

## Appendix: Real CoreBluetooth Behaviors

### State Transitions (Real)
```
.unknown (initial)
  ↓ (auto)
.resetting (brief)
  ↓
.poweredOff (if BT disabled)
.unauthorized (if no permission)
.unsupported (if no BT hardware)
.poweredOn (if BT enabled & authorized)
```

### MTU Values (Real)
| Device | Typical MTU |
|--------|-------------|
| iPhone 6s+ | 185 bytes |
| iPhone 12+ | 247 bytes |
| iPad Pro | 512 bytes |
| BLE 4.0 Min | 23 bytes |
| BLE 5.0 Max | 251 bytes |

### Error Codes (Real CBATTError)
- `.invalidHandle` (0x01)
- `.readNotPermitted` (0x02)
- `.writeNotPermitted` (0x03)
- `.invalidPdu` (0x04)
- `.insufficientAuthentication` (0x05)
- `.requestNotSupported` (0x06)
- `.invalidOffset` (0x07)
- `.insufficientAuthorization` (0x08)
- `.prepareQueueFull` (0x09)
- `.attributeNotFound` (0x0A)
- `.attributeNotLong` (0x0B)
- `.insufficientEncryptionKeySize` (0x0C)
- `.invalidAttributeValueLength` (0x0D)
- `.unlikelyError` (0x0E)
- `.insufficientEncryption` (0x0F)
- `.unsupportedGroupType` (0x10)
- `.insufficientResources` (0x11)

---

## References

- [CoreBluetooth Documentation](https://developer.apple.com/documentation/corebluetooth)
- [Bluetooth Core Specification](https://www.bluetooth.com/specifications/specs/)
- [BLE MTU Negotiation](https://punchthrough.com/maximizing-ble-throughput-part-2-use-larger-att-mtu-2/)
- [ATT Error Codes](https://www.bluetooth.com/specifications/specs/core-specification-5-3/)
