# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Bleu 2 is a next-generation Swift framework for Bluetooth Low Energy (BLE) communication that leverages Swift's Distributed Actor system to provide transparent, type-safe communication between BLE Peripherals and Centrals. It completely abstracts away the complexity of CoreBluetooth, allowing developers to write BLE applications as if they were simple distributed function calls.

## Core Philosophy

**"Make BLE communication as simple as calling a function"**

Developers should focus on their business logic, not BLE complexity. Bleu 2 handles all the details:
- Service/Characteristic management → Automatic
- UUID generation → Automatic
- Connection management → Automatic
- Data serialization → Automatic
- Error recovery → Automatic

## Architecture

### 4-Layer Architecture

```
┌──────────────────────────────────────────┐
│          User Application Layer          │
│   distributed actor MyPeripheral { }      │  ← Developers write only this
└────────────────▲─────────────────────────┘
                 │ Transparent RPC
┌────────────────┴─────────────────────────┐
│         Bleu 2 Framework                 │
├──────────────────────────────────────────┤
│  Layer 4: Public API                     │
│    - BLEActorSystem                      │  ← Distributed Actor System
│    - Automatic service registration      │
├──────────────────────────────────────────┤
│  Layer 3: Auto-Mapping System            │
│    - ServiceMapper                       │  ← Method → Characteristic mapping
│    - MethodRegistry                      │
├──────────────────────────────────────────┤
│  Layer 2: Message Transport              │
│    - BLETransport                        │  ← Reliability & flow control
│    - MessageRouter                       │
├──────────────────────────────────────────┤
│  Layer 1: BLE Abstraction                │
│    - LocalPeripheralActor                │  ← CoreBluetooth wrappers
│    - LocalCentralActor                   │
└──────────────────────────────────────────┘
```

### Key Design Principles

1. **Separation of Concerns**: CoreBluetooth delegates never directly interact with distributed actors
2. **Message Passing**: Local actors communicate with distributed actors via AsyncChannel
3. **Actor Isolation**: No locks needed - all synchronization via actor boundaries
4. **Type Safety**: Full type preservation across BLE communication

### Critical Architecture Pattern

The framework follows a strict delegate isolation pattern to maintain Swift 6 concurrency safety:

```
CoreBluetooth Delegate Callbacks (Main Queue)
    ↓
DelegateProxy (converts to AsyncChannel events)
    ↓
LocalActor (actor-isolated processing)
    ↓
EventBridge (routes events by UUID)
    ↓
Distributed Actor (business logic)
```

**Why this matters**:
- CoreBluetooth delegates run on main queue, not in actor context
- Distributed actors cannot be called directly from non-isolated contexts
- DelegateProxy + AsyncChannel bridges the gap safely
- This pattern eliminates all data races without locks

## Usage

### Peripheral Implementation (3 lines!)

```swift
distributed actor TemperatureSensor {
    typealias ActorSystem = BLEActorSystem
    
    distributed func readTemperature() async -> Double {
        return 22.5
    }
}

// That's it! Start advertising:
let sensor = TemperatureSensor(actorSystem: system)
try await system.startAdvertising(sensor)
```

### Central Implementation (3 lines!)

```swift
// Discover and connect
let sensors = try await system.discover(TemperatureSensor.self)

// Use it like a local object
let temp = try await sensors[0].readTemperature()
```

## Connection Flow

### Phase 1: Peripheral Setup & Advertisement
1. Extract distributed methods from actor type
2. Generate deterministic Service/Characteristic UUIDs
3. Create CBMutableService with characteristics
4. Start advertising with service UUID

### Phase 2: Central Discovery & Connection
1. Calculate expected service UUID from actor type
2. Scan for peripherals advertising that service
3. Connect and discover services/characteristics
4. Create remote actor proxy

### Phase 3: Transparent Communication
1. Method calls on remote actor trigger RPC
2. Arguments serialized and sent via BLE
3. Response deserialized and returned
4. All async/await with full type safety

## Implementation Guide

### File Structure

```
Sources/Bleu/
├── Actors/                         # Distributed actor protocols
├── Core/
│   ├── BLEActorSystem.swift        # Distributed actor system (DistributedActorSystem)
│   ├── BleuConfiguration.swift     # System configuration
│   ├── BleuError.swift             # Error types
│   ├── BleuTypes.swift             # Common types
│   ├── EventBridge.swift           # Routes BLE events to actors
│   └── InstanceRegistry.swift      # Tracks actor instances by UUID
├── LocalActors/
│   ├── LocalPeripheralActor.swift          # CBPeripheralManager wrapper
│   ├── LocalCentralActor.swift             # CBCentralManager wrapper
│   ├── PeripheralManagerDelegateProxy.swift # Delegate → AsyncChannel
│   └── CentralManagerDelegateProxy.swift    # Delegate → AsyncChannel
├── Mapping/
│   ├── ServiceMapper.swift         # Auto service generation from types
│   └── MethodRegistry.swift        # Distributed method registration
├── Transport/
│   └── BLETransport.swift          # Packet fragmentation & reliability
├── Extensions/
│   └── AsyncChannel.swift          # Event streaming utilities
└── Utils/
    └── Logger.swift                # Logging infrastructure

Examples/
├── BasicUsage/
│   ├── SensorServer.swift          # Peripheral example
│   └── SensorClient.swift          # Central example
├── SwiftUIApp/                     # Full SwiftUI app example
└── Common/
    └── PeripheralActors.swift      # Shared actor definitions
```

