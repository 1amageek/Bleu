# Bleu 2 Examples

Sample code demonstrating how to use Bleu 2 framework with Swift Distributed Actors.

## 📁 Directory Structure

### BasicUsage/ - Basic Usage Examples
Minimal code examples to understand Bleu's core functionality using Distributed Actors.

- **SensorServer.swift** - Minimal BLE peripheral implementation using PeripheralActor
- **SensorClient.swift** - Minimal BLE central implementation for discovering and connecting to peripherals

### SwiftUIApp/ - SwiftUI Sample Application
Practical SwiftUI application implementation examples.

- **BleuExampleApp.swift** - Application entry point
- **ServerExample.swift** - Peripheral (server) functionality with UI
- **ClientExample.swift** - Central (client) functionality with UI
- **BluetoothState.swift** - Bluetooth state management
- **SharedViews.swift** - Reusable UI components

### Common/ - Shared Definitions
Common type definitions used across all examples.

- **PeripheralActors.swift** - Distributed actor definitions for BLE peripherals
- **SensorPeripheral.swift** - Sensor-specific peripheral actor implementations

## 🚀 Running Examples

### Navigate to Examples Directory

```bash
cd Examples
```

### Run Basic Usage Examples

```bash
# Start the sensor server (peripheral)
swift run SensorServer

# In another terminal, start the sensor client (central)
swift run SensorClient
```

### Run SwiftUI App

```bash
# Open in Xcode
open Package.swift

# Select BleuExampleApp target and run
# Or use command line:
swift run BleuExampleApp
```

## 📖 Learning Path

1. **BasicUsage/SensorServer.swift** and **SensorClient.swift** - Understand basic peripheral-central communication
2. **Common/PeripheralActors.swift** - Learn how to define distributed actors for BLE
3. **SwiftUIApp/** - See practical application implementation with reactive UI
4. **Common/** definitions - Reference for implementing your own peripheral actors

## 💡 Key Concepts

### Distributed Actor Pattern

```swift
// Define a peripheral as a distributed actor
distributed actor TemperatureSensor: PeripheralActor {
    typealias ActorSystem = BLEActorSystem

    distributed func readTemperature() async throws -> Double {
        return 25.5
    }
}
```

### Type-Safe Communication

```swift
// Peripheral side - advertise the actor
let system = BLEActorSystem.shared
let sensor = TemperatureSensor(actorSystem: system)
try await system.startAdvertising(sensor)

// Central side - discover and call methods
let sensors = try await system.discover(TemperatureSensor.self)
let temperature = try await sensors[0].readTemperature()
```

### Async/Await Integration

```swift
// All BLE operations use modern async/await
let devices = try await system.discover(TemperatureSensor.self, timeout: 10.0)
let value = try await devices[0].readTemperature()
```

### SwiftUI Integration

```swift
// Observable state for reactive UI updates
@Published var isAdvertising = false
@Published var discoveredDevices: [PeripheralActor] = []
```

## 📚 Documentation

For more detailed information, see:
- [Main README](../README.md) - Project overview and quick start
- [Specification](../docs/SPECIFICATION.md) - Complete framework specification
- [Repository Guidelines](../docs/internal/REPOSITORY_GUIDELINES.md) - Development workflow

## 🎯 Example Features

### BasicUsage
- ✅ Minimal server/client implementation
- ✅ Distributed actor pattern demonstration
- ✅ Automatic service discovery
- ✅ Type-safe remote method invocation

### SwiftUIApp
- ✅ Full SwiftUI integration
- ✅ Peripheral and Central modes in one app
- ✅ Real-time device discovery
- ✅ Connection state management
- ✅ Reactive UI updates with @Published

## ⚙️ Requirements

- iOS 18.0+ / macOS 15.0+ / watchOS 11.0+ / tvOS 18.0+
- Swift 6.1+
- Xcode 16.0+

## 🧪 Testing

Examples can be tested on:
- Real iOS/macOS devices (recommended for full BLE functionality)
- iOS Simulator (limited BLE support)
- macOS (full CoreBluetooth support)

---

*These examples demonstrate Bleu 2's Distributed Actor architecture for transparent, type-safe BLE communication.*
