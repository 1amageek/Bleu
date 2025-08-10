# Bleu v2 🔵

**Enterprise-Grade Bluetooth Low Energy Framework for Swift**

[![Swift 6.1](https://img.shields.io/badge/Swift-6.1-orange.svg)](https://swift.org)
[![Platforms](https://img.shields.io/badge/Platforms-iOS%2018%2B%20|%20macOS%2015%2B%20|%20watchOS%2011%2B%20|%20tvOS%2018%2B-brightgreen.svg)](https://developer.apple.com/swift/)
[![Swift Package Manager](https://img.shields.io/badge/SPM-Compatible-brightgreen.svg)](https://swift.org/package-manager/)
[![License](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Tests](https://img.shields.io/badge/Tests-Passing-green.svg)](#testing)

Bleu v2 is a complete rewrite of the Bluetooth Low Energy framework, designed from the ground up with **Distributed Actors** and **Swift Concurrency**. It provides a modern, type-safe, performant, and enterprise-ready solution for BLE development.

## ✨ Key Features

### 🎭 **Distributed Actor Architecture**
- Type-safe remote procedure calls over BLE
- Transparent communication between devices
- Swift 6.1 concurrency and actor isolation

### 🔒 **Enterprise Security**
- Built-in AES-GCM encryption
- Device authentication and trust management
- Certificate validation and PKI support
- Security configurations per environment

### 🚀 **High Performance**
- Adaptive data compression (LZ4, LZFSE, LZMA)
- Smart buffer pool management
- Flow control with backpressure handling
- Connection quality monitoring

### 🔄 **Automatic Recovery**
- Intelligent reconnection policies
- Connection state management
- Error recovery with suggested actions
- Quality-based adaptive throttling

### 📊 **Comprehensive Monitoring**
- Structured logging with multiple destinations
- Real-time performance metrics
- Connection quality tracking
- Memory and resource monitoring

### ⚙️ **Production Ready**
- Environment-specific configurations
- Feature flag management
- Hot configuration reloading
- Resource cleanup and management

## 🚀 Quick Start

### Installation

Add Bleu to your project using Swift Package Manager:

```swift
dependencies: [
    .package(url: "https://github.com/1amageek/Bleu.git", from: "2.0.0")
]
```

### Basic Usage

#### Create a BLE Server

```swift
import Bleu

// Create a server that responds to device info requests
let server = try await BleuServer(
    serviceUUID: UUID(uuidString: "12345678-1234-5678-9ABC-123456789ABC")!,
    characteristicUUIDs: [UUID(uuidString: "87654321-4321-8765-CBA9-987654321CBA")!],
    localName: "My BLE Device"
)

// Handle incoming requests with type safety
await server.handleRequests(ofType: GetDeviceInfoRequest.self) { request in
    return GetDeviceInfoRequest.Response(
        deviceName: "Bleu Device",
        firmwareVersion: "2.0.0", 
        batteryLevel: 85
    )
}
```

#### Create a BLE Client

```swift
import Bleu

// Create a client to discover and connect to devices
let client = try await BleuClient(
    serviceUUIDs: [UUID(uuidString: "12345678-1234-5678-9ABC-123456789ABC")!]
)

// Discover nearby devices
let devices = try await client.discover(timeout: 10.0)

// Connect to the first discovered device
if let device = devices.first {
    let peripheral = try await client.connect(to: device)
    
    // Send a type-safe request
    let request = GetDeviceInfoRequest()
    let response = try await client.sendRequest(request, to: device.identifier)
    
    print("Device: \(response.deviceName), Battery: \(response.batteryLevel)%")
}
```

## 🎯 Advanced Features

### Type-Safe Remote Procedure Calls

Define your communication protocols with full type safety:

```swift
struct GetDeviceInfoRequest: RemoteProcedure {
    let serviceUUID = UUID(uuidString: "12345678-1234-5678-9ABC-123456789ABC")!
    let characteristicUUID = UUID(uuidString: "87654321-4321-8765-CBA9-987654321CBA")!
    
    struct Response: Sendable, Codable {
        let deviceName: String
        let firmwareVersion: String
        let batteryLevel: Int
    }
}
```

### Real-time Data Streaming

Subscribe to continuous data streams with AsyncSequence:

```swift
// Subscribe to temperature sensor data
let temperatureStream = try await client.subscribe(
    to: SensorDataNotification.self,
    from: deviceId,
    characteristicUUID: sensorCharacteristicUUID
)

for await sensorData in temperatureStream {
    print("Temperature: \(sensorData.temperature)°C")
    print("Humidity: \(sensorData.humidity)%")
}
```

### Distributed Actor Communication

Interact with BLE devices as if they were local actors:

```swift
// Get a distributed actor reference to a remote BLE device
let peripheral: PeripheralActor = try await centralActor.connect(to: deviceId)

// Call distributed methods directly
try await peripheral.startAdvertising()
try await peripheral.sendNotification(characteristicUUID: uuid, data: data)
```

### Bluetooth State Monitoring

Monitor Bluetooth state changes reactively:

```swift
let stateStream = Bleu.monitorBluetoothState()

for await state in stateStream {
    switch state {
    case .poweredOn:
        print("Bluetooth ready!")
    case .poweredOff:
        print("Bluetooth disabled")
    default:
        print("Bluetooth state: \(state)")
    }
}
```

## 📱 SwiftUI Integration

Bleu provides reactive SwiftUI integration:

```swift
import SwiftUI
import Bleu

struct ContentView: View {
    @StateObject private var bluetoothManager = BluetoothManager()
    
    var body: some View {
        VStack {
            if bluetoothManager.isAvailable {
                Text("✓ Bluetooth Ready")
                    .foregroundColor(.green)
            } else {
                Text("⚠️ Bluetooth Unavailable")
                    .foregroundColor(.red)
            }
        }
    }
}

@MainActor
class BluetoothManager: ObservableObject {
    @Published var isAvailable = false
    
    init() {
        Task {
            let stateStream = Bleu.monitorBluetoothState()
            for await state in stateStream {
                self.isAvailable = state == .poweredOn
            }
        }
    }
}
```

## 🧪 Testing

Bleu includes a comprehensive mock system for testing:

```swift
import Testing
@testable import Bleu

@Test("Mock BLE communication")
func testMockCommunication() async throws {
    let mockSystem = MockBLEActorSystem()
    
    // Setup mock response
    let expectedResponse = GetDeviceInfoRequest.Response(
        deviceName: "Mock Device",
        firmwareVersion: "1.0.0",
        batteryLevel: 75
    )
    
    try mockSystem.setMockResponse(
        expectedResponse,
        for: "getDeviceInfo",
        characteristicUUID: characteristicUUID
    )
    
    // Test the interaction
    let actualResponse = try await mockPeripheral.simulateRequest(
        GetDeviceInfoRequest.Response.self,
        method: "getDeviceInfo",
        characteristicUUID: characteristicUUID
    )
    
    #expect(actualResponse.deviceName == expectedResponse.deviceName)
}
```

## 📋 Requirements

- **iOS 18.0+**
- **macOS 15.0+** 
- **watchOS 11.0+**
- **tvOS 18.0+**
- **Swift 6.1+**
- **Xcode 16.0+**

## 🗺️ Architecture

Bleu is built around several key architectural concepts:

### Distributed Actor System
- **BLEActorSystem**: Manages distributed actor communication over BLE
- **BluetoothActor**: Global actor managing Bluetooth state and coordination
- **PeripheralActor**: Distributed actor representing BLE servers
- **CentralActor**: Distributed actor representing BLE clients

### Type-Safe Communication
- **RemoteProcedure**: Protocol for defining type-safe RPC calls
- **Sendable Types**: All data types conform to Sendable for actor isolation
- **Codable Integration**: Automatic serialization/deserialization

### Modern Concurrency
- Full async/await support throughout the API
- AsyncSequence for streaming data
- Actor isolation for thread safety
- Swift 6 concurrency features

## 🚀 Migration from v1

Bleu v2 is a complete rewrite with breaking changes. See the [Migration Guide](MIGRATION.md) for detailed migration instructions.

Key changes:
- Modern Swift Concurrency (async/await) replaces callbacks
- Distributed Actors replace Server/Client classes
- Type-safe RemoteProcedure replaces Communicable protocol
- Minimum deployment targets updated to latest OS versions

## 📖 Examples

Check out the comprehensive SwiftUI example app in the `Examples/` directory that demonstrates:
- BLE Server implementation
- BLE Client with device discovery
- Real-time sensor data streaming
- Remote actor communication patterns

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## 📄 License

Bleu is available under the MIT license. See the LICENSE file for more info.

---

**Bleu v2** - Modern Bluetooth Low Energy for Swift 6.1+