### Core Components & Data Flow

#### BLEActorSystem (Sources/Bleu/Core/BLEActorSystem.swift)
- Implements `DistributedActorSystem` protocol
- **Actor ID = UUID**: Each peripheral is uniquely identified
- Manages actor lifecycle and `remoteCall()` for RPC
- Holds `InstanceRegistry` for tracking local actor instances
- Uses `ProxyManager` actor to track remote peripheral connections
- Coordinates with `EventBridge` for BLE event routing

#### EventBridge (Sources/Bleu/Core/EventBridge.swift)
- Routes CoreBluetooth events from delegates to appropriate actors
- Bridges the gap between delegate callbacks and actor message passing
- Ensures no direct coupling between CoreBluetooth delegates and distributed actors

#### LocalPeripheralActor (Sources/Bleu/LocalActors/LocalPeripheralActor.swift)
- Actor wrapping `CBPeripheralManager`
- Uses `PeripheralManagerDelegateProxy` to convert delegate callbacks to AsyncChannel events
- Manages service/characteristic setup and advertisement
- **Critical**: Delegates NEVER call distributed actor methods directly

#### LocalCentralActor (Sources/Bleu/LocalActors/LocalCentralActor.swift)
- Actor wrapping `CBCentralManager`
- Uses `CentralManagerDelegateProxy` for delegate → AsyncChannel conversion
- Manages scanning, connection, and service/characteristic discovery
- Connection state tracked via actor isolation (no locks needed)

#### ServiceMapper (Sources/Bleu/Mapping/ServiceMapper.swift)
- Extracts distributed methods via Swift Mirror API reflection
- Generates deterministic UUIDs using UUID5 algorithm:
  - Service UUID: `UUID5(namespace, "\(ActorType).BLEService")`
  - Characteristic UUID: `UUID5(ServiceUUID, "\(ActorType).\(methodName)")`
- Creates `ServiceMetadata` for automatic BLE service setup
- Maps Swift distributed methods to CoreBluetooth characteristics

#### BLETransport (Sources/Bleu/Transport/BLETransport.swift)
- Handles packet fragmentation for data larger than MTU
- Binary packet format with 24-byte header (UUID + sequence + total + CRC)
- Provides reliability with checksums and reassembly
- Adaptive MTU negotiation (typically 185-512 bytes)

---

## CoreBluetooth Integration

Bleu wraps Apple's CoreBluetooth framework to provide a distributed actor interface. Understanding CoreBluetooth fundamentals is crucial for working with Bleu's LocalCentralActor and LocalPeripheralActor.

### CBCentralManager (Central Role)

**Purpose**: Scans for, discovers, connects to, and manages peripheral devices.

**Key Requirements**:
- Must be in `.poweredOn` state before operations
- Delegate runs on specified queue (or main queue if nil)
- All operations are asynchronous via delegate callbacks

**Essential Operations in LocalCentralActor**:

```swift
// 1. Initialization
let centralManager = CBCentralManager(
    delegate: delegateProxy,
    queue: nil,  // nil = main queue
    options: [
        CBCentralManagerOptionShowPowerAlertKey: true
    ]
)

// 2. Scanning for peripherals
centralManager.scanForPeripherals(
    withServices: [serviceUUID],  // Filter by service UUID
    options: [
        CBCentralManagerScanOptionAllowDuplicatesKey: false
    ]
)

// 3. Connecting to a peripheral
centralManager.connect(
    peripheral,
    options: [
        CBConnectPeripheralOptionNotifyOnConnectionKey: true,
        CBConnectPeripheralOptionNotifyOnDisconnectionKey: true
    ]
)

// 4. Disconnecting
centralManager.cancelPeripheralConnection(peripheral)

// 5. Retrieving known peripherals (by UUID)
let peripherals = centralManager.retrievePeripherals(
    withIdentifiers: [uuid]
)
```

**Critical Delegate Methods** (implemented in CentralManagerDelegateProxy):
- `centralManagerDidUpdateState(_:)` - **REQUIRED** - Monitors Bluetooth state
- `centralManager(_:didDiscover:advertisementData:rssi:)` - Peripheral discovered
- `centralManager(_:didConnect:)` - Connection established
- `centralManager(_:didDisconnectPeripheral:error:)` - Connection lost
- `centralManager(_:didFailToConnect:error:)` - Connection failed

### CBPeripheralManager (Peripheral Role)

**Purpose**: Publishes services and advertises them to central devices.

**Key Requirements**:
- Must be in `.poweredOn` state before operations
- Services must be added before advertising
- Delegate handles read/write requests from centrals

**Essential Operations in LocalPeripheralActor**:

```swift
// 1. Initialization
let peripheralManager = CBPeripheralManager(
    delegate: delegateProxy,
    queue: nil,
    options: [
        CBPeripheralManagerOptionShowPowerAlertKey: true
    ]
)

// 2. Create and add service
let service = CBMutableService(
    type: serviceUUID,
    primary: true
)
service.characteristics = [characteristic1, characteristic2]
peripheralManager.add(service)

// 3. Start advertising
peripheralManager.startAdvertising([
    CBAdvertisementDataServiceUUIDsKey: [serviceUUID],
    CBAdvertisementDataLocalNameKey: "Device Name"
])

// 4. Stop advertising
peripheralManager.stopAdvertising()

// 5. Respond to read/write requests
peripheralManager.respond(
    to: request,
    withResult: .success
)

// 6. Send characteristic value updates
peripheralManager.updateValue(
    data,
    for: characteristic,
    onSubscribedCentrals: nil  // nil = all subscribed
)
```

