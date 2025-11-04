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