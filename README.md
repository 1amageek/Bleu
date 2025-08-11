<div align="center">
  <img src="Bleu.png" alt="Bleu Logo" width="600">
  
  # Bleu 2
  
  **Modern Bluetooth Low Energy Framework with Swift Distributed Actors**
  
  [![Swift 6.0](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)
  [![Platforms](https://img.shields.io/badge/Platforms-iOS%2015%2B%20|%20macOS%2012%2B%20|%20watchOS%208%2B%20|%20tvOS%2015%2B-brightgreen.svg)](https://developer.apple.com/swift/)
  [![Swift Package Manager](https://img.shields.io/badge/SPM-Compatible-brightgreen.svg)](https://swift.org/package-manager/)
  [![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
</div>

---

## Overview

Bleu 2 is a revolutionary Bluetooth Low Energy framework that leverages **Swift's Distributed Actor System** to create seamless, type-safe communication between BLE devices. It transforms complex BLE operations into simple, intuitive actor method calls.

## ✨ Key Features

### 🎭 **Distributed Actor Architecture**
- Transparent RPC over BLE using Swift's native distributed actors
- Type-safe remote method invocation
- Automatic serialization and error handling
- Actor isolation for thread safety

### 🚀 **High Performance**
- Binary packet fragmentation with 24-byte headers
- Efficient data transport with checksums
- Adaptive MTU negotiation
- Automatic packet reassembly

### 📱 **Modern Swift Integration**
- Full async/await support
- AsyncStream for real-time data
- Swift 6 concurrency features
- Sendable protocol compliance

### 🔧 **Developer Friendly**
- Simple, intuitive API
- Comprehensive logging system
- Automatic resource management
- Clean error handling

## 🚀 Quick Start

### Installation

Add Bleu to your project using Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://github.com/1amageek/Bleu.git", from: "2.0.0")
]
```

### Basic Usage

#### Define Your Distributed Actor

```swift
import Bleu
import Distributed

// Define a distributed actor that runs on a BLE peripheral
distributed actor TemperatureSensor: PeripheralActor {
    typealias ActorSystem = BLEActorSystem
    
    distributed func getTemperature() async throws -> Double {
        // Read from actual sensor hardware
        return 25.5
    }
    
    distributed func setUpdateInterval(_ seconds: Int) async throws {
        // Configure sensor update rate
    }
}
```

#### Peripheral Side

```swift
// Create and advertise the sensor
let actorSystem = BLEActorSystem.shared
let sensor = TemperatureSensor(actorSystem: actorSystem)

// Start advertising the sensor service
try await actorSystem.startAdvertising(sensor)
```

#### Central Side

```swift
// Discover and connect to sensors
let actorSystem = BLEActorSystem.shared
let sensors = try await actorSystem.discover(TemperatureSensor.self, timeout: 10.0)

if let remoteSensor = sensors.first {
    // Call methods on the remote sensor as if it were local!
    let temperature = try await remoteSensor.getTemperature()
    print("Current temperature: \(temperature)°C")
    
    // Configure the remote sensor
    try await remoteSensor.setUpdateInterval(5)
}
```

## 🎯 Advanced Features

### Custom Service Metadata

```swift
distributed actor SmartLight: PeripheralActor {
    typealias ActorSystem = BLEActorSystem
    
    // Custom service configuration
    static var serviceMetadata: ServiceMetadata {
        ServiceMetadata(
            uuid: UUID(uuidString: "12345678-1234-5678-9ABC-123456789ABC")!,
            characteristics: [
                CharacteristicMetadata(
                    uuid: UUID(uuidString: "87654321-4321-8765-CBA9-987654321CBA")!,
                    properties: [.read, .write, .notify],
                    permissions: [.readable, .writeable]
                )
            ]
        )
    }
    
    distributed func setBrightness(_ level: Int) async throws {
        // Control light brightness
    }
    
    distributed func setColor(_ rgb: (r: Int, g: Int, b: Int)) async throws {
        // Set RGB color
    }
}
```

### Notifications and Subscriptions

```swift
distributed actor HeartRateMonitor: PeripheralActor {
    typealias ActorSystem = BLEActorSystem
    
    // Stream heart rate data
    distributed func streamHeartRate() -> AsyncStream<Int> {
        AsyncStream { continuation in
            // Setup sensor monitoring
            Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { _ in
                let heartRate = Int.random(in: 60...100)
                continuation.yield(heartRate)
            }
        }
    }
}

// Client side - subscribe to updates
let monitor = try await actorSystem.connect(to: deviceID, as: HeartRateMonitor.self)
for await heartRate in await monitor.streamHeartRate() {
    print("Heart rate: \(heartRate) BPM")
}
```

### Error Handling

```swift
do {
    let devices = try await actorSystem.discover(TemperatureSensor.self)
    // ... use devices
} catch BleuError.bluetoothPoweredOff {
    print("Please enable Bluetooth")
} catch BleuError.connectionTimeout {
    print("Connection timed out")
} catch {
    print("Unexpected error: \(error)")
}
```

## 📋 Architecture

### Core Components

- **`BLEActorSystem`**: The distributed actor system managing BLE communication
- **`PeripheralActor`**: Protocol for actors that can be advertised as BLE peripherals
- **`BLETransport`**: Handles packet fragmentation and reassembly
- **`EventBridge`**: Routes BLE events to distributed actors
- **`LocalPeripheralActor`/`LocalCentralActor`**: Core BLE operation management

### Communication Flow

```
┌─────────────┐                    ┌─────────────┐
│   Central   │                    │ Peripheral  │
└──────┬──────┘                    └──────┬──────┘
       │                                   │
       │  discover(TemperatureSensor)      │
       │────────────────────────────────>  │
       │                                   │
       │  <────────────────────────────    │
       │     [TemperatureSensor actors]    │
       │                                   │
       │  remoteSensor.getTemperature()    │
       │────────────────────────────────>  │
       │                                   │
       │  <────────────────────────────    │
       │            25.5°C                 │
       └───────────────────────────────────┘
```

### Binary Packet Format

Bleu uses an efficient binary packet format for BLE communication:

```
┌──────────────┬─────────────┬──────────────┬──────────┐
│  UUID (16B)  │  Seq (2B)   │  Total (2B)  │ CRC (4B) │ Payload
└──────────────┴─────────────┴──────────────┴──────────┘
        24-byte header
```

## 🧪 Testing

```swift
import Testing
@testable import Bleu

@Test("Distributed actor communication")
func testActorCommunication() async throws {
    let actorSystem = BLEActorSystem.shared
    
    // Create a mock peripheral
    let mockSensor = MockTemperatureSensor(actorSystem: actorSystem)
    
    // Test remote method invocation
    let temperature = try await mockSensor.getTemperature()
    #expect(temperature > 0)
}
```

## 📱 Platform Requirements

- **iOS 15.0+** / **macOS 12.0+** / **watchOS 8.0+** / **tvOS 15.0+**
- **Swift 6.0+**
- **Xcode 15.0+**

## 🗺️ Roadmap

- [ ] Enhanced security with encryption
- [ ] Improved connection management
- [ ] Background mode support
- [ ] Performance optimizations
- [ ] Additional platform support

## 🤝 Contributing

We welcome contributions! Please see our [Contributing Guidelines](CONTRIBUTING.md) for details.

## 📄 License

Bleu is available under the MIT license. See the [LICENSE](LICENSE) file for more info.

## 🙏 Acknowledgments

Special thanks to the Swift community and all contributors who have helped shape Bleu 2.

---

<div align="center">
  Made with ❤️ by <a href="https://x.com/1amageek">@1amageek</a>
  
  [Documentation](https://github.com/1amageek/Bleu/wiki) • [Issues](https://github.com/1amageek/Bleu/issues) • [Discussions](https://github.com/1amageek/Bleu/discussions)
</div>