**Critical Delegate Methods** (implemented in PeripheralManagerDelegateProxy):
- `peripheralManagerDidUpdateState(_:)` - **REQUIRED** - Monitors Bluetooth state
- `peripheralManager(_:didAdd:error:)` - Service added confirmation
- `peripheralManagerDidStartAdvertising(_:error:)` - Advertising started
- `peripheralManager(_:didReceiveRead:)` - Handle read request
- `peripheralManager(_:didReceiveWrite:)` - Handle write request
- `peripheralManager(_:central:didSubscribeTo:)` - Central subscribed to notifications

### CBPeripheral (Remote Device Operations)

**Purpose**: Represents a remote peripheral and provides service/characteristic access.

**Essential Operations**:

```swift
// 1. Discover services
peripheral.discoverServices([serviceUUID])

// 2. Discover characteristics (after services discovered)
peripheral.discoverCharacteristics(
    [characteristicUUID],
    for: service
)

// 3. Read characteristic value
peripheral.readValue(for: characteristic)

// 4. Write characteristic value
peripheral.writeValue(
    data,
    for: characteristic,
    type: .withResponse  // or .withoutResponse
)

// 5. Enable notifications
peripheral.setNotifyValue(true, for: characteristic)

// 6. Get maximum write length
let maxLength = peripheral.maximumWriteValueLength(
    for: .withResponse
)
```

**Delegate Callbacks** (CBPeripheralDelegate):
- `peripheral(_:didDiscoverServices:)` - Services discovered
- `peripheral(_:didDiscoverCharacteristicsFor:error:)` - Characteristics discovered
- `peripheral(_:didUpdateValueFor:error:)` - Value updated (read or notification)
- `peripheral(_:didWriteValueFor:error:)` - Write completed
- `peripheral(_:didUpdateNotificationStateFor:error:)` - Notification state changed

### Delegate Pattern Integration

**Why Delegates are Problematic for Actors**:

1. **Main Queue Execution**: CoreBluetooth delegates run on main queue (if no queue specified)
2. **Non-Isolated Context**: Delegates are not actor-isolated
3. **Cannot Call Distributed Methods**: Distributed actors can't be called from non-isolated contexts

**Bleu's Solution: DelegateProxy Pattern**

```
CoreBluetooth Delegate (Main Queue)
    ↓
DelegateProxy (converts to events)
    ↓
AsyncChannel<BLEEvent>
    ↓
LocalActor (actor-isolated processing)
    ↓
EventBridge (routes to correct actor)
    ↓
Distributed Actor (business logic)
```

**Example: CentralManagerDelegateProxy**:

```swift
class CentralManagerDelegateProxy: NSObject, CBCentralManagerDelegate {
    private weak var actor: LocalCentralActor?

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String : Any],
        rssi RSSI: NSNumber
    ) {
        // Convert delegate callback to actor-safe message
        Task {
            await actor?.handlePeripheralDiscovered(
                peripheral: peripheral,
                rssi: RSSI.intValue
            )
        }
    }
}
```

**Why This Works**:
- DelegateProxy is a simple NSObject (no actor isolation)
- Converts callbacks to `Task { }` for actor context
- LocalActor processes events safely within actor boundary
- No locks needed - actor isolation provides thread safety

### Connection State Management

**CoreBluetooth Connection States** (CBPeripheralState):
- `.disconnected` - Not connected
- `.connecting` - Connection in progress
- `.connected` - Connected and ready
- `.disconnecting` - Disconnection in progress

**Bleu's State Tracking**:

```swift
// LocalCentralActor tracks connected peripherals
private var connectedPeripherals: [UUID: CBPeripheral] = [:]

// ProxyManager tracks active proxies (implies connected + services discovered)
private actor ProxyManager {
    private var peripheralProxies: [UUID: PeripheralActorProxy] = [:]
}
```

**State Invariants**:
```
connectedPeripherals[id] != nil
  ⟹ Peripheral is connected

proxyManager.hasProxy(id) == true
  ⟹ Connected AND services discovered AND proxy ready

Both are managed via actor isolation - no locks needed
```

### Error Handling

**CoreBluetooth Errors** (CBError, CBATTError):
- Connection errors (timeout, failed, etc.)
- ATT errors (read/write failures)
- State errors (powered off, unauthorized)

**Bleu Error Mapping**:

```swift
// CoreBluetooth → BleuError
switch cbError.code {
case .connectionTimeout:
    throw BleuError.connectionTimeout
case .peripheralDisconnected:
    throw BleuError.disconnected
case .unknown:
    throw BleuError.connectionFailed(cbError.localizedDescription)
// ... etc
}
```

### Best Practices for CoreBluetooth in Bleu

1. **Always Check State**: Verify `.poweredOn` before operations
2. **Use DelegateProxy**: Never call distributed actors from delegates directly
3. **Store Peripheral References**: Keep `CBPeripheral` instances alive (weak references cause disconnection)
4. **Handle Disconnections**: Implement reconnection logic in EventBridge
5. **MTU Awareness**: Respect `maximumWriteValueLength()` for data fragmentation
6. **Cleanup on Disconnect**: Remove proxies and unsubscribe from events

### Common Pitfalls

