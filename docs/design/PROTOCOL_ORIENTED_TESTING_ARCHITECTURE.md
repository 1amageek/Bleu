# Protocol-Oriented Testing Architecture Design Document

**Status**: Proposed
**Priority**: P0 - Critical
**Created**: 2025-11-04
**Author**: Design Review Team
**Target Release**: Bleu 2.1

---

## Executive Summary

This document proposes a comprehensive refactoring of Bleu 2's BLE management layer using Protocol-Oriented Programming and Dependency Injection to solve the TCC (Transparency, Consent, and Control) privacy violation crashes during `swift test` execution, while simultaneously improving the overall architecture and testability of the framework.

**Key Deliverables:**
- Protocol abstraction layer for BLE operations
- Mock implementations for hardware-free testing
- Dependency injection in BLEActorSystem
- Reorganized test architecture
- 100% backward compatibility

---

## Table of Contents

1. [Background](#1-background)
2. [Current Architecture Analysis](#2-current-architecture-analysis)
3. [Design Goals](#3-design-goals)
4. [Proposed Solution](#4-proposed-solution)
5. [Detailed Design](#5-detailed-design)
6. [Implementation Plan](#6-implementation-plan)
7. [Migration Guide](#7-migration-guide)
8. [Alternatives Considered](#8-alternatives-considered)
9. [Risks and Mitigation](#9-risks-and-mitigation)
10. [Future Enhancements](#10-future-enhancements)
11. [Success Metrics](#11-success-metrics)
12. [Conclusion](#12-conclusion)
13. [Appendices](#appendices)

---

## 1. Background

### 1.1 Current Problem

When running `swift test`, the test suite crashes immediately with a TCC privacy violation:

```
This app has crashed because it attempted to access privacy-sensitive data without a usage description.
The app's Info.plist must contain an NSBluetoothAlwaysUsageDescription key with a string value
explaining to the user how the app uses this data.

Thread 18 Queue : com.apple.root.default-qos (concurrent)
#3    0x000000019a9ced98 in __TCC_CRASHING_DUE_TO_PRIVACY_VIOLATION__
#4    0x000000019a9cf6e0 in __TCCAccessRequest_block_invoke.225
```

This prevents any testing of the Bleu framework using `swift test`.

### 1.2 Root Cause Analysis

#### Why Swift Package Manager Test Targets Can't Have Info.plist

1. **SPM Design Philosophy**

   Swift Package Manager intentionally does not support Info.plist files in test targets. This is a fundamental architectural decision, not an oversight.

2. **Test Target Architecture**

   SPM test targets compile as standalone executables (e.g., `BleuPackageTests.xctest`), not as app bundles. Info.plist is a bundle resource specific to macOS/iOS app bundles and doesn't translate to SPM's cross-platform model.

3. **Cross-Platform Concerns**

   SPM aims to be cross-platform (macOS, Linux, Windows). Info.plist is an Apple-specific concept that doesn't exist on other platforms. Supporting it would break SPM's platform-agnostic design.

4. **Workaround Limitations**

   While you can create an Xcode project wrapper with Info.plist, this:
   - Defeats SPM's purpose of providing a pure Swift build system
   - Creates dependency on Xcode tooling
   - Doesn't work on Linux/Windows
   - Adds complexity for contributors

#### The Real Issue: Tight Coupling to CoreBluetooth

The current implementation directly instantiates `CBPeripheralManager` and `CBCentralManager` during actor initialization:

```swift
// From LocalPeripheralActor.swift:22-25
public func initialize() {
    delegateProxy = PeripheralManagerDelegateProxy(actor: self)
    peripheralManager = CBPeripheralManager(
        delegate: delegateProxy,
        queue: nil
    )  // ← TCC violation occurs HERE
}

// From LocalCentralActor.swift:44-47
public func initialize() {
    delegateProxy = CentralManagerDelegateProxy(actor: self)
    centralManager = CBCentralManager(
        delegate: delegateProxy,
        queue: nil
    )  // ← TCC violation occurs HERE
}
```

Creating these CoreBluetooth managers **immediately** triggers macOS/iOS privacy checks for Bluetooth access. These checks:
- Require Info.plist entries (`NSBluetoothAlwaysUsageDescription`)
- Cannot be deferred or avoided when using real CoreBluetooth classes
- Cause instant crash if privacy declarations are missing

### 1.3 Why This is an Architectural Issue

This reveals deeper architectural problems beyond just testing:

1. **Tight Coupling**
   - `BLEActorSystem` is directly coupled to CoreBluetooth concrete types
   - No abstraction layer between business logic and platform code
   - Hard dependency on Apple's frameworks

2. **No Testability**
   - Cannot unit test distributed actor logic without BLE hardware
   - Cannot mock BLE behavior for edge case testing
   - Cannot simulate connection failures, timeouts, errors

3. **Platform Lock-in**
   - Hard dependency on CoreBluetooth prevents Linux/Windows support
   - Cannot implement alternative BLE stacks (BlueZ on Linux)
   - Limits future portability

4. **Development Friction**
   - Developers must grant Bluetooth permissions just to run tests
   - Tests require physical BLE hardware
   - Slow test iteration cycles

5. **Poor Separation of Concerns**
   - Business logic mixed with platform-specific code
   - Difficult to understand what code does vs. how it communicates

### 1.4 Impact on Development Workflow

**Current State (Broken):**
- ❌ Cannot run `swift test` without TCC crash
- ❌ Cannot test BLE logic in CI/CD (no Bluetooth hardware)
- ❌ Cannot develop/test without Bluetooth permissions
- ❌ Cannot simulate BLE scenarios (connection failures, edge cases)
- ❌ Test suite requires physical BLE hardware
- ❌ Slow test cycles (minutes instead of seconds)

**Desired State (After Refactoring):**
- ✅ `swift test` runs without BLE permissions
- ✅ Fast unit tests with mock BLE implementation (<10s for full suite)
- ✅ Separate integration tests for real hardware
- ✅ CI/CD friendly test execution
- ✅ Comprehensive test coverage of edge cases
- ✅ Rapid development iteration

---

## 2. Current Architecture Analysis

### 2.1 BLEActorSystem Initialization Flow

```swift
// From BLEActorSystem.swift:67-77
public init() {
    // Step 1: Create local actors with hardcoded types
    self.localPeripheral = LocalPeripheralActor()
    self.localCentral = LocalCentralActor()

    Task {
        // Step 2: Initialize peripheral (creates CBPeripheralManager → TCC!)
        await localPeripheral.initialize()

        // Step 3: Initialize central (creates CBCentralManager → TCC!)
        await localCentral.initialize()

        await setupEventHandlers()
        await bootstrap.markReady()
    }
}
```

**Critical Problem**: Lines 72-73 create real CoreBluetooth managers, triggering TCC checks. There's no way to inject alternative implementations or defer hardware access.

### 2.2 Dependency Graph

```
BLEActorSystem (Singleton)
    │
    ├─► LocalPeripheralActor
    │       ├─► CBPeripheralManager ← TCC VIOLATION!
    │       └─► PeripheralManagerDelegateProxy
    │
    ├─► LocalCentralActor
    │       ├─► CBCentralManager ← TCC VIOLATION!
    │       └─► CentralManagerDelegateProxy
    │
    ├─► EventBridge (Singleton)
    ├─► InstanceRegistry (Singleton)
    ├─► MethodRegistry (Singleton)
    └─► BLETransport (Singleton)
```

**Observations:**
1. Direct instantiation of CoreBluetooth managers at initialization
2. No interface/protocol abstraction
3. Singleton pattern prevents multiple instances with different configurations
4. Cannot inject test doubles or mock implementations
5. Circular dependencies through singletons

### 2.3 Coupling Analysis

**LocalPeripheralActor Responsibilities:**

Good (✅):
- Manages service setup
- Handles advertising
- Processes write requests
- Event stream generation

Bad (❌):
- **Tightly coupled to CBPeripheralManager**
- **Cannot be tested without BLE hardware**
- **Mixes business logic with platform code**

**LocalCentralActor Responsibilities:**

Good (✅):
- Manages scanning
- Handles connections
- Processes characteristic operations
- Connection state tracking

Bad (❌):
- **Tightly coupled to CBCentralManager**
- **Cannot be tested without BLE**
- **Cannot simulate BLE errors**

### 2.4 Current Limitations

1. **Zero Testability**
   - Cannot unit test without BLE hardware and TCC permissions
   - Cannot test error conditions reliably
   - Cannot test race conditions or edge cases
   - No way to mock BLE behavior

2. **No Simulation**
   - Cannot simulate connection failures
   - Cannot simulate timeout scenarios
   - Cannot simulate low signal strength
   - Cannot test recovery mechanisms

3. **Platform Lock-in**
   - Locked to Apple platforms via CoreBluetooth
   - Cannot support Linux (BlueZ)
   - Cannot support Windows
   - Hard to add alternative BLE stacks

4. **Poor Separation**
   - Business logic mixed with CoreBluetooth-specific code
   - Hard to understand what code does vs. how it does it
   - Difficult to refactor or optimize

5. **Development Pain**
   - Must grant Bluetooth permissions to run tests
   - Need physical BLE devices for integration testing
   - Long test iteration cycles
   - CI/CD cannot run tests

---

## 3. Design Goals

### 3.1 Primary Goals (MUST HAVE)

1. **Fix TCC Crash**
   - Enable `swift test` to run without TCC permissions
   - Tests execute successfully without Info.plist

2. **Enable Hardware-Free Testing**
   - Unit test distributed actor logic without BLE
   - Mock BLE behavior for comprehensive testing
   - Fast test execution (<10 seconds for full suite)

3. **Maintain Backward Compatibility**
   - 100% backward compatible public API
   - Zero changes required for existing code
   - No breaking changes for framework users

4. **Production Parity**
   - Mock behavior matches real BLE as closely as possible
   - Same code paths in tests and production
   - No test-only code branches

### 3.2 Secondary Goals (SHOULD HAVE)

1. **Improve Architecture**
   - Proper separation of concerns
   - Clear abstraction layers
   - Protocol-oriented design

2. **Comprehensive Testing**
   - Test edge cases and error conditions
   - Test timeout scenarios
   - Test connection failures
   - Test race conditions

3. **CI/CD Support**
   - Tests run in any environment
   - No BLE hardware required
   - Fast, reliable test execution

4. **Better Organization**
   - Clear separation between platform and business code
   - Well-organized test structure
   - Easy to understand and maintain

### 3.3 Tertiary Goals (NICE TO HAVE)

1. **Development Experience**
   - BLE scenario simulation for development
   - Multiple BLE implementations (real, mock, simulator)
   - Performance testing with controlled behavior
   - Better debugging capabilities

2. **Future-Proofing**
   - Foundation for cross-platform support
   - Support for alternative BLE stacks
   - Extensibility for new features

### 3.4 Non-Goals (OUT OF SCOPE)

1. ❌ **Cross-Platform Implementation** - Foundation only, not actual Linux/Windows support
2. ❌ **Public API Changes** - Maintain exact compatibility
3. ❌ **Performance Optimization** - Not the focus
4. ❌ **New BLE Features** - Architecture only
5. ❌ **Removing Singletons** - Backward compatibility constraint

---

## 4. Proposed Solution

### 4.1 Protocol-Oriented Programming Approach

**Core Principle**: "Program to an interface, not an implementation" (Gang of Four, Design Patterns)

We introduce protocol abstractions between `BLEActorSystem` and CoreBluetooth, enabling dependency injection of different implementations (real vs. mock) while maintaining identical behavior.

### 4.2 Architectural Layers

```
┌────────────────────────────────────────────────────┐
│  Public API (BLEActorSystem)                       │
│  - Unchanged public interface                      │
│  - Factory methods for production/testing          │
│  - Backward compatible singleton                   │
└────────────────┬───────────────────────────────────┘
                 │ depends on (protocols)
┌────────────────▼───────────────────────────────────┐
│  Protocol Layer (NEW)                              │
│  - BLECentralManagerProtocol                       │
│  - BLEPeripheralManagerProtocol                    │
│  - Clear contracts for BLE operations              │
└────────────────┬───────────────────────────────────┘
                 │ implemented by
        ┌────────┴────────┐
        │                 │
┌───────▼──────┐   ┌──────▼────────┐
│ Production   │   │ Mock          │
│ CBWrapper    │   │ Implementations│
│ (Real BLE)   │   │ (Testing)     │
│ - TCC req    │   │ - No TCC      │
│ - Hardware   │   │ - In-memory   │
└──────────────┘   └───────────────┘
```

### 4.3 Dependency Injection Pattern

**Current (Direct Instantiation - Bad):**
```swift
class BLEActorSystem {
    // Fixed dependencies - cannot change or test
    private let localPeripheral = LocalPeripheralActor()
    private let localCentral = LocalCentralActor()
}
```

**Proposed (Dependency Injection - Good):**
```swift
class BLEActorSystem {
    // Injected dependencies - flexible and testable
    private let peripheralManager: BLEPeripheralManagerProtocol
    private let centralManager: BLECentralManagerProtocol

    init(
        peripheralManager: BLEPeripheralManagerProtocol,
        centralManager: BLECentralManagerProtocol
    ) {
        self.peripheralManager = peripheralManager
        self.centralManager = centralManager
    }
}
```

### 4.4 Factory Method Pattern

```swift
extension BLEActorSystem {
    /// Production: Real CoreBluetooth (requires TCC permissions)
    public static func production() -> BLEActorSystem {
        let peripheral = CoreBluetoothPeripheralManager()
        let central = CoreBluetoothCentralManager()

        Task {
            await peripheral.initialize()  // TCC check happens here
            await central.initialize()     // TCC check happens here
        }

        return BLEActorSystem(
            peripheralManager: peripheral,
            centralManager: central
        )
    }

    /// Testing: Mock implementation (no TCC, no hardware)
    public static func mock(
        peripheralConfig: MockPeripheralManager.Configuration = .init(),
        centralConfig: MockCentralManager.Configuration = .init()
    ) -> BLEActorSystem {
        return BLEActorSystem(
            peripheralManager: MockPeripheralManager(configuration: peripheralConfig),
            centralManager: MockCentralManager(configuration: centralConfig)
        )
    }

    /// Backward compatibility: shared singleton uses production
    public static let shared: BLEActorSystem = .production()
}
```

---

## 5. Detailed Design

### 5.1 Protocol Definitions

#### 5.1.1 BLEPeripheralManagerProtocol

```swift
/// Protocol abstracting CBPeripheralManager operations
/// Conforming types must be actors for thread-safety
public protocol BLEPeripheralManagerProtocol: Actor {

    // MARK: - Event Stream

    /// Async stream of BLE events from peripheral manager
    var events: AsyncStream<BLEEvent> { get }

    // MARK: - State Management

    /// Current Bluetooth state
    var state: CBManagerState { get async }

    /// Initialize the peripheral manager
    /// - Note: For CoreBluetooth implementations, creates CBPeripheralManager (triggers TCC)
    ///   For mock implementations, this is typically a no-op
    func initialize() async

    /// Wait until Bluetooth is powered on
    /// - Returns: Final state (should be .poweredOn)
    func waitForPoweredOn() async -> CBManagerState

    // MARK: - Service Management

    /// Add a service to the peripheral
    /// - Parameter service: Service metadata to add
    /// - Throws: BleuError if service cannot be added
    func add(_ service: ServiceMetadata) async throws

    // MARK: - Advertising

    /// Start advertising with given data
    /// - Parameter data: Advertisement data to broadcast
    /// - Throws: BleuError if advertising fails to start
    func startAdvertising(_ data: AdvertisementData) async throws

    /// Stop advertising
    func stopAdvertising() async

    /// Check if currently advertising
    var isAdvertising: Bool { get async }

    // MARK: - Characteristic Updates

    /// Update characteristic value and notify subscribed centrals
    /// - Parameters:
    ///   - data: New value for the characteristic
    ///   - characteristicUUID: UUID of the characteristic
    ///   - centrals: Optional list of specific centrals to notify (nil = all)
    /// - Returns: true if update was sent successfully
    /// - Throws: BleuError if update fails
    func updateValue(
        _ data: Data,
        for characteristicUUID: UUID,
        to centrals: [UUID]?
    ) async throws -> Bool

    // MARK: - Subscription Management

    /// Get list of centrals subscribed to a characteristic
    /// - Parameter characteristicUUID: UUID of the characteristic
    /// - Returns: Array of subscribed central UUIDs
    func subscribedCentrals(for characteristicUUID: UUID) async -> [UUID]
}
```

**Design Rationale:**

1. **Actor Conformance**: Ensures thread-safety matching current `LocalPeripheralActor` design
2. **Async/Await**: Modern Swift concurrency throughout
3. **Event Stream**: Maintains current AsyncChannel-based event system
4. **Service Abstraction**: Uses `ServiceMetadata` instead of `CBMutableService` for platform independence
5. **UUID-Based**: Uses `Foundation.UUID` instead of `CBUUID` for easier mocking

#### 5.1.2 BLECentralManagerProtocol

```swift
/// Protocol abstracting CBCentralManager operations
/// Conforming types must be actors for thread-safety
public protocol BLECentralManagerProtocol: Actor {

    // MARK: - Event Stream

    /// Async stream of BLE events from central manager
    var events: AsyncStream<BLEEvent> { get }

    // MARK: - State Management

    /// Current Bluetooth state
    var state: CBManagerState { get async }

    /// Initialize the central manager
    /// - Note: For CoreBluetooth implementations, creates CBCentralManager (triggers TCC)
    ///   For mock implementations, this is typically a no-op
    func initialize() async

    /// Wait until Bluetooth is powered on
    /// - Returns: Final state (should be .poweredOn)
    func waitForPoweredOn() async -> CBManagerState

    // MARK: - Scanning

    /// Scan for peripherals advertising specified services
    /// - Parameters:
    ///   - serviceUUIDs: Services to scan for (empty = all peripherals)
    ///   - timeout: Maximum time to scan
    /// - Returns: AsyncStream of discovered peripherals
    func scanForPeripherals(
        withServices serviceUUIDs: [UUID],
        timeout: TimeInterval
    ) -> AsyncStream<DiscoveredPeripheral>

    /// Stop scanning for peripherals
    func stopScan() async

    // MARK: - Connection Management

    /// Connect to a peripheral
    /// - Parameters:
    ///   - peripheralID: UUID of the peripheral
    ///   - timeout: Connection timeout
    /// - Throws: BleuError if connection fails or times out
    func connect(
        to peripheralID: UUID,
        timeout: TimeInterval
    ) async throws

    /// Disconnect from a peripheral
    /// - Parameter peripheralID: UUID of the peripheral
    /// - Throws: BleuError if disconnection fails
    func disconnect(from peripheralID: UUID) async throws

    /// Check if a peripheral is connected
    /// - Parameter peripheralID: UUID of the peripheral
    /// - Returns: true if connected
    func isConnected(_ peripheralID: UUID) async -> Bool

    // MARK: - Service & Characteristic Discovery

    /// Discover services on a connected peripheral
    /// - Parameters:
    ///   - peripheralID: UUID of the peripheral
    ///   - serviceUUIDs: Specific services to discover (nil = all)
    /// - Returns: Array of discovered services
    /// - Throws: BleuError if discovery fails
    func discoverServices(
        for peripheralID: UUID,
        serviceUUIDs: [UUID]?
    ) async throws -> [ServiceMetadata]

    /// Discover characteristics for a service
    /// - Parameters:
    ///   - serviceUUID: Service UUID
    ///   - peripheralID: Peripheral UUID
    ///   - characteristicUUIDs: Specific characteristics (nil = all)
    /// - Returns: Array of discovered characteristics
    /// - Throws: BleuError if discovery fails
    func discoverCharacteristics(
        for serviceUUID: UUID,
        in peripheralID: UUID,
        characteristicUUIDs: [UUID]?
    ) async throws -> [CharacteristicMetadata]

    // MARK: - Characteristic Operations

    /// Read characteristic value
    /// - Parameters:
    ///   - characteristicUUID: Characteristic UUID
    ///   - peripheralID: Peripheral UUID
    /// - Returns: Characteristic value
    /// - Throws: BleuError if read fails
    func readValue(
        for characteristicUUID: UUID,
        in peripheralID: UUID
    ) async throws -> Data

    /// Write characteristic value
    /// - Parameters:
    ///   - data: Data to write
    ///   - characteristicUUID: Characteristic UUID
    ///   - peripheralID: Peripheral UUID
    ///   - type: Write type (with/without response)
    /// - Throws: BleuError if write fails
    func writeValue(
        _ data: Data,
        for characteristicUUID: UUID,
        in peripheralID: UUID,
        type: CBCharacteristicWriteType
    ) async throws

    /// Enable/disable notifications for characteristic
    /// - Parameters:
    ///   - enabled: true to enable, false to disable
    ///   - characteristicUUID: Characteristic UUID
    ///   - peripheralID: Peripheral UUID
    /// - Throws: BleuError if operation fails
    func setNotifyValue(
        _ enabled: Bool,
        for characteristicUUID: UUID,
        in peripheralID: UUID
    ) async throws

    // MARK: - MTU Management

    /// Get maximum write length for a peripheral
    /// - Parameters:
    ///   - peripheralID: Peripheral UUID
    ///   - type: Write type
    /// - Returns: Maximum write length in bytes (nil if not connected)
    func maximumWriteValueLength(
        for peripheralID: UUID,
        type: CBCharacteristicWriteType
    ) async -> Int?
}
```

**Design Rationale:**

1. **Scanning as AsyncStream**: Natural Swift Concurrency pattern for continuous discovery
2. **Timeout Parameters**: Built into async methods for better control
3. **UUID-Based Tracking**: Simplifies mock implementation
4. **Metadata Return Types**: Platform-independent (not CBService/CBCharacteristic)
5. **Full Coverage**: Every operation `LocalCentralActor` currently performs

### 5.2 Mock Implementations

#### 5.2.1 MockPeripheralManager Design

```swift
/// Mock implementation of BLE peripheral manager for testing
/// Simulates peripheral behavior without requiring BLE hardware or TCC permissions
public actor MockPeripheralManager: BLEPeripheralManagerProtocol {

    // MARK: - Internal State

    private var _state: CBManagerState
    private var _isAdvertising = false
    private var services: [UUID: ServiceMetadata] = [:]
    private var characteristicValues: [UUID: Data] = [:]
    private var subscribedCentrals: [UUID: Set<UUID>] = [:]  // char -> centrals
    private let eventChannel = AsyncChannel<BLEEvent>()

    // MARK: - Configuration

    /// Configuration for controlling mock behavior
    public struct Configuration: Sendable {
        /// Initial Bluetooth state
        public var initialState: CBManagerState = .poweredOn

        /// Delay before advertising starts (simulates async)
        public var advertisingDelay: TimeInterval = 0

        /// Should advertising fail?
        public var shouldFailAdvertising: Bool = false

        /// Should service addition fail?
        public var shouldFailServiceAdd: Bool = false

        /// Delay before responding to writes
        public var writeResponseDelay: TimeInterval = 0

        public init() {}
    }

    private var config: Configuration

    // MARK: - Initialization

    public init(configuration: Configuration = Configuration()) {
        self.config = configuration
        self._state = configuration.initialState
    }

    // MARK: - BLEPeripheralManagerProtocol Implementation

    public var events: AsyncStream<BLEEvent> {
        eventChannel.stream
    }

    public var state: CBManagerState {
        _state
    }

    public func initialize() async {
        // Mock implementation - no-op
        // Already initialized in init(), no CoreBluetooth to create
    }

    public func waitForPoweredOn() async -> CBManagerState {
        if _state == .poweredOn {
            return .poweredOn
        }

        // Simulate state transition
        try? await Task.sleep(nanoseconds: 100_000_000)  // 0.1s
        _state = .poweredOn
        await eventChannel.send(.stateChanged(.poweredOn))
        return .poweredOn
    }

    public func add(_ service: ServiceMetadata) async throws {
        if config.shouldFailServiceAdd {
            throw BleuError.operationNotSupported
        }

        services[service.uuid] = service

        // Initialize characteristic values
        for char in service.characteristics {
            characteristicValues[char.uuid] = Data()
        }
    }

    public func startAdvertising(_ data: AdvertisementData) async throws {
        if config.shouldFailAdvertising {
            throw BleuError.operationNotSupported
        }

        // Simulate async delay
        if config.advertisingDelay > 0 {
            try await Task.sleep(
                nanoseconds: UInt64(config.advertisingDelay * 1_000_000_000)
            )
        }

        _isAdvertising = true
        // Mock: advertising always succeeds
    }

    public func stopAdvertising() async {
        _isAdvertising = false
    }

    public var isAdvertising: Bool {
        _isAdvertising
    }

    public func updateValue(
        _ data: Data,
        for characteristicUUID: UUID,
        to centrals: [UUID]?
    ) async throws -> Bool {
        // Simulate write delay
        if config.writeResponseDelay > 0 {
            try await Task.sleep(
                nanoseconds: UInt64(config.writeResponseDelay * 1_000_000_000)
            )
        }

        characteristicValues[characteristicUUID] = data

        // Send notification event for subscribed centrals
        let centralsToNotify = centrals ?? Array(
            subscribedCentrals[characteristicUUID] ?? []
        )

        for centralID in centralsToNotify {
            await eventChannel.send(.characteristicValueUpdated(
                centralID,
                UUID(),  // service UUID
                characteristicUUID,
                data
            ))
        }

        return true  // Mock always succeeds
    }

    public func subscribedCentrals(for characteristicUUID: UUID) async -> [UUID] {
        Array(subscribedCentrals[characteristicUUID] ?? [])
    }

    // MARK: - Test Helpers (Not in Protocol)

    /// Simulate a central subscribing to a characteristic
    public func simulateSubscription(
        central: UUID,
        to characteristic: UUID
    ) async {
        var centrals = subscribedCentrals[characteristic] ?? []
        centrals.insert(central)
        subscribedCentrals[characteristic] = centrals

        await eventChannel.send(.centralSubscribed(
            central,
            UUID(),  // service UUID
            characteristic
        ))
    }

    /// Simulate a write request from a central
    public func simulateWriteRequest(
        from central: UUID,
        to characteristic: UUID,
        value: Data
    ) async {
        characteristicValues[characteristic] = value
        await eventChannel.send(.writeRequestReceived(
            central,
            UUID(),  // service UUID
            characteristic,
            value
        ))
    }

    /// Change Bluetooth state (for testing state transitions)
    public func simulateStateChange(_ newState: CBManagerState) async {
        _state = newState
        await eventChannel.send(.stateChanged(newState))
    }
}
```

**Design Highlights:**
- ✅ Configurable behavior (delays, failures, states)
- ✅ Complete state tracking
- ✅ Test helper methods (not in protocol)
- ✅ Proper event generation
- ✅ No BLE hardware required
- ✅ Pure in-memory implementation

#### 5.2.2 MockCentralManager Design

```swift
/// Mock implementation of BLE central manager for testing
/// Simulates central behavior without requiring BLE hardware or TCC permissions
public actor MockCentralManager: BLECentralManagerProtocol {

    // MARK: - Internal State

    private var _state: CBManagerState
    private var discoveredPeripherals: [UUID: DiscoveredPeripheral] = [:]
    private var connectedPeripherals: Set<UUID> = []
    private var peripheralServices: [UUID: [ServiceMetadata]] = [:]
    private var peripheralCharacteristics: [UUID: [UUID: [CharacteristicMetadata]]] = [:]
    private var characteristicValues: [UUID: [UUID: Data]] = [:]
    private var notifyingCharacteristics: [UUID: Set<UUID>] = [:]
    private let eventChannel = AsyncChannel<BLEEvent>()

    // MARK: - Configuration

    public struct Configuration: Sendable {
        public var initialState: CBManagerState = .poweredOn
        public var scanDelay: TimeInterval = 0.1
        public var connectionDelay: TimeInterval = 0.1
        public var discoveryDelay: TimeInterval = 0.05
        public var shouldFailConnection: Bool = false
        public var connectionTimeout: Bool = false

        public init() {}
    }

    private var config: Configuration

    // MARK: - Initialization

    public init(configuration: Configuration = Configuration()) {
        self.config = configuration
        self._state = configuration.initialState
    }

    // MARK: - BLECentralManagerProtocol Implementation

    public var events: AsyncStream<BLEEvent> {
        eventChannel.stream
    }

    public var state: CBManagerState {
        _state
    }

    public func initialize() async {
        // Mock implementation - no-op
        // Already initialized in init(), no CoreBluetooth to create
    }

    public func waitForPoweredOn() async -> CBManagerState {
        if _state == .poweredOn {
            return .poweredOn
        }

        try? await Task.sleep(nanoseconds: 100_000_000)
        _state = .poweredOn
        await eventChannel.send(.stateChanged(.poweredOn))
        return .poweredOn
    }

    public func scanForPeripherals(
        withServices serviceUUIDs: [UUID],
        timeout: TimeInterval
    ) -> AsyncStream<DiscoveredPeripheral> {
        AsyncStream { continuation in
            Task {
                // Emit discovered peripherals matching service UUIDs
                for peripheral in discoveredPeripherals.values {
                    let matches = serviceUUIDs.isEmpty ||
                        peripheral.advertisementData.serviceUUIDs.contains(
                            where: { serviceUUIDs.contains($0) }
                        )

                    if matches {
                        if config.scanDelay > 0 {
                            try? await Task.sleep(
                                nanoseconds: UInt64(config.scanDelay * 1_000_000_000)
                            )
                        }
                        continuation.yield(peripheral)
                        await eventChannel.send(.peripheralDiscovered(peripheral))
                    }
                }

                // Wait for timeout
                try? await Task.sleep(
                    nanoseconds: UInt64(timeout * 1_000_000_000)
                )
                continuation.finish()
            }
        }
    }

    public func stopScan() async {
        // Mock: no-op
    }

    public func connect(
        to peripheralID: UUID,
        timeout: TimeInterval
    ) async throws {
        if config.shouldFailConnection {
            throw BleuError.connectionFailed("Mock configured to fail")
        }

        if config.connectionTimeout {
            try await Task.sleep(
                nanoseconds: UInt64(timeout * 1_000_000_000)
            )
            throw BleuError.connectionTimeout
        }

        guard discoveredPeripherals[peripheralID] != nil else {
            throw BleuError.peripheralNotFound(peripheralID)
        }

        if config.connectionDelay > 0 {
            try await Task.sleep(
                nanoseconds: UInt64(config.connectionDelay * 1_000_000_000)
            )
        }

        connectedPeripherals.insert(peripheralID)
        await eventChannel.send(.peripheralConnected(peripheralID))
    }

    public func disconnect(from peripheralID: UUID) async throws {
        connectedPeripherals.remove(peripheralID)
        await eventChannel.send(.peripheralDisconnected(peripheralID, nil))
    }

    public func isConnected(_ peripheralID: UUID) async -> Bool {
        connectedPeripherals.contains(peripheralID)
    }

    public func discoverServices(
        for peripheralID: UUID,
        serviceUUIDs: [UUID]?
    ) async throws -> [ServiceMetadata] {
        guard connectedPeripherals.contains(peripheralID) else {
            throw BleuError.peripheralNotFound(peripheralID)
        }

        if config.discoveryDelay > 0 {
            try await Task.sleep(
                nanoseconds: UInt64(config.discoveryDelay * 1_000_000_000)
            )
        }

        let services = peripheralServices[peripheralID] ?? []
        await eventChannel.send(.serviceDiscovered(peripheralID, services))
        return services
    }

    public func discoverCharacteristics(
        for serviceUUID: UUID,
        in peripheralID: UUID,
        characteristicUUIDs: [UUID]?
    ) async throws -> [CharacteristicMetadata] {
        guard connectedPeripherals.contains(peripheralID) else {
            throw BleuError.peripheralNotFound(peripheralID)
        }

        if config.discoveryDelay > 0 {
            try await Task.sleep(
                nanoseconds: UInt64(config.discoveryDelay * 1_000_000_000)
            )
        }

        return peripheralCharacteristics[peripheralID]?[serviceUUID] ?? []
    }

    public func readValue(
        for characteristicUUID: UUID,
        in peripheralID: UUID
    ) async throws -> Data {
        guard connectedPeripherals.contains(peripheralID) else {
            throw BleuError.peripheralNotFound(peripheralID)
        }

        return characteristicValues[peripheralID]?[characteristicUUID] ?? Data()
    }

    public func writeValue(
        _ data: Data,
        for characteristicUUID: UUID,
        in peripheralID: UUID,
        type: CBCharacteristicWriteType
    ) async throws {
        guard connectedPeripherals.contains(peripheralID) else {
            throw BleuError.peripheralNotFound(peripheralID)
        }

        if characteristicValues[peripheralID] == nil {
            characteristicValues[peripheralID] = [:]
        }
        characteristicValues[peripheralID]?[characteristicUUID] = data
    }

    public func setNotifyValue(
        _ enabled: Bool,
        for characteristicUUID: UUID,
        in peripheralID: UUID
    ) async throws {
        guard connectedPeripherals.contains(peripheralID) else {
            throw BleuError.peripheralNotFound(peripheralID)
        }

        if enabled {
            if notifyingCharacteristics[peripheralID] == nil {
                notifyingCharacteristics[peripheralID] = []
            }
            notifyingCharacteristics[peripheralID]?.insert(characteristicUUID)
        } else {
            notifyingCharacteristics[peripheralID]?.remove(characteristicUUID)
        }

        await eventChannel.send(.notificationStateChanged(
            peripheralID,
            UUID(),
            characteristicUUID,
            enabled
        ))
    }

    public func maximumWriteValueLength(
        for peripheralID: UUID,
        type: CBCharacteristicWriteType
    ) async -> Int? {
        guard connectedPeripherals.contains(peripheralID) else {
            return nil
        }
        return 512  // Mock MTU
    }

    // MARK: - Test Helpers (Not in Protocol)

    /// Register a peripheral for discovery
    public func registerPeripheral(
        _ peripheral: DiscoveredPeripheral,
        services: [ServiceMetadata]
    ) async {
        discoveredPeripherals[peripheral.id] = peripheral
        peripheralServices[peripheral.id] = services

        // Setup characteristics mapping
        peripheralCharacteristics[peripheral.id] = [:]
        for service in services {
            peripheralCharacteristics[peripheral.id]?[service.uuid] =
                service.characteristics
        }
    }

    /// Simulate a characteristic value update (notification)
    public func simulateValueUpdate(
        for characteristicUUID: UUID,
        in peripheralID: UUID,
        value: Data
    ) async {
        if characteristicValues[peripheralID] == nil {
            characteristicValues[peripheralID] = [:]
        }
        characteristicValues[peripheralID]?[characteristicUUID] = value

        if notifyingCharacteristics[peripheralID]?.contains(characteristicUUID) == true {
            await eventChannel.send(.characteristicValueUpdated(
                peripheralID,
                UUID(),
                characteristicUUID,
                value
            ))
        }
    }

    /// Simulate disconnection with error
    public func simulateDisconnection(
        peripheralID: UUID,
        error: Error?
    ) async {
        connectedPeripherals.remove(peripheralID)
        await eventChannel.send(.peripheralDisconnected(peripheralID, error))
    }

    /// Change Bluetooth state
    public func simulateStateChange(_ newState: CBManagerState) async {
        _state = newState
        await eventChannel.send(.stateChanged(newState))
    }
}
```

**Design Highlights:**
- ✅ Full peripheral simulation
- ✅ Realistic behavior (delays, timeouts, failures)
- ✅ State management (connections, notifications, values)
- ✅ Event generation for testing
- ✅ Test helpers for complex scenarios

#### 5.2.3 CoreBluetoothPeripheralManager Implementation Guidelines

The production implementation wraps `CBPeripheralManager` and adapts current `LocalPeripheralActor` code:

```swift
/// Production implementation wrapping CBPeripheralManager
public actor CoreBluetoothPeripheralManager: BLEPeripheralManagerProtocol {

    private var peripheralManager: CBPeripheralManager?
    private var delegateProxy: PeripheralManagerDelegateProxy?
    private let eventChannel = AsyncChannel<BLEEvent>()
    private var _state: CBManagerState = .unknown
    private var _isAdvertising = false

    // State for service/characteristic management
    private var services: [UUID: CBMutableService] = [:]
    private var characteristics: [UUID: CBMutableCharacteristic] = [:]
    private var subscribedCentrals: [UUID: Set<CBCentral>] = [:]

    public init() {
        // Do NOT create CBPeripheralManager here (no TCC)
        // Will be created in initialize()
    }

    public func initialize() async {
        // TCC check occurs HERE
        delegateProxy = PeripheralManagerDelegateProxy(actor: self)
        peripheralManager = CBPeripheralManager(
            delegate: delegateProxy,
            queue: nil
        )
    }

    public var events: AsyncStream<BLEEvent> {
        eventChannel.stream
    }

    public var state: CBManagerState {
        _state
    }

    public func waitForPoweredOn() async -> CBManagerState {
        // Wait for state to become .poweredOn
        // Implementation similar to current LocalPeripheralActor
    }

    public func add(_ service: ServiceMetadata) async throws {
        // Convert ServiceMetadata -> CBMutableService
        // Migrate from LocalPeripheralActor.setupService()
    }

    public func startAdvertising(_ data: AdvertisementData) async throws {
        // Convert AdvertisementData -> [String: Any] dictionary
        // Call peripheralManager.startAdvertising()
    }

    // ... other protocol methods
}
```

**Key Migration Points:**
1. Extract all logic from `LocalPeripheralActor`
2. Adapt method signatures to match protocol
3. Keep delegate proxy pattern intact
4. Maintain AsyncChannel for events
5. Convert between `UUID` ↔ `CBUUID` as needed
6. Convert between `ServiceMetadata` ↔ `CBMutableService`

#### 5.2.4 CoreBluetoothCentralManager Implementation Guidelines

The production implementation wraps `CBCentralManager` and adapts current `LocalCentralActor` code:

```swift
/// Production implementation wrapping CBCentralManager
public actor CoreBluetoothCentralManager: BLECentralManagerProtocol {

    private var centralManager: CBCentralManager?
    private var delegateProxy: CentralManagerDelegateProxy?
    private let eventChannel = AsyncChannel<BLEEvent>()
    private var _state: CBManagerState = .unknown

    // Track discovered and connected peripherals
    private var discoveredPeripherals: [UUID: CBPeripheral] = [:]
    private var connectedPeripherals: [UUID: CBPeripheral] = [:]

    public init() {
        // Do NOT create CBCentralManager here (no TCC)
        // Will be created in initialize()
    }

    public func initialize() async {
        // TCC check occurs HERE
        delegateProxy = CentralManagerDelegateProxy(actor: self)
        centralManager = CBCentralManager(
            delegate: delegateProxy,
            queue: nil
        )
    }

    public var events: AsyncStream<BLEEvent> {
        eventChannel.stream
    }

    public var state: CBManagerState {
        _state
    }

    public func waitForPoweredOn() async -> CBManagerState {
        // Wait for state to become .poweredOn
    }

    public func scanForPeripherals(
        withServices serviceUUIDs: [UUID],
        timeout: TimeInterval
    ) -> AsyncStream<DiscoveredPeripheral> {
        // Convert UUIDs to CBUUIDs
        // Start scanning with centralManager
        // Return AsyncStream of discovered peripherals
    }

    public func connect(to peripheralID: UUID, timeout: TimeInterval) async throws {
        // Get CBPeripheral from discoveredPeripherals
        // Call centralManager.connect()
        // Wait for connection with timeout
    }

    // ... other protocol methods
}
```

**Key Migration Points:**
1. Extract all logic from `LocalCentralActor`
2. Adapt method signatures to match protocol
3. Maintain peripheral references (prevent deallocation)
4. Keep delegate proxy pattern intact
5. Handle connection state tracking
6. Convert between platform types as needed

**Important Considerations for Both Implementations:**

1. **Delegate Proxy Pattern**: Keep existing `PeripheralManagerDelegateProxy` and `CentralManagerDelegateProxy` unchanged. They convert CoreBluetooth callbacks to AsyncChannel events.

2. **TCC Timing**: `CBPeripheralManager` and `CBCentralManager` creation **must** happen in `initialize()`, not in `init()`. This allows SPM tests to instantiate wrappers without triggering TCC.

3. **UUID Conversion**: CoreBluetooth uses `CBUUID`, protocols use `Foundation.UUID`. Convert via:
   ```swift
   let cbuuid = CBUUID(nsuuid: uuid)           // UUID → CBUUID
   let uuid = (cbuuid as NSUUID) as UUID        // CBUUID → UUID
   ```

4. **Metadata Conversion**:
   - `ServiceMetadata` → `CBMutableService`
   - `CharacteristicMetadata` → `CBMutableCharacteristic`
   - `AdvertisementData` → `[String: Any]` dictionary

5. **State Management**: Track state internally and update via delegate callbacks. The `waitForPoweredOn()` method should use continuations to wait asynchronously.

### 5.3 BLEActorSystem Refactoring

#### 5.3.1 New Initialization

```swift
public final class BLEActorSystem: DistributedActorSystem, Sendable {
    // ... existing properties ...

    // CHANGED: Use protocols instead of concrete types
    private let peripheralManager: BLEPeripheralManagerProtocol
    private let centralManager: BLECentralManagerProtocol

    // MARK: - Initialization (Internal with DI)

    /// Internal initializer with dependency injection
    /// - Parameters:
    ///   - peripheralManager: BLE peripheral manager implementation (must be initialized)
    ///   - centralManager: BLE central manager implementation (must be initialized)
    /// - Note: Managers should have their initialize() method called BEFORE passing here
    ///   The init will wait for them to reach .poweredOn state asynchronously
    internal init(
        peripheralManager: BLEPeripheralManagerProtocol,
        centralManager: BLECentralManagerProtocol
    ) {
        self.peripheralManager = peripheralManager
        self.centralManager = centralManager

        Task {
            // Wait for managers to be powered on before setting up event handlers
            // This is safe because initialize() has already been called by the factory/convenience init
            _ = await peripheralManager.waitForPoweredOn()
            _ = await centralManager.waitForPoweredOn()

            await setupEventHandlers()
            await bootstrap.markReady()
        }
    }

    // MARK: - Factory Methods

    /// Create production instance with real CoreBluetooth
    /// - Note: Requires Bluetooth permissions (TCC)
    /// - Warning: Will trigger TCC permission check on iOS/macOS
    public static func production() -> BLEActorSystem {
        let peripheral = CoreBluetoothPeripheralManager()
        let central = CoreBluetoothCentralManager()

        // Initialize managers BEFORE creating BLEActorSystem
        // This ensures they are ready when internal init() calls waitForPoweredOn()
        Task {
            await peripheral.initialize()  // TCC check happens here
            await central.initialize()     // TCC check happens here
        }

        return BLEActorSystem(
            peripheralManager: peripheral,
            centralManager: central
        )
    }

    /// Create mock instance for testing
    /// - Parameters:
    ///   - peripheralConfig: Configuration for mock peripheral manager
    ///   - centralConfig: Configuration for mock central manager
    /// - Returns: BLEActorSystem with mock implementations
    /// - Note: No Bluetooth permissions required, no hardware needed
    public static func mock(
        peripheralConfig: MockPeripheralManager.Configuration = .init(),
        centralConfig: MockCentralManager.Configuration = .init()
    ) -> BLEActorSystem {
        return BLEActorSystem(
            peripheralManager: MockPeripheralManager(
                configuration: peripheralConfig
            ),
            centralManager: MockCentralManager(
                configuration: centralConfig
            )
        )
    }

    // MARK: - Testing Support

    /// Access to mock peripheral manager for testing
    /// - Returns: Mock peripheral manager if the system was created with `.mock()`, otherwise nil
    /// - Note: Only available when using mock implementations
    /// - Important: Use this method instead of direct downcasting to access mock-specific APIs
    ///   The `peripheralManager` property is private, so tests must use this accessor
    public func mockPeripheralManager() async -> MockPeripheralManager? {
        return peripheralManager as? MockPeripheralManager
    }

    /// Access to mock central manager for testing
    /// - Returns: Mock central manager if the system was created with `.mock()`, otherwise nil
    /// - Note: Only available when using mock implementations
    /// - Important: Use this method instead of direct downcasting to access mock-specific APIs
    ///   The `centralManager` property is private, so tests must use this accessor
    public func mockCentralManager() async -> MockCentralManager? {
        return centralManager as? MockCentralManager
    }

    // MARK: - Backward Compatibility

    /// Shared instance - now uses production() by default
    /// - Warning: Requires Bluetooth permissions
    /// - Note: Existing code using `.shared` continues to work unchanged
    public static let shared: BLEActorSystem = .production()

    /// Legacy initializer for backward compatibility
    /// - Note: Creates production instance identical to `.shared`
    /// - Warning: Requires Bluetooth permissions (TCC)
    public convenience init() {
        // Create dependencies directly without going through .production()
        let peripheral = CoreBluetoothPeripheralManager()
        let central = CoreBluetoothCentralManager()

        // Pass uninitialized managers to internal init
        // The internal init will wait for them to power on via waitForPoweredOn()
        self.init(
            peripheralManager: peripheral,
            centralManager: central
        )

        // Start initialization after BLEActorSystem is constructed
        // This ensures no duplicate tasks are created
        Task {
            await peripheral.initialize()
            await central.initialize()
        }
    }
}
```

**Design Notes:**

1. **Initialization Ordering**: All factory methods and convenience initializers follow the same pattern:
   - Create manager instances
   - Call `initialize()` on managers in a Task (triggers TCC for production, no-op for mocks)
   - Pass managers to `internal init()`
   - Internal init starts a Task that waits for `.poweredOn`, then sets up event handlers

   This ensures `setupEventHandlers()` always operates on initialized managers.

2. **Task Duplication Prevention**: The convenience `init()` creates dependencies directly instead of calling `.production()` to avoid duplicate task creation. When `.production()` is called, it starts an initialization task. If we then copied those managers to create a new BLEActorSystem, the internal init would start another setupEventHandlers task, causing duplicate event subscriptions.

3. **Race Condition Handling**: The internal init's Task calls `waitForPoweredOn()`, which blocks until managers reach `.poweredOn` state. This handles the race between the factory's `initialize()` Task and the internal init's setup Task - even if initialize() hasn't completed yet, waitForPoweredOn() will wait for it.

4. **Testing Support Methods**: The `mockPeripheralManager()` and `mockCentralManager()` methods provide safe access to mock-specific APIs without exposing the private protocol properties. This maintains encapsulation while enabling advanced test scenarios like simulating connection failures or state changes.

#### 5.3.2 Updated Method Implementations

All methods that currently use `localPeripheral` or `localCentral` will be updated to use the protocol properties:

```swift
// BEFORE
public func startAdvertising<T: PeripheralActor>(_ peripheral: T) async throws {
    guard await ready else {
        throw BleuError.bluetoothUnavailable
    }

    let metadata = ServiceMapper.createServiceMetadata(from: T.self)
    try await localPeripheral.setupService(from: metadata)  // ← Concrete type

    let advertisementData = AdvertisementData(
        localName: String(describing: T.self),
        serviceUUIDs: [metadata.uuid]
    )

    try await localPeripheral.startAdvertising(advertisementData)  // ← Concrete type
    actorReady(peripheral)
}

// AFTER
public func startAdvertising<T: PeripheralActor>(_ peripheral: T) async throws {
    guard await ready else {
        throw BleuError.bluetoothUnavailable
    }

    let metadata = ServiceMapper.createServiceMetadata(from: T.self)
    try await peripheralManager.add(metadata)  // ← Protocol method

    let advertisementData = AdvertisementData(
        localName: String(describing: T.self),
        serviceUUIDs: [metadata.uuid]
    )

    try await peripheralManager.startAdvertising(advertisementData)  // ← Protocol method
    actorReady(peripheral)
}
```

**Key Changes:**
- Replace `localPeripheral` → `peripheralManager`
- Replace `localCentral` → `centralManager`
- All calls through protocol interface
- Identical behavior, flexible implementation

### 5.4 Test Architecture

#### 5.4.1 Directory Structure

```
Tests/BleuTests/
├── Unit/                           # Pure unit tests (no BLE hardware)
│   ├── ServiceMapperTests.swift    # Service/UUID generation
│   ├── MethodRegistryTests.swift   # Method registration
│   ├── BLETransportTests.swift     # Packet fragmentation
│   ├── EventBridgeTests.swift      # Event routing
│   └── UUIDExtensionsTests.swift   # UUID utilities
│
├── Integration/                    # Integration tests (mock BLE)
│   ├── MockConnectionTests.swift   # Connection flows with mocks
│   ├── MockRPCTests.swift          # RPC execution with mocks
│   ├── MockDiscoveryTests.swift    # Discovery/scan with mocks
│   └── ErrorHandlingTests.swift    # Error scenarios
│
├── Hardware/                       # Real BLE tests (requires hardware)
│   ├── RealBLETests.swift          # Actual BLE hardware tests
│   └── PerformanceTests.swift      # Real-world performance
│
└── Mocks/                          # Shared test utilities
    ├── TestHelpers.swift           # Common test utilities
    └── MockActorExamples.swift     # Example distributed actors for testing
```

#### 5.4.2 Unit Test Example

```swift
import Testing
@testable import Bleu

@Suite("Distributed Actor RPC Tests")
struct DistributedActorRPCTests {

    @Test("RPC call execution with mock BLE")
    func testRPCExecution() async throws {
        // Create mock system (no TCC required!)
        let system = BLEActorSystem.mock()

        // Define test peripheral actor
        distributed actor TestPeripheral {
            typealias ActorSystem = BLEActorSystem

            distributed func getValue() async -> Int {
                return 42
            }
        }

        let peripheral = TestPeripheral(actorSystem: system)
        try await system.startAdvertising(peripheral)

        // Verify system is ready
        #expect(await system.ready)

        // Verify service was registered (using mock's internal state)
        // Test RPC invocation logic without real BLE
    }

    @Test("Connection failure handling")
    func testConnectionFailure() async throws {
        // Configure mock to fail connections
        let config = MockCentralManager.Configuration(
            shouldFailConnection: true
        )
        let system = BLEActorSystem.mock(centralConfig: config)

        distributed actor TestActor {
            typealias ActorSystem = BLEActorSystem
        }

        // Test that connection failures are handled correctly
        do {
            try await system.connect(to: UUID(), as: TestActor.self)
            Issue.record("Expected connection to fail")
        } catch {
            #expect(error is BleuError)
        }
    }

    @Test("Timeout scenarios")
    func testConnectionTimeout() async throws {
        // Configure mock to timeout on connection
        let config = MockCentralManager.Configuration(
            connectionTimeout: true
        )
        let system = BLEActorSystem.mock(centralConfig: config)

        distributed actor TestActor {
            typealias ActorSystem = BLEActorSystem
        }

        // Should throw timeout error
        do {
            try await system.connect(
                to: UUID(),
                as: TestActor.self,
                timeout: 0.5
            )
            Issue.record("Expected connection to timeout")
        } catch let error as BleuError {
            #expect(error == .connectionTimeout)
        } catch {
            Issue.record("Expected BleuError.connectionTimeout, got \(error)")
        }
    }
}
```

#### 5.4.3 Integration Test Example

```swift
@Suite("Mock BLE Integration Tests")
struct MockBLEIntegrationTests {

    @Test("Full peripheral-central interaction")
    func testFullInteraction() async throws {
        // Create two separate systems
        let peripheralSystem = BLEActorSystem.mock()
        let centralSystem = BLEActorSystem.mock()

        // Define sensor actor
        distributed actor Sensor {
            typealias ActorSystem = BLEActorSystem

            distributed func readTemperature() async -> Double {
                return 22.5
            }
        }

        // Setup peripheral side
        let sensor = Sensor(actorSystem: peripheralSystem)
        try await peripheralSystem.startAdvertising(sensor)

        // Setup central side - register the peripheral in mock
        let peripheralID = sensor.id
        guard let mockCentral = await centralSystem.mockCentralManager() else {
            Issue.record("Expected mock central manager")
            return
        }

        let discovered = DiscoveredPeripheral(
            id: peripheralID,
            name: "Sensor",
            rssi: -50,
            advertisementData: AdvertisementData(
                serviceUUIDs: [UUID.serviceUUID(for: Sensor.self)]
            )
        )

        let serviceMetadata = ServiceMapper.createServiceMetadata(from: Sensor.self)
        await mockCentral.registerPeripheral(discovered, services: [serviceMetadata])

        // Discover peripherals
        let sensors = try await centralSystem.discover(Sensor.self, timeout: 1.0)
        #expect(sensors.count == 1)

        // Call distributed method
        let temp = try await sensors[0].readTemperature()
        #expect(temp == 22.5)
    }

    @Test("Multiple concurrent connections")
    func testConcurrentConnections() async throws {
        let system = BLEActorSystem.mock()

        distributed actor Device {
            typealias ActorSystem = BLEActorSystem
            let deviceID: Int

            init(deviceID: Int, actorSystem: BLEActorSystem) {
                self.deviceID = deviceID
                self.actorSystem = actorSystem
            }

            distributed func getID() async -> Int {
                return deviceID
            }
        }

        // Create multiple devices
        let devices = (0..<5).map { Device(deviceID: $0, actorSystem: system) }

        // Advertise all
        try await withThrowingTaskGroup(of: Void.self) { group in
            for device in devices {
                group.addTask {
                    try await system.startAdvertising(device)
                }
            }
            try await group.waitForAll()
        }

        // Verify all are working
        let ids = try await withThrowingTaskGroup(of: Int.self) { group in
            for device in devices {
                group.addTask {
                    try await device.getID()
                }
            }

            var results: [Int] = []
            for try await id in group {
                results.append(id)
            }
            return results
        }

        #expect(ids.sorted() == [0, 1, 2, 3, 4])
    }
}
```

#### 5.4.4 When to Use Each Test Type

**Unit Tests** (`Tests/Unit/`):
- ✅ Pure logic with no BLE dependency
- ✅ ServiceMapper, MethodRegistry, UUID generation
- ✅ Data serialization/deserialization
- ✅ Error handling logic
- ✅ Fast execution (milliseconds)
- ✅ CI/CD friendly
- ✅ No TCC permissions needed

**Integration Tests** (`Tests/Integration/`):
- ✅ Mock BLE interactions
- ✅ Full discovery → connect → RPC flow
- ✅ Connection failure scenarios
- ✅ Timeout handling
- ✅ Event propagation
- ✅ Still fast (seconds)
- ✅ CI/CD friendly
- ✅ No TCC permissions needed

**Hardware Tests** (`Tests/Hardware/`):
- ⚠️ Real BLE hardware required
- ⚠️ Requires TCC permissions and Info.plist
- ⚠️ Slower execution (minutes)
- ⚠️ Manual execution only (skip in CI/CD)
- ✅ Final validation before release
- ✅ Real-world performance testing

---

## 6. Implementation Plan

### Overview

5-week phased implementation with incremental delivery of value.

### Phase 1: Foundation (Week 1)

**Goal**: Create protocol layer without breaking existing code

**Tasks:**

**Day 1-2: Define Protocols**
- [ ] Create `Sources/Bleu/Protocols/BLEManagerProtocols.swift`
- [ ] Define `BLEPeripheralManagerProtocol` with full method signatures
- [ ] Define `BLECentralManagerProtocol` with full method signatures
- [ ] Add comprehensive documentation comments
- [ ] Add protocol refinements based on current usage patterns

**Day 3-4: Create Wrapper Implementations**
- [ ] Create `Sources/Bleu/Implementations/CoreBluetoothPeripheralManager.swift`
- [ ] Create `Sources/Bleu/Implementations/CoreBluetoothCentralManager.swift`
- [ ] Migrate code from `LocalPeripheralActor` to wrapper
- [ ] Migrate code from `LocalCentralActor` to wrapper
- [ ] Add delayed initialization (no TCC check in init)
- [ ] Make wrappers conform to protocols

**Day 5: Testing**
- [ ] Verify wrappers work identically to current implementation
- [ ] Test with Example apps (SensorServer, SensorClient, BleuExampleApp)
- [ ] Ensure no regression in existing functionality
- [ ] Test on real BLE hardware

**Deliverables:**
- ✅ Protocol definitions
- ✅ Production wrappers (CoreBluetooth-based)
- ✅ Zero breaking changes
- ✅ All examples still work

**Dependencies**: None
**Risk**: Low - purely additive changes

### Phase 2: Mock Implementation (Week 2)

**Goal**: Build comprehensive mock BLE managers for testing

**Tasks:**

**Day 1-2: MockPeripheralManager**
- [ ] Create `Sources/Bleu/Mocks/MockPeripheralManager.swift`
- [ ] Implement all `BLEPeripheralManagerProtocol` methods
- [ ] Add `Configuration` struct for controlling behavior
- [ ] Add test helper methods (simulate subscription, etc.)
- [ ] Write unit tests for mock itself
- [ ] Document mock limitations and behavior

**Day 3-4: MockCentralManager**
- [ ] Create `Sources/Bleu/Mocks/MockCentralManager.swift`
- [ ] Implement all `BLECentralManagerProtocol` methods
- [ ] Add peripheral registration system
- [ ] Add simulation capabilities (disconnections, errors)
- [ ] Write unit tests for mock itself
- [ ] Document mock usage patterns

**Day 5: Integration**
- [ ] Test mocks with real distributed actors
- [ ] Verify event generation works correctly
- [ ] Test error simulation scenarios
- [ ] Create mock usage examples
- [ ] Document testing patterns

**Deliverables:**
- ✅ Complete mock implementations
- ✅ Configurable behavior
- ✅ Unit tests for mocks
- ✅ Documentation and examples

**Dependencies**: Phase 1 complete
**Risk**: Medium - complex state management in mocks

### Phase 3: BLEActorSystem Refactoring (Week 3)

**Goal**: Update BLEActorSystem to use protocols and enable DI

**Tasks:**

**Day 1-2: Dependency Injection**
- [ ] Update `BLEActorSystem` properties to use protocol types
- [ ] Implement internal `init(peripheralManager:centralManager:)`
- [ ] Create `production()` factory method
- [ ] Create `mock()` factory method with configuration
- [ ] Update `shared` singleton to use `production()`
- [ ] Add backward-compatible convenience `init()`

**Day 3-4: Method Migration**
- [ ] Update `startAdvertising()` to use protocol methods
- [ ] Update `discover()` to use protocol methods
- [ ] Update `connect()` to use protocol methods
- [ ] Update all other BLE interaction methods
- [ ] Replace `localPeripheral` with `peripheralManager`
- [ ] Replace `localCentral` with `centralManager`

**Day 5: Verification**
- [ ] Test with all existing examples
- [ ] Verify no API breaking changes
- [ ] Test backward compatibility thoroughly
- [ ] Update inline documentation
- [ ] Test both production and mock paths

**Deliverables:**
- ✅ Refactored BLEActorSystem with DI
- ✅ Factory methods for production/mock
- ✅ 100% backward compatibility
- ✅ All examples work unchanged

**Dependencies**: Phases 1 and 2 complete
**Risk**: High - central system changes, careful testing required

### Phase 4: Test Migration (Week 4)

**Goal**: Rewrite tests using new architecture

**Tasks:**

**Day 1: Test Infrastructure**
- [ ] Create `Tests/BleuTests/Unit/` directory
- [ ] Create `Tests/BleuTests/Integration/` directory
- [ ] Create `Tests/BleuTests/Hardware/` directory
- [ ] Create `Tests/BleuTests/Mocks/` directory
- [ ] Setup common test fixtures
- [ ] Create test helper utilities
- [ ] Document testing patterns

**Day 2-3: Unit Tests**
- [ ] Move existing isolated tests to `Unit/`
- [ ] Rewrite integration tests to use mocks
- [ ] Add new tests for previously untestable code
- [ ] Test error conditions comprehensively
- [ ] Test edge cases and race conditions
- [ ] Achieve >80% code coverage

**Day 4: Integration Tests**
- [ ] Write mock-based integration tests in `Integration/`
- [ ] Test full discovery → connect → RPC workflows
- [ ] Test connection failure scenarios
- [ ] Test timeout handling
- [ ] Test event propagation
- [ ] Test concurrent operations

**Day 5: Hardware Tests**
- [ ] Move real BLE tests to `Hardware/`
- [ ] Add skip conditions for CI/CD
- [ ] Document hardware test execution requirements
- [ ] Setup manual test checklist
- [ ] Create hardware test README

**Deliverables:**
- ✅ Reorganized test structure
- ✅ Comprehensive unit tests (mock-based)
- ✅ Integration tests (mock-based)
- ✅ Separated hardware tests
- ✅ >80% code coverage

**Dependencies**: Phase 3 complete
**Risk**: Low - tests only, no production code changes

### Phase 5: Documentation & Polish (Week 5)

**Goal**: Complete documentation and finalize release

**Tasks:**

**Day 1-2: Documentation**
- [ ] Update README.md with testing guide
- [ ] Create `docs/guides/TESTING.md`
- [ ] Document protocol layer architecture
- [ ] Add migration guide for contributors
- [ ] Update `CLAUDE.md` with new patterns
- [ ] Update `REPOSITORY_GUIDELINES.md`

**Day 3-4: Examples & Guides**
- [ ] Add testing example to Examples/
- [ ] Create troubleshooting guide
- [ ] Add best practices guide
- [ ] Update Examples/README.md
- [ ] Create quick start guide for testing

**Day 5: Final Validation**
- [ ] Run full test suite on all platforms
- [ ] Performance testing (before/after comparison)
- [ ] Security review of changes
- [ ] Final documentation review
- [ ] Prepare release notes

**Deliverables:**
- ✅ Complete documentation
- ✅ Testing guides
- ✅ Examples and best practices
- ✅ Release-ready codebase

**Dependencies**: All previous phases complete
**Risk**: Low - documentation and polish only

### Testing Strategy Per Phase

**Phase 1**: Manual testing with Example apps, verify equivalence
**Phase 2**: Unit test mocks themselves, verify simulation accuracy
**Phase 3**: Test both mock and real BLE paths, ensure parity
**Phase 4**: Comprehensive automated test suite execution
**Phase 5**: Full regression testing across all platforms

---

## 7. Migration Guide

### 7.1 For Current API Users

**Excellent News**: Zero changes required for existing code!

```swift
// This code continues to work completely unchanged:
let system = BLEActorSystem.shared

distributed actor MySensor {
    typealias ActorSystem = BLEActorSystem

    distributed func readValue() async -> Int {
        return 42
    }
}

let sensor = MySensor(actorSystem: system)
try await system.startAdvertising(sensor)

// Client side - also unchanged:
let sensors = try await system.discover(MySensor.self)
let value = try await sensors[0].readValue()
```

### 7.2 For Test Writers

**Before (couldn't test - crashed with TCC):**
```swift
@Test func testSensor() async throws {
    // ❌ This crashes with TCC violation
    let system = BLEActorSystem()

    distributed actor TestSensor {
        typealias ActorSystem = BLEActorSystem
        distributed func getValue() async -> Int { 42 }
    }

    let sensor = TestSensor(actorSystem: system)
    // CRASH: __TCC_CRASHING_DUE_TO_PRIVACY_VIOLATION__
}
```

**After (works perfectly - no TCC required):**
```swift
@Test func testSensor() async throws {
    // ✅ No TCC required! Works in swift test!
    let system = BLEActorSystem.mock()

    distributed actor TestSensor {
        typealias ActorSystem = BLEActorSystem
        distributed func getValue() async -> Int { 42 }
    }

    let sensor = TestSensor(actorSystem: system)
    try await system.startAdvertising(sensor)

    #expect(await system.ready)
    // Test your distributed actor logic!
}
```

### 7.3 For Advanced Users

**Custom Mock Configuration:**
```swift
// Example: Simulate connection failures
let config = MockCentralManager.Configuration(
    connectionDelay: 2.0,          // Slow connection
    shouldFailConnection: true,     // Always fail
    discoveryDelay: 1.0            // Slow discovery
)
let system = BLEActorSystem.mock(centralConfig: config)

// Test error handling
await #expect(throws: BleuError.connectionFailed) {
    try await system.connect(to: someID, as: MyActor.self)
}
```

**Simulate Bluetooth State Changes:**
```swift
let system = BLEActorSystem.mock()
guard let mockCentral = await system.mockCentralManager() else {
    fatalError("Expected mock central manager")
}

// Simulate Bluetooth turning off
await mockCentral.simulateStateChange(.poweredOff)

// Test app's response to Bluetooth state changes
```

### 7.4 Backward Compatibility Guarantees

1. ✅ `BLEActorSystem.shared` continues to work
2. ✅ `BLEActorSystem()` continues to work
3. ✅ All public APIs unchanged
4. ✅ Existing code requires **zero** modifications
5. ✅ Binary compatibility maintained
6. ✅ Source compatibility maintained

---

## 8. Alternatives Considered

### 8.1 Alternative 1: Add Info.plist to Test Target

**Approach**: Create Xcode project wrapper with Info.plist

**Implementation:**
```
Bleu.xcworkspace
├── Bleu (SPM package)
└── BleuTests.xcodeproj
    ├── Info.plist  ← Add here
    └── BleuTests target
```

**Pros:**
- ✅ Quick fix
- ✅ No code changes required
- ✅ Tests can run with real BLE

**Cons:**
- ❌ Defeats SPM's purpose (pure Swift build system)
- ❌ Requires Xcode (not cross-platform)
- ❌ Tests still need BLE hardware
- ❌ Cannot run in CI/CD without BLE
- ❌ Poor developer experience
- ❌ Doesn't solve testability problem
- ❌ Linux/Windows contributors cannot test

**Verdict**: **Rejected** - Solves TCC crash but doesn't enable proper testing

### 8.2 Alternative 2: Skip Tests That Need BLE

**Approach**: Use `#if canImport(CoreBluetooth)` to conditionally skip tests

**Implementation:**
```swift
#if canImport(CoreBluetooth) && !RUNNING_IN_CI
@Test func testBLE() async throws {
    let system = BLEActorSystem()
    // ... test code ...
}
#endif
```

**Pros:**
- ✅ Simple implementation
- ✅ No architecture changes
- ✅ Tests don't crash

**Cons:**
- ❌ No actual testing of BLE logic
- ❌ Extremely poor test coverage
- ❌ Cannot catch BLE-related bugs
- ❌ Tests become documentation, not validation
- ❌ False sense of security

**Verdict**: **Rejected** - Defeats the entire purpose of having tests

### 8.3 Alternative 3: Conditional Compilation

**Approach**: Use `#if DEBUG` to avoid BLE initialization in tests

**Implementation:**
```swift
public init() {
    #if DEBUG
    // Don't create CB managers in debug builds
    #else
    self.localPeripheral = LocalPeripheralActor()
    self.localCentral = LocalCentralActor()
    #endif
}
```

**Pros:**
- ✅ No protocol layer needed
- ✅ Simple code changes

**Cons:**
- ❌ Cannot test production code paths
- ❌ Debug vs Release behavior differs (dangerous!)
- ❌ Fragile preprocessor conditionals throughout codebase
- ❌ Harder to maintain
- ❌ Anti-pattern in Swift

**Verdict**: **Rejected** - Creates debug/release parity issues

### 8.4 Alternative 4: Subclass-Based Mocking

**Approach**: Make BLEActorSystem methods `open`, subclass for testing

**Implementation:**
```swift
open class BLEActorSystem {
    open func connect(...) { /* real impl */ }
}

class MockBLEActorSystem: BLEActorSystem {
    override func connect(...) { /* mock impl */ }
}
```

**Pros:**
- ✅ Familiar OOP pattern
- ✅ Less boilerplate than protocols

**Cons:**
- ❌ **Swift actors cannot be subclassed** (fundamental limitation)
- ❌ Breaks encapsulation
- ❌ Fragile inheritance hierarchy
- ❌ Not Swift best practice
- ❌ Doesn't work with actor isolation

**Verdict**: **Rejected** - Incompatible with Swift's actor model

### 8.5 Why Protocol-Oriented Approach is Superior

**Comparison Table:**

| Aspect | Protocol-Oriented | Info.plist | Skip Tests | Conditional | Subclassing |
|--------|------------------|------------|------------|-------------|-------------|
| Fixes TCC crash | ✅ Yes | ✅ Yes | ✅ Yes | ✅ Yes | ❌ No (actors) |
| Enables unit testing | ✅ Yes | ❌ No | ❌ No | ⚠️ Partial | ❌ No |
| No hardware required | ✅ Yes | ❌ No | ⚠️ Skipped | ⚠️ Partial | ❌ No |
| CI/CD friendly | ✅ Yes | ❌ No | ❌ No | ⚠️ Partial | ❌ No |
| Cross-platform | ✅ Yes | ❌ No | ⚠️ Partial | ⚠️ Partial | ❌ No |
| Swift best practice | ✅ Yes | ❌ No | ❌ No | ❌ No | ❌ No |
| Actor compatible | ✅ Yes | ✅ Yes | ✅ Yes | ✅ Yes | ❌ No |
| Future-proof | ✅ Yes | ❌ No | ❌ No | ❌ No | ❌ No |

**Protocol-Oriented Advantages:**

1. ✅ **Compile-time Safety**: Protocol conformance checked by compiler
2. ✅ **Clear Contracts**: Protocol defines exact interface
3. ✅ **Multiple Implementations**: Production, mock, future (BlueZ, Windows)
4. ✅ **Complete Testability**: Full control over mock behavior
5. ✅ **Actor-Compatible**: Works perfectly with Swift's actor model
6. ✅ **Swift Best Practice**: Aligns with Swift's protocol-oriented design philosophy
7. ✅ **Future-Proof**: Foundation for cross-platform support

---

## 9. Risks and Mitigation

### 9.1 Risk: Breaking Changes

**Description**: Refactoring might inadvertently break existing code

**Likelihood**: Medium
**Impact**: High
**Severity**: Critical if occurs

**Mitigation Strategies:**
1. ✅ Maintain exact public API surface (no signature changes)
2. ✅ Add new features (factory methods) without removing old ones
3. ✅ Comprehensive testing before merge (all Examples must work)
4. ✅ Automated API compatibility checks
5. ✅ Deprecation warnings instead of removal (if needed)
6. ✅ Clear rollback plan: revert to Phase 1 only (just protocols)

**Rollback Plan:**
- If issues found in Phase 3+: Revert BLEActorSystem changes, keep protocols
- Keep old LocalPeripheralActor/LocalCentralActor as fallback
- Can release protocols alone if needed (Phase 1-2 standalone)

### 9.2 Risk: Performance Regression

**Description**: Protocol indirection might slow BLE operations

**Likelihood**: Low
**Impact**: Medium
**Severity**: Medium

**Analysis:**
- Protocol dispatch is optimized by Swift compiler (witness tables)
- Most BLE operations are I/O bound (hardware latency >> protocol overhead)
- Expected overhead: <1% (protocol dispatch is nanoseconds, BLE is milliseconds)

**Mitigation Strategies:**
1. ✅ Benchmark critical paths before and after
2. ✅ Profile using Instruments
3. ✅ Accept <5% performance hit for testability (well worth it)
4. ✅ Monitor real-world usage after release

**Measurement Plan:**
```swift
// Benchmark: Time to connect + discover + RPC
let start = Date()
let actors = try await system.discover(TestActor.self)
let value = try await actors[0].getValue()
let elapsed = Date().timeIntervalSince(start)

// Before: ~2.5s typical
// After: Should be < 2.65s (< 5% regression)
```

### 9.3 Risk: Mock Divergence

**Description**: Mock behavior differs from real CoreBluetooth

**Likelihood**: Medium
**Impact**: Medium
**Severity**: Medium

**Scenarios Where Mocks Might Differ:**
- Timing/latency (mocks might be too fast)
- Error conditions (mocks might not cover all CB errors)
- State transitions (CB has complex state machine)
- Delegate callback ordering

**Mitigation Strategies:**
1. ✅ Keep mocks simple and predictable
2. ✅ Comprehensive integration tests with real BLE (Hardware/)
3. ✅ Document mock limitations clearly
4. ✅ Regular testing on real hardware
5. ✅ Mock based on CoreBluetooth documentation
6. ✅ Community feedback to improve mocks

**Documentation:**
```swift
/// Mock Limitations:
/// - Timing is instant (real BLE has latency)
/// - State transitions are simplified
/// - Does not simulate signal strength/RSSI changes
/// - Always succeeds unless configured to fail
/// - See Integration tests for realistic scenarios
```

### 9.4 Risk: Increased Complexity

**Description**: More code to maintain (protocols + mocks + wrappers)

**Likelihood**: High (certain)
**Impact**: Low
**Severity**: Low

**Complexity Metrics:**
- New files: ~10 files
- New lines of code: ~3,000 LOC
- Maintenance burden: +20%

**Justification:**
- ✅ Benefits far outweigh complexity cost
- ✅ Standard industry practice (all major frameworks do this)
- ✅ Complexity is well-organized and documented
- ✅ Enables contributors to test their changes
- ✅ Reduces debugging time in the long run

**Mitigation Strategies:**
1. ✅ Clear documentation at every level
2. ✅ Well-organized file structure
3. ✅ Comprehensive code comments
4. ✅ Examples of usage patterns
5. ✅ CLAUDE.md guidance for contributors

### 9.5 Risk: Implementation Time

**Description**: 5-week timeline might be optimistic

**Likelihood**: Medium
**Impact**: Low
**Severity**: Low

**Contingency Plans:**
1. ✅ Phased approach allows early delivery
   - Can ship Phase 1-3, defer 4-5 if needed
   - Each phase delivers standalone value
2. ✅ Built-in buffer time in estimates
3. ✅ Can parallelize some tasks
4. ✅ Community contributions possible for docs

**Minimum Viable Delivery:**
- Phase 1-3 only: Protocols + Mocks + Refactored BLEActorSystem
- Phase 4-5 can follow in subsequent release
- Core functionality delivered in 3 weeks worst case

---

## 10. Future Enhancements

### 10.1 Cross-Platform Support

**Foundation Laid by This Refactoring:**
- Protocol abstraction allows different implementations
- No CoreBluetooth types in public API
- UUID-based instead of CBUUID-based
- Platform-agnostic architecture

**Potential Future Implementations:**

```swift
// Linux BlueZ support
#if os(Linux)
class BlueZPeripheralManager: BLEPeripheralManagerProtocol {
    // Use BlueZ DBus API
}

class BlueZCentralManager: BLECentralManagerProtocol {
    // Use BlueZ DBus API
}

extension BLEActorSystem {
    static func production() -> BLEActorSystem {
        #if os(Linux)
        return BLEActorSystem(
            peripheralManager: BlueZPeripheralManager(),
            centralManager: BlueZCentralManager()
        )
        #else
        return BLEActorSystem(
            peripheralManager: CoreBluetoothPeripheralManager(),
            centralManager: CoreBluetoothCentralManager()
        )
        #endif
    }
}
#endif
```

**Impact**: Enable Bleu on Linux servers, Raspberry Pi, IoT devices

### 10.2 BLE Simulator

**Use Case**: Development without hardware

```swift
/// Simulates realistic BLE environment
public class BLESimulator {
    /// Create a virtual peripheral with services
    public func createVirtualPeripheral(
        named: String,
        services: [ServiceMetadata]
    ) -> MockPeripheralManager

    /// Create a virtual central
    public func createVirtualCentral() -> MockCentralManager

    /// Simulate proximity (affects RSSI)
    public func simulateProximity(rssi: Int)

    /// Simulate interference (packet loss)
    public func simulateInterference(dropRate: Double)

    /// Simulate movement (changing RSSI)
    public func simulateMovement(
        from: Int,
        to: Int,
        duration: TimeInterval
    )
}

// Usage:
let simulator = BLESimulator()
let peripheral = simulator.createVirtualPeripheral(
    named: "Sensor",
    services: [...]
)
let central = simulator.createVirtualCentral()

simulator.simulateProximity(rssi: -70)  // Far away
simulator.simulateInterference(dropRate: 0.1)  // 10% packet loss

// Test how app handles poor BLE conditions
```

### 10.3 Performance Testing

**Scenario-Based Testing:**

```swift
// Test with slow BLE conditions
let config = MockCentralManager.Configuration(
    connectionDelay: 5.0,      // Slow connection
    discoveryDelay: 2.0,       // Slow discovery
    scanDelay: 1.0            // Slow scanning
)
let system = BLEActorSystem.mock(centralConfig: config)

// Measure performance under poor conditions
let start = Date()
try await system.connect(to: id, as: MyActor.self)
let elapsed = Date().timeIntervalSince(start)

#expect(elapsed >= 5.0)  // Verify timeout handling
#expect(elapsed < 10.0)  // Verify reasonable fallback
```

### 10.4 Chaos Testing

**Fault Injection for Resilience Testing:**

```swift
/// Chaotic mock that randomly fails operations
class ChaoticMockCentral: MockCentralManager {
    var failureRate: Double = 0.2

    override func connect(
        to peripheralID: UUID,
        timeout: TimeInterval
    ) async throws {
        // Randomly fail 20% of connections
        if Double.random(in: 0...1) < failureRate {
            throw BleuError.connectionFailed("Chaos!")
        }
        try await super.connect(to: peripheralID, timeout: timeout)
    }

    // Similar for all operations
}

// Test resilience to random failures
let system = BLEActorSystem(
    peripheralManager: MockPeripheralManager(),
    centralManager: ChaoticMockCentral()
)

// App should handle failures gracefully
```

### 10.5 Record & Replay

**Record Real BLE Sessions for Replay:**

```swift
/// Records all BLE operations to a file
class RecordingCentralManager: BLECentralManagerProtocol {
    private let wrapped: CoreBluetoothCentralManager
    private var recorder: BLEEventRecorder

    func connect(to peripheralID: UUID, timeout: TimeInterval) async throws {
        recorder.record(.connectionAttempt(peripheralID, timeout))

        do {
            try await wrapped.connect(to: peripheralID, timeout: timeout)
            recorder.record(.connectionSuccess(peripheralID))
        } catch {
            recorder.record(.connectionFailed(peripheralID, error))
            throw error
        }
    }

    // Record all operations...
}

// Later: Replay exact same sequence for debugging
class ReplayingCentralManager: BLECentralManagerProtocol {
    private let events: [RecordedBLEEvent]
    private var eventIndex = 0

    func connect(to peripheralID: UUID, timeout: TimeInterval) async throws {
        // Replay recorded behavior exactly
        let event = events[eventIndex]
        eventIndex += 1

        switch event {
        case .connectionSuccess:
            return
        case .connectionFailed(_, let error):
            throw error
        default:
            fatalError("Unexpected event")
        }
    }
}

// Usage:
// 1. Record session with real BLE
let recording = try await recordBLESession {
    // User actions that triggered bug
}

// 2. Replay for debugging (deterministic!)
let replay = ReplayingCentralManager(events: recording.events)
let system = BLEActorSystem(
    peripheralManager: MockPeripheralManager(),
    centralManager: replay
)
```

---

## 11. Success Metrics

### 11.1 Immediate Success Criteria (Post-Implementation)

**After Implementation Completes:**
- ✅ `swift test` runs without TCC crash
- ✅ Test suite completes in <10 seconds (mock tests only)
- ✅ 100% backward compatibility maintained
- ✅ Zero changes required in Examples/
- ✅ All existing tests pass
- ✅ CI/CD pipeline runs successfully
- ✅ No performance regression (< 5%)

### 11.2 Quality Metrics

**Code Coverage:**
- **Before**: ~40% (excluding BLE code that couldn't be tested)
- **Target**: >80% overall
- **Improvement**: +40 percentage points absolute

**Test Reliability:**
- **Before**: Flaky (dependent on BLE hardware state)
- **After**:
  - 0% flaky tests (deterministic mocks)
  - 100% reproducible test failures
  - Consistent CI/CD results

**Test Performance:**
- **Before**:
  - Unit tests: N/A (couldn't run)
  - Integration tests: ~60 seconds (with hardware)
- **After**:
  - Unit tests: <5 seconds (mock-based)
  - Integration tests: <10 seconds (mock-based)
  - Hardware tests: Still ~60s (but optional)

**Developer Experience:**
- Test iteration time: <5 seconds (vs. minutes before)
- No BLE permissions needed for development
- Clear error messages from mocks
- Easy to understand test failures

### 11.3 Long-Term Success Criteria (6 Months After Release)

**Adoption Metrics:**
- Community adoption of testing patterns
- Contributions leveraging mock infrastructure
- Positive feedback on testing experience

**Quality Metrics:**
- Reduced bug reports related to BLE edge cases
- Faster bug fix turnaround (easier to reproduce with mocks)
- Higher contributor confidence

**Codebase Health:**
- Maintained >80% code coverage
- All new features include mock-based tests
- Documentation kept up to date

---

## 12. Conclusion

The Protocol-Oriented Testing Architecture refactoring solves the immediate TCC crash problem while delivering substantial long-term benefits that extend far beyond testing.

### Immediate Value

**Problems Solved:**
- ✅ Fixes `swift test` TCC crash
- ✅ Enables unit testing without BLE hardware
- ✅ Improves development workflow dramatically
- ✅ Makes CI/CD testing possible

**Zero Cost:**
- ✅ 100% backward compatible
- ✅ No changes required for existing users
- ✅ No performance regression
- ✅ No breaking changes

### Architectural Value

**Design Improvements:**
- ✅ Proper separation of concerns
- ✅ Clear abstraction layers
- ✅ Protocol-oriented architecture (Swift best practice)
- ✅ Dependency injection pattern
- ✅ Better code organization

**Future-Proofing:**
- ✅ Foundation for cross-platform support (Linux, Windows)
- ✅ Support for alternative BLE stacks (BlueZ)
- ✅ Extensible for new implementations
- ✅ Testable by design

### Testing Value

**Comprehensive Testing:**
- ✅ Unit tests without hardware
- ✅ Integration tests with mocks
- ✅ Edge case and error scenario testing
- ✅ Performance and chaos testing
- ✅ CI/CD friendly

**Developer Experience:**
- ✅ Fast test iteration (<5s)
- ✅ No TCC permissions needed
- ✅ Deterministic test results
- ✅ Easy to debug failures
- ✅ Clear error messages

### Minimal Risk

**Safety:**
- ✅ Backward compatible (guaranteed)
- ✅ Phased implementation (incremental delivery)
- ✅ Rollback plan at every phase
- ✅ Industry-standard patterns
- ✅ Comprehensive testing

**Proven Approach:**
- ✅ Used by major frameworks (URLSession, CoreData, etc.)
- ✅ Swift best practices
- ✅ Well-documented patterns
- ✅ Community-accepted approach

### Final Recommendation

**This refactoring transforms Bleu 2 from:**
- ❌ Untestable framework dependent on BLE hardware

**To:**
- ✅ Well-architected, thoroughly tested, future-proof distributed actor system

**That happens to use BLE as its transport layer** (but could use others!)

The benefits far outweigh the implementation cost, and the phased approach minimizes risk while delivering incremental value. This is the **right architectural decision** for Bleu's long-term success.

---

## Appendices

### Appendix A: File Checklist

**New Files to Create:**

Protocols:
- `Sources/Bleu/Protocols/BLEPeripheralManagerProtocol.swift`
- `Sources/Bleu/Protocols/BLECentralManagerProtocol.swift`

Implementations:
- `Sources/Bleu/Implementations/CoreBluetoothPeripheralManager.swift`
- `Sources/Bleu/Implementations/CoreBluetoothCentralManager.swift`

Mocks:
- `Sources/Bleu/Mocks/MockPeripheralManager.swift`
- `Sources/Bleu/Mocks/MockCentralManager.swift`

Tests:
- `Tests/BleuTests/Unit/` (directory)
- `Tests/BleuTests/Integration/` (directory)
- `Tests/BleuTests/Hardware/` (directory)
- `Tests/BleuTests/Mocks/` (directory)

Documentation:
- `docs/design/PROTOCOL_ORIENTED_TESTING_ARCHITECTURE.md` (this document)
- `docs/guides/TESTING.md`

**Files to Modify:**

Core:
- `Sources/Bleu/Core/BLEActorSystem.swift` (major refactoring)
- `Sources/Bleu/LocalActors/LocalPeripheralActor.swift` (deprecate/wrap)
- `Sources/Bleu/LocalActors/LocalCentralActor.swift` (deprecate/wrap)

Build:
- `Package.swift` (test target updates if needed)

Documentation:
- `README.md` (testing section)
- `CLAUDE.md` (architecture updates)
- `docs/internal/REPOSITORY_GUIDELINES.md` (testing guidelines)
- `Examples/README.md` (testing examples)

**Files to Deprecate (Eventually):**
- `Sources/Bleu/LocalActors/LocalPeripheralActor.swift` → CoreBluetoothPeripheralManager
- `Sources/Bleu/LocalActors/LocalCentralActor.swift` → CoreBluetoothCentralManager

### Appendix B: Protocol Method Mapping

**BLEPeripheralManagerProtocol → CBPeripheralManager:**

| Protocol Method | CoreBluetooth Equivalent | Notes |
|----------------|--------------------------|-------|
| `events` | Custom AsyncChannel | From delegate callbacks |
| `state` | `state` property | Direct mapping |
| `waitForPoweredOn()` | `state` + delegate | Async wrapper |
| `add(_ service)` | `add(_ service: CBMutableService)` | Convert ServiceMetadata → CBMutableService |
| `startAdvertising(_)` | `startAdvertising(_ advertisementData:)` | Convert AdvertisementData → [String: Any] |
| `stopAdvertising()` | `stopAdvertising()` | Direct call |
| `isAdvertising` | `isAdvertising` property | Direct mapping |
| `updateValue(_:for:to:)` | `updateValue(_:for:onSubscribedCentrals:)` | UUID → CBCentral mapping |
| `subscribedCentrals(for:)` | Track via delegate | Manual tracking needed |

**BLECentralManagerProtocol → CBCentralManager:**

| Protocol Method | CoreBluetooth Equivalent | Notes |
|----------------|--------------------------|-------|
| `events` | Custom AsyncChannel | From delegate callbacks |
| `state` | `state` property | Direct mapping |
| `waitForPoweredOn()` | `state` + delegate | Async wrapper |
| `scanForPeripherals(withServices:timeout:)` | `scanForPeripherals(withServices:options:)` | Add timeout logic |
| `stopScan()` | `stopScan()` | Direct call |
| `connect(to:timeout:)` | `connect(_:options:)` | Add timeout logic |
| `disconnect(from:)` | `cancelPeripheralConnection(_)` | UUID → CBPeripheral mapping |
| `isConnected(_)` | Track manually | No direct CB API |
| `discoverServices(for:serviceUUIDs:)` | `CBPeripheral.discoverServices(_)` | Peripheral method |
| `discoverCharacteristics(for:in:characteristicUUIDs:)` | `CBPeripheral.discoverCharacteristics(_:for:)` | Peripheral method |
| `readValue(for:in:)` | `CBPeripheral.readValue(for:)` | Peripheral method |
| `writeValue(_:for:in:type:)` | `CBPeripheral.writeValue(_:for:type:)` | Peripheral method |
| `setNotifyValue(_:for:in:)` | `CBPeripheral.setNotifyValue(_:for:)` | Peripheral method |
| `maximumWriteValueLength(for:type:)` | `CBPeripheral.maximumWriteValueLength(for:)` | Peripheral method |

### Appendix C: Test Coverage Goals

**By Component:**

| Component | Current Coverage | Target Coverage | Priority |
|-----------|-----------------|-----------------|----------|
| BLEActorSystem | 20% | 90% | P0 |
| ServiceMapper | 80% | 95% | P1 |
| MethodRegistry | 70% | 90% | P1 |
| BLETransport | 50% | 85% | P1 |
| EventBridge | 60% | 85% | P2 |
| LocalPeripheralActor | 0% (untestable) | 80% (via protocol) | P0 |
| LocalCentralActor | 0% (untestable) | 80% (via protocol) | P0 |
| UUID Extensions | 90% | 95% | P2 |
| BleuError | 85% | 90% | P2 |

**Overall Target**: >80% code coverage with mock-based tests

### Appendix D: References

**Swift Evolution Proposals:**
- [SE-0336: Distributed Actor Isolation](https://github.com/apple/swift-evolution/blob/main/proposals/0336-distributed-actor-isolation.md)
- [SE-0296: Async/await](https://github.com/apple/swift-evolution/blob/main/proposals/0296-async-await.md)

**Apple Documentation:**
- [CoreBluetooth Framework](https://developer.apple.com/documentation/corebluetooth)
- [CBCentralManager](https://developer.apple.com/documentation/corebluetooth/cbcentralmanager)
- [CBPeripheralManager](https://developer.apple.com/documentation/corebluetooth/cbperipheralmanager)

**Design Patterns:**
- Gang of Four - Design Patterns (Protocol = Strategy Pattern)
- Dependency Injection (Martin Fowler)
- Protocol-Oriented Programming in Swift (WWDC 2015)

**Related Issues:**
- TCC Privacy Violation Crash (this document)
- Discovery Connection Bug Fix (DISCOVERY_CONNECTION_FIX.md)

---

**Document Version**: 1.0
**Date**: 2025-11-04
**Author**: Claude Code Assistant
**Status**: Proposed for Review
**Target Release**: Bleu 2.1
**Estimated Effort**: 5 weeks (phased implementation)
