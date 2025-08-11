# Bleu 2.0 Specification

## Overview

Bleu 2.0 is a Swift framework that leverages Distributed Actors to provide transparent, type-safe Bluetooth Low Energy communication. It completely abstracts CoreBluetooth complexity, allowing developers to write BLE applications as simple distributed function calls.

## Core Concepts

### 1. Peripheral as Distributed Actor

In Bleu 2.0, BLE Peripherals are represented as Distributed Actors:

- **PeripheralActor**: Base type for all BLE peripherals
- **Actor ID = Peripheral UUID**: Each peripheral is uniquely identified by its UUID
- **Transparent RPC**: Method calls on peripheral actors are automatically translated to BLE operations

### 2. UUID-based Communication

All communication is based on peripheral UUIDs:

- **Persistent Identity**: Peripheral UUIDs remain constant across connections
- **Direct Connection**: Connect to known peripherals without scanning
- **Efficient Discovery**: Skip scanning for previously connected devices

### 3. Automatic Service Mapping

Distributed actor methods are automatically mapped to BLE services:

- **Service UUID**: Generated deterministically from actor type
- **Characteristic UUID**: Generated from method signature
- **No Manual Configuration**: All UUIDs are managed by the framework

## Architecture

### Layer Structure

```
┌──────────────────────────────────────────┐
│          Application Layer               │
│   distributed actor MyPeripheralActor    │  ← User code
└────────────────▲─────────────────────────┘
                 │
┌────────────────┴─────────────────────────┐
│         BLEActorSystem                   │  ← Distributed Actor System
├──────────────────────────────────────────┤
│         ServiceMapper                    │  ← Automatic mapping
├──────────────────────────────────────────┤
│         BLETransport                     │  ← Reliable transport
├──────────────────────────────────────────┤
│    LocalPeripheralActor/LocalCentralActor│  ← CoreBluetooth wrapper
└──────────────────────────────────────────┘
```

### Component Responsibilities

#### BLEActorSystem
- Implements `DistributedActorSystem` protocol
- Manages actor lifecycle
- Handles remote method invocation
- Maintains actor registry keyed by UUID

#### LocalPeripheralActor / LocalCentralActor
- Wraps CoreBluetooth functionality
- Handles delegate callbacks
- Manages BLE state
- Communicates via AsyncChannel

#### ServiceMapper
- Generates service/characteristic UUIDs from type information
- Creates BLE service metadata
- Maps distributed methods to characteristics
- Handles method signature extraction

#### BLETransport
- Manages data fragmentation/reassembly
- Provides reliability guarantees
- Handles flow control
- Supports compression

## API Reference

### PeripheralActor Protocol

```swift
public protocol PeripheralActor: DistributedActor 
    where ActorSystem == BLEActorSystem {
    nonisolated var id: UUID { get }
}
```

All peripheral implementations must conform to this protocol.

### BLEActorSystem

#### Peripheral Mode Operations

```swift
// Start advertising a peripheral
func startAdvertising<T: PeripheralActor>(_ peripheral: T) async throws

// Stop advertising
func stopAdvertising() async throws

// Update advertisement data
func updateAdvertisement(_ data: AdvertisementData) async throws
```

#### Central Mode Operations

```swift
// Discover peripherals of a specific type
func discover<T: PeripheralActor>(_ type: T.Type, timeout: TimeInterval = 10) async throws -> [T]

// Connect to a known peripheral by UUID
func connect<T: PeripheralActor>(to peripheralID: UUID, as type: T.Type) async throws -> T

// Connect to multiple peripherals
func connectMultiple<T: PeripheralActor>(to peripheralIDs: [UUID], as type: T.Type) async throws -> [T]

// Check connection status
func isConnected(_ peripheralID: UUID) async -> Bool

// Disconnect from a peripheral
func disconnect(from peripheralID: UUID) async throws
```

### Defining a Peripheral

```swift
distributed actor TemperatureSensorActor: PeripheralActor {
    typealias ActorSystem = BLEActorSystem
    
    // Distributed methods become BLE characteristics
    distributed func readTemperature() async throws -> Double
    distributed func calibrate(offset: Double) async throws
    distributed func subscribeToUpdates() async throws -> AsyncStream<Double>
}
```

### Using a Peripheral

```swift
// Discover peripherals
let sensors = try await system.discover(TemperatureSensorActor.self)

// Use the first sensor
if let sensor = sensors.first {
    // Read temperature (triggers BLE read)
    let temp = try await sensor.readTemperature()
    
    // Subscribe to updates (uses BLE notifications)
    for await update in try await sensor.subscribeToUpdates() {
        print("Temperature: \(update)")
    }
    
    // Save UUID for later
    UserDefaults.standard.set(sensor.id.uuidString, forKey: "sensorID")
}

// Later: reconnect using saved UUID
if let uuidString = UserDefaults.standard.string(forKey: "sensorID"),
   let uuid = UUID(uuidString: uuidString) {
    let sensor = try await system.connect(to: uuid, as: TemperatureSensorActor.self)
    // Ready to use immediately
}
```

## Connection Management

### Connection Flow

1. **Peripheral Setup**
   - Extract distributed methods from actor type
   - Generate service/characteristic UUIDs
   - Create CBMutableService
   - Start advertising

2. **Central Discovery**
   - Calculate expected service UUID
   - Scan for matching peripherals
   - Create peripheral actor instances