❌ **Calling Distributed Methods from Delegates**:
```swift
// WRONG - Will not compile
func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    try await distributedActor.handleConnection()  // ❌ Cannot call from non-isolated context
}
```

✅ **Correct - Use DelegateProxy + Actor**:
```swift
// DelegateProxy (non-isolated)
func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    Task {
        await localActor.handleConnection(peripheral.identifier)
    }
}

// LocalActor (actor-isolated)
func handleConnection(_ id: UUID) async {
    // Safe to process here
}
```

❌ **Not Storing Peripheral References**:
```swift
// WRONG - Peripheral may be deallocated
func scan() {
    centralManager.scanForPeripherals(...)
    // Peripheral discovered but not stored → may disconnect
}
```

✅ **Correct - Store in Dictionary**:
```swift
private var discoveredPeripherals: [UUID: CBPeripheral] = [:]

func didDiscover(_ peripheral: CBPeripheral) {
    discoveredPeripherals[peripheral.identifier] = peripheral  // Keep alive
}
```

---

## Development Workflow

### 1. Define Your Peripheral

```swift
distributed actor MyDevice {
    typealias ActorSystem = BLEActorSystem
    
    // Each distributed method becomes a BLE characteristic
    distributed func getValue() async -> Int { 42 }
    distributed func setValue(_ value: Int) async { }
    distributed func subscribe() async -> AsyncStream<Int> { }
}
```

### 2. Start Advertising

```swift
let device = MyDevice(actorSystem: system)
try await system.startAdvertising(device)
```

### 3. Discover & Connect from Central

```swift
let devices = try await system.discover(MyDevice.self)
let value = try await devices[0].getValue()
```

## Build & Test

### Build Commands
```bash
# Build the library in debug mode
swift build

# Build the demo executable
swift build --product BleuDemo

# Run the demo
swift run BleuDemo
```

### Test Commands
```bash
# Run all tests
swift test

# Run specific test suite
swift test --filter BleuV2SwiftTests
swift test --filter IntegrationTests
swift test --filter RPCTests

# Run a single test
swift test --filter ServiceMetadataTests
```

### Examples Package
```bash
# Build and run examples (from Examples/ directory)
swift run --package-path Examples SensorServer
swift run --package-path Examples SensorClient
swift run --package-path Examples BleuExampleApp
```

### Platform-specific
```bash
# iOS
xcodebuild -scheme Bleu -destination 'platform=iOS Simulator,name=iPhone 15 Pro'

# macOS
xcodebuild -scheme Bleu -destination 'platform=macOS'
```

## Platform Requirements

- iOS 18.0+
- macOS 15.0+
- watchOS 11.0+
- tvOS 18.0+
- Swift 6.1+
- Swift Testing framework (included in Swift 6 toolchain)

## Testing Architecture

### Overview

Bleu 2 uses a Protocol-Oriented Testing Architecture to enable hardware-free testing and solve TCC (Transparency, Consent, and Control) privacy violations that occur when Swift Package Manager test targets attempt to access CoreBluetooth APIs.

For comprehensive details, see [Protocol-Oriented Testing Architecture](../design/PROTOCOL_ORIENTED_TESTING_ARCHITECTURE.md).

### The TCC Problem

Swift Package Manager test targets **cannot** have Info.plist files, which are required by CoreBluetooth for privacy declarations. When tests instantiate `CBPeripheralManager` or `CBCentralManager`, the system triggers a TCC crash:

```
__TCC_CRASHING_DUE_TO_PRIVACY_VIOLATION__
NSBluetoothAlwaysUsageDescription key missing
```

### Solution: Protocol Abstraction + Dependency Injection

Bleu 2 solves this through a layered approach:

1. **Protocol Layer**: Define protocols abstracting all BLE operations
2. **Production Implementation**: Real CoreBluetooth wrappers (requires TCC permissions)
3. **Mock Implementation**: In-memory BLE simulation (no TCC, no hardware)
4. **Dependency Injection**: BLEActorSystem accepts any conforming implementation

### BLE Manager Protocols

#### BLEPeripheralManagerProtocol

Abstracts `CBPeripheralManager` operations for peripheral role:

```swift
public protocol BLEPeripheralManagerProtocol: Actor {
    /// Event stream for delegate callbacks
    var events: AsyncStream<BLEEvent> { get }

    /// Current Bluetooth state
    var state: CBManagerState { get async }

    /// Initialize the peripheral manager
    func initialize() async

    /// Wait for Bluetooth to be powered on
    func waitForPoweredOn() async -> CBManagerState

    /// Add a service to the peripheral
    func add(_ service: ServiceMetadata) async throws

    /// Start advertising with given data
    func startAdvertising(_ data: AdvertisementData) async throws

    /// Stop advertising
    func stopAdvertising() async

    /// Check if currently advertising
    var isAdvertising: Bool { get async }

    /// Update characteristic value and notify subscribers
    func updateValue(_ data: Data, for characteristicUUID: UUID, to centrals: [UUID]?) async throws -> Bool

    /// Get centrals subscribed to a characteristic
    func subscribedCentrals(for characteristicUUID: UUID) async -> [UUID]
}
```

#### BLECentralManagerProtocol

Abstracts `CBCentralManager` operations for central role:

```swift
public protocol BLECentralManagerProtocol: Actor {
    /// Event stream for delegate callbacks
    var events: AsyncStream<BLEEvent> { get }

    /// Current Bluetooth state
    var state: CBManagerState { get async }

    /// Initialize the central manager
    func initialize() async

    /// Wait for Bluetooth to be powered on
    func waitForPoweredOn() async -> CBManagerState

    /// Start scanning for peripherals with given service UUIDs
    func scanForPeripherals(withServices serviceUUIDs: [UUID]?) async throws

    /// Stop scanning
    func stopScan() async

    /// Connect to a peripheral
    func connect(peripheralID: UUID) async throws

    /// Disconnect from a peripheral
    func disconnect(peripheralID: UUID) async

    /// Retrieve connected peripherals
    func retrieveConnectedPeripherals(withServices serviceUUIDs: [UUID]) async -> [UUID]

    /// Retrieve peripherals by identifiers
    func retrievePeripherals(withIdentifiers identifiers: [UUID]) async -> [UUID]

    /// Write data to a characteristic
    func writeValue(_ data: Data, for characteristicUUID: UUID, peripheralID: UUID, type: CBCharacteristicWriteType) async throws

    /// Read value from a characteristic
    func readValue(for characteristicUUID: UUID, peripheralID: UUID) async throws -> Data

    /// Enable/disable notifications for a characteristic
    func setNotifyValue(_ enabled: Bool, for characteristicUUID: UUID, peripheralID: UUID) async throws
}
```

### Factory Methods

BLEActorSystem provides factory methods for different environments:

```swift
extension BLEActorSystem {
    /// Production: Real CoreBluetooth (requires TCC permissions, real hardware)
    public static func production() -> BLEActorSystem {
        let peripheral = CoreBluetoothPeripheralManager()
        let central = CoreBluetoothCentralManager()
        Task {
            await peripheral.initialize()  // TCC check occurs here
            await central.initialize()
        }
        return BLEActorSystem(
            peripheralManager: peripheral,
            centralManager: central
        )
    }

    /// Testing: Mock implementation (no TCC, no hardware required)
    public static func mock(
        peripheralConfig: MockPeripheralManager.Configuration = .init(),
        centralConfig: MockCentralManager.Configuration = .init()
    ) -> BLEActorSystem {
        return BLEActorSystem(
            peripheralManager: MockPeripheralManager(configuration: peripheralConfig),
            centralManager: MockCentralManager(configuration: centralConfig)
        )
    }

    /// Default shared instance uses production
    public static let shared: BLEActorSystem = .production()
}
```

### Test Organization

Tests are organized by hardware requirements and purpose:

```
Tests/BleuTests/
├── Unit/                          # Pure logic tests (no BLE)
│   ├── UnitTests.swift            # BLE Transport, UUID extensions
│   ├── RPCTests.swift             # RPC mechanism tests
│   ├── BleuV2SwiftTests.swift    # Core type tests
│   ├── EventBridgeTests.swift    # Event routing tests
│   └── TransportLayerTests.swift # Message transport tests
│
├── Integration/                   # Mock BLE integration tests
│   ├── MockActorSystemTests.swift # Mock manager tests
│   ├── FullWorkflowTests.swift    # Complete discovery-to-RPC workflows
│   └── ErrorHandlingTests.swift   # Error scenarios and edge cases
│
├── Hardware/                      # Real hardware tests (requires devices)
│   └── RealBLETests.swift         # Real BLE hardware validation
│
└── Mocks/                         # Test utilities and helpers
    ├── TestHelpers.swift          # Common test utilities
    └── MockActorExamples.swift    # Pre-built distributed actors for testing
```

### Writing Tests

#### Unit Tests (No BLE Dependency)

```swift
@Suite("Transport Layer")
struct TransportTests {
    @Test("Packet fragmentation")
    func testFragmentation() async {
        let transport = BLETransport.shared
        let data = Data(repeating: 0xFF, count: 1000)

        let packets = await transport.fragment(data)
        #expect(packets.count > 1)
    }
}
```

#### Integration Tests (Mock BLE)

```swift
import Testing
import Distributed
@testable import Bleu

@Suite("BLE System Integration")
struct MockBLESystemTests {
    @Test("Complete discovery to RPC flow")
    func testCompleteFlow() async throws {
        // Create separate mock systems for peripheral and central
        let peripheralSystem = BLEActorSystem.mock(
            peripheralConfig: TestHelpers.fastPeripheralConfig()
        )
        let centralSystem = BLEActorSystem.mock(
            centralConfig: TestHelpers.fastCentralConfig()
        )

        // Define test actor
        distributed actor TestSensor: PeripheralActor {
            typealias ActorSystem = BLEActorSystem

            distributed func getValue() async -> Int {
                return 42
            }
        }

        // Setup peripheral
        let sensor = TestSensor(actorSystem: peripheralSystem)
        try await peripheralSystem.startAdvertising(sensor)

        // Setup central to discover peripheral
        guard let mockCentral = await centralSystem.mockCentralManager() else {
            Issue.record("Expected mock central manager")
            return
        }

        // Register peripheral with mock central
        let serviceUUID = UUID.serviceUUID(for: TestSensor.self)
        let serviceMetadata = ServiceMapper.createServiceMetadata(from: TestSensor.self)

        let discovered = DiscoveredPeripheral(
            id: sensor.id,
            name: "TestSensor",
            rssi: -50,
            advertisementData: AdvertisementData(serviceUUIDs: [serviceUUID])
        )

        await mockCentral.registerPeripheral(discovered, services: [serviceMetadata])

        // Test discovery and RPC
        let sensors = try await centralSystem.discover(TestSensor.self, timeout: 1.0)
        #expect(sensors.count == 1)

        let value = try await sensors[0].getValue()
        #expect(value == 42)
    }
}
```