3. **Lazy Connection**
   - Connection established on first method call
   - Automatic reconnection on failure
   - Connection pooling for efficiency

### Connection States

```swift
enum ConnectionState {
    case disconnected
    case connecting
    case connected
    case disconnecting
}
```

### Automatic Reconnection

The framework automatically handles reconnection with exponential backoff:

- Initial retry delay: 1 second
- Maximum retry delay: 30 seconds
- Maximum retries: 5

## Data Types

### Supported Parameter Types

All parameters and return types must conform to `Codable`:

- Basic types: `Int`, `Double`, `String`, `Bool`, `Data`
- Collections: `Array`, `Dictionary`, `Set`
- Custom types: Any `Codable` struct/enum
- Async types: `AsyncStream`, `AsyncThrowingStream`

### Method Patterns

```swift
// Simple read
distributed func getValue() async throws -> Int

// Write with parameter
distributed func setValue(_ value: Int) async throws

// Write without response
distributed func notify(_ message: String) async

// Streaming updates
distributed func subscribe() async throws -> AsyncStream<Event>
```

## Error Handling

### BleuError

```swift
public enum BleuError: Error {
    case bluetoothUnavailable
    case bluetoothUnauthorized
    case peripheralNotFound(UUID)
    case serviceNotFound(UUID)
    case characteristicNotFound(UUID)
    case connectionTimeout
    case connectionFailed(Error)
    case incompatibleVersion(detected: Int, required: Int)
    case invalidData
    case quotaExceeded
}
```

### Error Recovery

The framework automatically recovers from transient errors:

- Connection loss → Automatic reconnection
- Bluetooth off → Wait and retry
- Peripheral out of range → Periodic scanning

## Performance Characteristics

### Connection Timing

- Discovery: 1-3 seconds typical
- Connection: 0.5-2 seconds typical
- Service discovery: 0.2-1 second typical
- First RPC call: 0.1-0.5 seconds typical

### Data Limits

- Maximum packet size: Negotiated MTU (typically 185-512 bytes)
- Automatic fragmentation for larger data
- Compression for data > 1KB

### Concurrency

- Multiple simultaneous peripheral connections supported
- Parallel RPC calls to different peripherals
- Serial RPC calls to same peripheral (preserves ordering)

## Platform Requirements

- **iOS**: 18.0+
- **macOS**: 15.0+
- **watchOS**: 11.0+
- **tvOS**: 18.0+
- **Swift**: 6.1+
- **Xcode**: 16.0+

## Security Considerations

### Pairing and Bonding

- Automatic pairing when required by characteristic
- Bonding information persisted by system
- Support for encrypted characteristics

### Data Protection

- Optional AES-GCM encryption for sensitive data
- Per-session keys
- Forward secrecy support

## Migration from v1

### Key Differences

| v1 | v2 |
|---|---|
| Beacon/Radar | PeripheralActor/CentralCoordinator |
| Communicable protocol | Distributed Actor |
| Manual UUID management | Automatic UUID generation |
| Callback-based | async/await |
| Manual connection | Automatic connection |

### Migration Steps

1. Replace `Beacon` with `PeripheralActor` subclass
2. Replace `Radar` with `BLEActorSystem.discover()`
3. Convert callbacks to async methods
4. Remove manual UUID management
5. Remove connection state management

## Best Practices

### 1. Peripheral Design

- Keep distributed methods focused and simple
- Use AsyncStream for continuous updates
- Implement proper error handling
- Document expected latencies

### 2. Central Design

- Save peripheral UUIDs for quick reconnection
- Handle discovery timeouts gracefully
- Implement retry logic for critical operations
- Monitor connection state changes

### 3. Performance

- Minimize data transfer size
- Use notifications instead of polling
- Batch operations when possible
- Implement caching where appropriate

### 4. Testing

- Test with real devices (simulator limitations)
- Test connection/disconnection scenarios
- Verify behavior with Bluetooth off
- Test with multiple simultaneous connections

## Limitations

### Framework Limitations

- Maximum 7 simultaneous connections (iOS limitation)
- Background mode requires specific capabilities
- Advertising limited in background
- Some operations require user interaction

### CoreBluetooth Limitations

- No direct peripheral-to-peripheral communication
- Limited advertisement data (31 bytes)
- Cannot scan for all peripherals in background
- MTU negotiation not directly controllable

## Future Enhancements (Post v2.0)

- Mesh networking support
- Enhanced background capabilities
- Cross-transport support (WiFi Direct, NFC)
- Linux support via BlueZ
- Windows support via WinRT

## Appendix

### UUID Generation Algorithm

Service UUIDs are generated using:
```
UUID5(namespace: BLEU_NAMESPACE, name: "\(ActorType).BLEService")
```

Characteristic UUIDs are generated using:
```
UUID5(namespace: ServiceUUID, name: "\(ActorType).\(methodName)")
```

### MTU Negotiation

The framework automatically negotiates the maximum MTU:
- iOS/macOS: Up to 512 bytes
- watchOS: Up to 185 bytes
- tvOS: Up to 512 bytes

### Background Modes

Required background modes in Info.plist:
```xml
<key>UIBackgroundModes</key>
<array>
    <string>bluetooth-central</string>
    <string>bluetooth-peripheral</string>
</array>
```