#### Hardware Tests (Real Devices)

```swift
@Suite("Real BLE Hardware Tests", .disabled("Requires real BLE hardware"))
struct RealBLETests {
    @Test("BLE Actor System Initialization")
    func testBLEActorSystemInit() async throws {
        // Uses production system - requires TCC permissions
        let actorSystem = BLEActorSystem.shared

        // Wait for system to be ready
        var isReady = false
        for _ in 0..<100 {
            isReady = await actorSystem.ready
            if isReady {
                break
            }
            try await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }

        #expect(isReady == true)
    }
}
```

**Important**: Hardware tests are disabled by default using `.disabled()` attribute. To run them:
1. Remove the `.disabled()` attribute from the suite
2. Ensure your app has proper `Info.plist` with Bluetooth permissions
3. Run tests on a device or Mac with Bluetooth hardware

### Test Utilities and Helpers

Bleu provides comprehensive test utilities in `Tests/BleuTests/Mocks/` to simplify test writing.

#### TestHelpers (Tests/BleuTests/Mocks/TestHelpers.swift)

Common utilities for test data generation and mock configuration:

```swift
// Generate test data
let randomData = TestHelpers.randomData(size: 100)
let deterministicData = TestHelpers.deterministicData(size: 100, pattern: 0xAB)

// Create service metadata
let simpleService = TestHelpers.createSimpleService()
let rpcService = TestHelpers.createRPCService()
let complexService = TestHelpers.createComplexService()

// Create advertisement data
let adData = TestHelpers.createAdvertisementData(
    name: "MyDevice",
    serviceUUIDs: [serviceUUID]
)

// Create discovered peripheral
let peripheral = TestHelpers.createDiscoveredPeripheral(
    id: UUID(),
    name: "TestDevice",
    rssi: -50,
    serviceUUIDs: [serviceUUID]
)

// Fast mock configurations (10ms delays for quick tests)
let system = BLEActorSystem.mock(
    peripheralConfig: TestHelpers.fastPeripheralConfig(),
    centralConfig: TestHelpers.fastCentralConfig()
)

// Failing mock configurations (for error testing)
let failingSystem = BLEActorSystem.mock(
    peripheralConfig: TestHelpers.failingPeripheralConfig(),
    centralConfig: TestHelpers.failingCentralConfig()
)
```

#### Mock Actor Examples (Tests/BleuTests/Mocks/MockActorExamples.swift)

Pre-built distributed actors for common testing scenarios:

```swift
// SimpleValueActor - Returns constant value
let actor = SimpleValueActor(actorSystem: system)
let value = try await actor.getValue() // Returns 42

// EchoActor - Echoes back messages
let echo = EchoActor(actorSystem: system)
let result = try await echo.echo("hello") // Returns "hello"

// SensorActor - Simulates sensor readings
let sensor = SensorActor(actorSystem: system)
let temp = try await sensor.readTemperature() // Returns 22.5
let humidity = try await sensor.readHumidity() // Returns 45.0

// CounterActor - Stateful counter
let counter = CounterActor(actorSystem: system)
let count1 = try await counter.increment() // Returns 1
let count2 = try await counter.increment() // Returns 2

// DeviceControlActor - Device control simulation
let device = DeviceControlActor(actorSystem: system)
try await device.turnOn()
try await device.setBrightness(75)
let status = try await device.getStatus()

// DataStorageActor - Key-value storage
let storage = DataStorageActor(actorSystem: system)
try await storage.store(key: "test", value: testData)
let retrieved = try await storage.retrieve(key: "test")

// ErrorThrowingActor - Error handling tests
let errorActor = ErrorThrowingActor(actorSystem: system)
try await errorActor.alwaysThrows() // Throws TestError
let result = try await errorActor.throwsIf(false) // Returns "Success"

// ComplexDataActor - Complex data structures
let dataActor = ComplexDataActor(actorSystem: system)
let complexData = try await dataActor.getComplexData()

// StreamingActor - Async stream patterns
let streamActor = StreamingActor(actorSystem: system)
let sequence = try await streamActor.getSequence(count: 10)
```

**Usage Pattern**:
1. Use `SimpleValueActor` or `EchoActor` for basic RPC tests
2. Use `SensorActor` or `CounterActor` for stateful behavior tests
3. Use `ErrorThrowingActor` for error propagation tests
4. Use `ComplexDataActor` for serialization tests

### Running Tests

```bash
# Run all tests (uses mocks, no TCC required)
swift test

# Run specific test suite
swift test --filter "Mock Actor System Tests"

# Run only unit tests (fastest)
swift test --filter Unit

# Run integration tests with mocks
swift test --filter Integration

# Run hardware tests (requires real devices + TCC permissions)
swift test --filter Hardware

# Verbose output
swift test --verbose

# Parallel execution
swift test --parallel
```

### Mock Configuration

Mocks support extensive configuration for testing various scenarios:

#### MockPeripheralManager.Configuration

```swift
var peripheralConfig = MockPeripheralManager.Configuration()
peripheralConfig.initialState = .poweredOn           // Initial Bluetooth state
peripheralConfig.advertisingDelay = 0.01             // Delay before advertising starts (seconds)
peripheralConfig.shouldFailAdvertising = false       // Simulate advertising failure
peripheralConfig.shouldFailServiceAdd = false        // Simulate service add failure
peripheralConfig.writeResponseDelay = 0.01           // Delay before write responses (seconds)

let system = BLEActorSystem.mock(peripheralConfig: peripheralConfig)
```

#### MockCentralManager.Configuration

```swift
var centralConfig = MockCentralManager.Configuration()
centralConfig.initialState = .poweredOn              // Initial Bluetooth state
centralConfig.scanDelay = 0.01                       // Delay between discoveries (seconds)
centralConfig.connectionDelay = 0.01                 // Delay before connection (seconds)
centralConfig.discoveryDelay = 0.01                  // Service/characteristic discovery delay (seconds)
centralConfig.shouldFailConnection = false           // Simulate connection failure
centralConfig.connectionTimeout = false              // Simulate connection timeout

let system = BLEActorSystem.mock(centralConfig: centralConfig)
```

#### Common Testing Scenarios

```swift
// Fast tests (10ms delays)
let fastSystem = BLEActorSystem.mock(
    peripheralConfig: TestHelpers.fastPeripheralConfig(),
    centralConfig: TestHelpers.fastCentralConfig()
)

// Test connection failures
var failConfig = TestHelpers.fastCentralConfig()
failConfig.shouldFailConnection = true
let failingSystem = BLEActorSystem.mock(centralConfig: failConfig)

// Test connection timeouts
var timeoutConfig = TestHelpers.fastCentralConfig()
timeoutConfig.connectionTimeout = true
let timeoutSystem = BLEActorSystem.mock(centralConfig: timeoutConfig)

// Test advertising failures
var adFailConfig = TestHelpers.fastPeripheralConfig()
adFailConfig.shouldFailAdvertising = true
let adFailSystem = BLEActorSystem.mock(peripheralConfig: adFailConfig)

// Test Bluetooth powered off
var offConfig = MockPeripheralManager.Configuration()
offConfig.initialState = .poweredOff
let offSystem = BLEActorSystem.mock(peripheralConfig: offConfig)
```

### Benefits

1. **No TCC Crashes**: Tests run without CoreBluetooth, avoiding privacy violations
2. **Fast Test Execution**: No hardware delays, no async BLE operations
3. **Deterministic Tests**: Mocks provide consistent, reproducible behavior
4. **CI/CD Friendly**: Tests run on any machine without BLE hardware
5. **Edge Case Testing**: Easily simulate connection failures, timeouts, etc.
6. **100% Backward Compatible**: Existing code continues to work unchanged

### Testing Best Practices

#### 1. Use Mock Systems for Most Tests

```swift
// ✅ Good - Fast, no TCC required
let system = BLEActorSystem.mock()

// ❌ Avoid in tests - Slow, requires TCC
let system = BLEActorSystem.shared
```

#### 2. Use Fast Configurations

```swift
// ✅ Good - Fast test execution
let system = BLEActorSystem.mock(
    peripheralConfig: TestHelpers.fastPeripheralConfig(),
    centralConfig: TestHelpers.fastCentralConfig()
)

// ❌ Slow - Default delays
let system = BLEActorSystem.mock()
```

#### 3. Test One Thing Per Test

```swift
// ✅ Good - Focused test
@Test("Counter increments correctly")
func testCounterIncrement() async throws {
    let counter = CounterActor(actorSystem: system)
    let count = try await counter.increment()
    #expect(count == 1)
}

// ❌ Bad - Tests multiple things
@Test("Counter works")
func testCounter() async throws {
    // Tests increment, decrement, reset, add...
}
```

#### 4. Use Descriptive Test Names

```swift
// ✅ Good
@Test("Connection fails when peripheral not found")

// ❌ Bad
@Test("Test 1")
```

#### 5. Test Error Cases

```swift
@Test("Handles connection failure gracefully")
func testConnectionFailure() async throws {
    var config = TestHelpers.fastCentralConfig()
    config.shouldFailConnection = true

    let system = BLEActorSystem.mock(centralConfig: config)

    do {
        try await system.connect(to: UUID(), as: SensorActor.self)
        Issue.record("Expected connection to fail")
    } catch {
        // Success - error was thrown
    }
}
```

#### 6. Use Guard Statements for Optional Unwrapping

```swift
// ✅ Good - Clear error message
guard let mockCentral = await system.mockCentralManager() else {
    Issue.record("Expected mock central manager")
    return
}

// ❌ Bad - Force unwrap
let mockCentral = await system.mockCentralManager()!
```

#### 7. Separate Peripheral and Central Systems in Integration Tests

```swift
// ✅ Good - Separate systems for clarity
let peripheralSystem = BLEActorSystem.mock()
let centralSystem = BLEActorSystem.mock()

// Create actor on peripheral system
let sensor = SensorActor(actorSystem: peripheralSystem)

// Discover from central system
let sensors = try await centralSystem.discover(SensorActor.self)
```

### Implementation Status

- **Phase 1**: Protocol definitions - ✅ **Completed**
- **Phase 2**: Mock implementations - ✅ **Completed**
- **Phase 3**: BLEActorSystem refactoring - ✅ **Completed**
- **Phase 4**: Test migration - ✅ **Completed**
- **Phase 5**: Documentation polish - 🔄 **In Progress**

**Test Status**: 46 tests total, 39 passing (84.8%), 7 with initialization timing issues (non-blocking)

For detailed implementation design and architecture, see [Protocol-Oriented Testing Architecture](../design/PROTOCOL_ORIENTED_TESTING_ARCHITECTURE.md).

For comprehensive testing guide including troubleshooting, see [Testing Guide](../guides/TESTING.md).

## Package Structure

The repository contains two Swift packages:

### Main Package (Package.swift)
- **Bleu** library target (Sources/Bleu/)
- **BleuDemo** executable target (Sources/BleuDemo/)
- **BleuTests** test target (Tests/BleuTests/)

### Examples Package (Examples/Package.swift)
- **SensorServer** executable - Peripheral example
- **SensorClient** executable - Central example
- **BleuExampleApp** executable - Full SwiftUI app
- **BleuCommon** target - Shared actor definitions

## Reference Documentation

- **SPECIFICATION.md** - Complete protocol specification, API reference, UUID generation algorithm
- **API_REFERENCE.md** - Detailed API documentation for all public interfaces
- **MIGRATION.md** - Migration guide from Bleu v1 to v2
- **AGENTS.md** - Repository coding conventions and development guidelines
- **README.md** - Quick start guide and overview

## Current Status

### Phase 1: Foundation (In Progress)
- [ ] Fix existing compilation errors
- [ ] Remove NSLock usage
- [ ] Implement LocalPeripheralActor
- [ ] Implement LocalCentralActor

### Phase 2: Core Features
- [ ] ServiceMapper implementation
- [ ] MethodRegistry implementation
- [ ] BLEActorSystem completion
- [ ] Basic transport layer

### Phase 3: Advanced Features
- [ ] Automatic reconnection
- [ ] Data compression
- [ ] Encryption
- [ ] Flow control

## Common Issues & Solutions

### Distributed Actor Compilation Errors
**Cause**: CoreBluetooth delegates calling distributed actor methods directly
**Fix**: All delegate callbacks must go through LocalActors → EventBridge → Distributed Actors
**Pattern**: `CBDelegate` → `DelegateProxy` → `AsyncChannel` → `LocalActor` → `EventBridge` → `DistributedActor`

### NSLock or @unchecked Sendable Issues
**Cause**: Legacy synchronization code or improper Sendable conformance
**Fix**: Use actor isolation exclusively - wrap state in actors, never use locks
**Example**: Replace `NSLock` with `actor` boundaries, use `ProxyManager` pattern

### Method Not Found / RPC Errors
**Cause**: Method not marked as `distributed`
**Fix**: Add `distributed` keyword to all methods that need remote invocation
**Note**: Only `distributed func` methods are mapped to BLE characteristics

### Connection State Synchronization
**Cause**: Attempting to track connection state with mutable shared variables
**Fix**: Use actor-isolated state (e.g., `ProxyManager` actor in `BLEActorSystem`)
**Anti-pattern**: Avoid shared dictionaries protected by locks

## Coding Conventions

### Swift Style
- Follow Swift API Design Guidelines
- Use 4-space indentation (not tabs)
- Group imports: Foundation → Apple frameworks → project modules
- Types: `PascalCase`, methods/variables: `camelCase`
- Async distributed APIs should read like verbs: `startAdvertising()`, `discover()`

### Testing Requirements
- All tests use Swift `Testing` module (not XCTest)
- Use `@Suite` containers aligned with namespaces
- Expressive test names: `@Test("Characteristic permissions")`
- New functionality requires both unit tests and integration tests
- BLE handshake/serialization changes require Examples/ scenario validation
- Run `swift test` before every commit

### Commit Guidelines
- Use imperative mood for commit subjects (~72 chars max)
- Scoped prefixes: `feat:`, `fix:`, `docs:`, `refactor:`
- PRs should describe behavior change, validation steps, and reference specs
- Include logs/screenshots when peripheral behavior changes

## Best Practices

### Development
1. **Keep distributed methods simple** - Complex logic should be local, RPC should be lightweight
2. **Use AsyncStream for notifications** - Built-in support for BLE notify/indicate characteristics
3. **Let the system handle connections** - Don't manage CBPeripheral/CBCentral directly
4. **Trust automatic reconnection** - System handles transient disconnections with exponential backoff
5. **Test on real devices** - Simulator has significant BLE limitations

### Architecture
6. **Respect actor boundaries** - Never bypass actors with locks or shared mutable state
7. **Use message passing** - LocalActors ↔ DistributedActors communicate via AsyncChannel
8. **Immutable UUIDs** - Peripheral identity is permanent, never reassign actor UUIDs
9. **Deterministic service mapping** - Service/Characteristic UUIDs generated from type information

## Debugging

```swift
// Enable verbose logging
BLEActorSystem.loggingLevel = .verbose

// Monitor connection state
system.onConnectionStateChange = { peripheral, state in
    print("State: \(state)")
}

// Track discovery
system.onPeripheralDiscovered = { peripheral in
    print("Found: \(peripheral)")
}
```

## Example Applications

### Examples/BasicUsage/
- Simple temperature sensor
- LED controller
- Data logger

### Examples/SwiftUIApp/
- Full SwiftUI integration
- Real-time charts
- Device management UI

### Examples/Common/
- Shared actor definitions
- Reusable UI components

## Future Roadmap

- **v2.1**: Mesh networking support
- **v2.2**: Multi-peripheral connections
- **v2.3**: Background mode optimization
- **v2.4**: Linux support via BlueZ
- **v3.0**: Cross-transport support (WiFi, NFC)