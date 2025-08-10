# Migration Guide: Bleu v1 to v2

This guide will help you migrate from Bleu v1 to the completely redesigned v2.

## Overview

Bleu v2 is a complete rewrite that introduces:
- Distributed Actor architecture
- Swift Concurrency (async/await)
- Enhanced security and performance
- Modern Swift 6.1 features
- Production-ready enterprise features

## Breaking Changes

### 1. Minimum Requirements

**v1:**
- iOS 11.0+, macOS 10.13+
- Swift 5.0+
- Callback-based APIs

**v2:**
- iOS 18.0+, macOS 15.0+, watchOS 11.0+, tvOS 18.0+
- Swift 6.1+
- Distributed Actors and async/await

### 2. Architecture Changes

#### v1 Server/Client Pattern
```swift
// v1 - Callback based
class MyBeacon: Beacon {
    override func setUp() {
        // Setup services and characteristics
    }
}

let beacon = MyBeacon()
beacon.delegate = self
beacon.resume()

// Delegate methods
func beacon(_ beacon: Beacon, didConnect central: CBCentral) {
    // Handle connection
}
```

#### v2 Distributed Actor Pattern
```swift
// v2 - Distributed Actors with async/await
let server = try await Bleu.server(
    serviceUUID: serviceUUID,
    characteristicUUIDs: [characteristicUUID],
    localName: "My Device"
)

await server.handleRequests(ofType: MyRequest.self) { request in
    return MyResponse(data: processRequest(request))
}
```

### 3. Communication Patterns

#### v1 Communicable Protocol
```swift
// v1 - Communicable protocol
struct GetDeviceInfo: Communicable {
    typealias Response = DeviceInfoResponse
    
    let data: Data?
    let method: RequestMethod = .read
    
    func response(data: Data?) -> DeviceInfoResponse? {
        // Parse response
    }
}
```

#### v2 RemoteProcedure Protocol
```swift
// v2 - Type-safe RemoteProcedure
struct GetDeviceInfoRequest: RemoteProcedure {
    let serviceUUID = UUID(uuidString: "...")!
    let characteristicUUID = UUID(uuidString: "...")!
    
    struct Response: Sendable, Codable {
        let deviceName: String
        let firmwareVersion: String
        let batteryLevel: Int
    }
}
```

## Step-by-Step Migration

### Step 1: Update Dependencies

**Package.swift:**
```swift
// Remove v1 dependency
// .package(url: "https://github.com/1amageek/Bleu.git", from: "1.0.0")

// Add v2 dependency
.package(url: "https://github.com/1amageek/Bleu.git", from: "2.0.0")
```

### Step 2: Update Minimum Deployment Targets

**Update your app's deployment targets:**
```swift
// iOS: 18.0+
// macOS: 15.0+
// watchOS: 11.0+
// tvOS: 18.0+
```

### Step 3: Migrate Server Implementation

#### v1 Server
```swift
class TemperatureSensor: Beacon {
    private let temperatureCharacteristic = BLECharacteristic(
        UUID(uuidString: "2A6E")!
    )
    
    override func setUp() {
        let service = BLEService(
            UUID(uuidString: "181A")!,
            characteristics: [temperatureCharacteristic]
        )
        addService(service)
    }
    
    override func beacon(_ beacon: Beacon, didReceiveRead request: Request) {
        // Handle read request
        let temperature = getCurrentTemperature()
        let data = Data(temperature.bytes)
        respond(to: request, with: data)
    }
}
```

#### v2 Server
```swift
// Define request/response types
struct GetTemperatureRequest: RemoteProcedure {
    let serviceUUID = UUID(uuidString: "181A")! // Environmental Sensing
    let characteristicUUID = UUID(uuidString: "2A6E")! // Temperature
    
    struct Response: Sendable, Codable {
        let temperature: Double
        let unit: String
        let timestamp: Date
    }
}

// Create and configure server
let server = try await Bleu.server(
    serviceUUID: UUID(uuidString: "181A")!,
    characteristicUUIDs: [UUID(uuidString: "2A6E")!],
    localName: "Temperature Sensor"
)

// Handle requests with type safety
await server.handleRequests(ofType: GetTemperatureRequest.self) { request in
    let temperature = getCurrentTemperature()
    return GetTemperatureRequest.Response(
        temperature: temperature,
        unit: "Celsius",
        timestamp: Date()
    )
}
```

### Step 4: Migrate Client Implementation

#### v1 Client
```swift
let radar = Radar()
radar.delegate = self

radar.resume { [weak self] in
    // Scan and connect logic
}

// Delegate methods
func radar(_ radar: Radar, didDiscover peripheral: CBPeripheral) {
    radar.connect(to: peripheral)
}

func radar(_ radar: Radar, didConnect peripheral: CBPeripheral) {
    let request = GetTemperatureRequest()
    radar.send(request, to: peripheral) { response in
        // Handle response
    }
}
```

#### v2 Client
```swift
// Create client
let client = try await Bleu.client(
    serviceUUIDs: [UUID(uuidString: "181A")!]
)

// Discover devices
let devices = try await client.discover(timeout: 10.0)

// Connect to device
guard let device = devices.first else { return }
let peripheral = try await client.connect(to: device)

// Send type-safe request
let request = GetTemperatureRequest()
let response = try await client.sendRequest(request, to: device.identifier)

print("Temperature: \(response.temperature)°C at \(response.timestamp)")
```

### Step 5: Migrate Data Streaming

#### v1 Streaming
```swift
// v1 - Callback based notifications
func radar(_ radar: Radar, didReceiveData data: Data, from peripheral: CBPeripheral) {
    // Process streaming data
    let sensorData = parseSensorData(data)
    updateUI(with: sensorData)
}
```

#### v2 Streaming
```swift
// v2 - AsyncStream for real-time data
struct SensorDataNotification: Sendable, Codable {
    let temperature: Double
    let humidity: Double
    let timestamp: Date
}

// Subscribe to sensor data stream
let dataStream = try await client.subscribe(
    to: SensorDataNotification.self,
    from: device.identifier,
    characteristicUUID: sensorCharacteristicUUID
)

// Process stream data
for await sensorData in dataStream {
    await updateUI(with: sensorData)
}
```

### Step 6: Update Error Handling

#### v1 Error Handling
```swift
// v1 - Delegate-based error handling
func radar(_ radar: Radar, didFailToConnect peripheral: CBPeripheral, error: Error?) {
    // Handle connection failure
}
```

#### v2 Error Handling
```swift
// v2 - Structured error handling with recovery
do {
    let peripheral = try await client.connect(to: device)
} catch let error as BleuError {
    // Use error recovery suggestions
    switch error {
    case .connectionFailed:
        if error.isRecoverable {
            for action in error.recoveryActions {
                switch action {
                case .retry:
                    // Implement retry logic
                    try await client.connect(to: device)
                case .scan:
                    // Rescan for devices
                    let newDevices = try await client.discover()
                default:
                    break
                }
            }
        }
    default:
        // Handle other errors
        break
    }
}
```

## New Features in v2

### Security Configuration

```swift
// Configure security for production
let securityConfig = SecurityConfiguration.secure
await BleuSecurityManager.shared.updateSecurityConfiguration(securityConfig)

// Trust specific devices
await BleuSecurityManager.shared.trustDevice(deviceId, level: .verified)

// Use secure connections
let peripheral = try await client.secureConnect(to: deviceId)
```

### Performance Optimization

```swift
// Configure for high performance
let config = BufferConfiguration.highPerformance
await BleuDataOptimizer.shared.setConfiguration(config)

// Send optimized data
let response = try await client.sendOptimizedData(
    to: deviceId,
    data: largeDataSet,
    serviceUUID: serviceUUID,
    characteristicUUID: characteristicUUID
)
```

### Connection Management

```swift
// Set up automatic reconnection
let reconnectionPolicy = ReconnectionPolicy.aggressive

let peripheral = try await client.connectWithReconnection(
    to: deviceId,
    policy: reconnectionPolicy
)

// Monitor connection quality
let observerId = await BleuConnectionManager.shared.addConnectionObserver { deviceId, state in
    print("Device \(deviceId.name ?? "Unknown") state: \(state)")
}
```

### Comprehensive Logging

```swift
// Configure logging for debugging
await BleuLogger.shared.setMinimumLevel(.debug)
await BleuLogger.shared.addDestination(FileLogDestination(fileURL: logFileURL))

// Contextual logging
await BleuLogger.shared.info(
    "Device connected",
    category: .connection,
    deviceId: device.identifier.uuid.uuidString,
    metadata: ["rssi": "\(device.rssi)", "quality": "excellent"]
)
```

## Migration Checklist

- [ ] Update minimum deployment targets
- [ ] Update dependencies to Bleu v2
- [ ] Migrate from callback-based to async/await
- [ ] Convert Communicable protocols to RemoteProcedure
- [ ] Replace Beacon/Radar with BleuServer/BleuClient
- [ ] Update error handling to use BleuError
- [ ] Add security configuration for production
- [ ] Configure logging and monitoring
- [ ] Update tests to use new APIs
- [ ] Test thoroughly on target devices

## Common Issues

### 1. Swift Concurrency Warnings

**Issue**: Actor isolation warnings in Swift 6.1

**Solution**: Use proper actor isolation:
```swift
@MainActor
class ViewController: UIViewController {
    func updateUI(with data: SensorData) async {
        // UI updates are now actor-isolated to MainActor
        temperatureLabel.text = "\(data.temperature)°C"
    }
}
```

### 2. Sendable Conformance

**Issue**: Data types not conforming to Sendable

**Solution**: Make your types Sendable:
```swift
struct MyData: Sendable, Codable {
    let value: String
    let timestamp: Date
}
```

### 3. Configuration Complexity

**Issue**: Too many configuration options

**Solution**: Use preset configurations:
```swift
// Use presets for common scenarios
let config = BleuConfiguration.production // or .development, .staging
await BleuConfigurationManager.shared.updateConfiguration(config)
```

## Support

If you encounter issues during migration:

1. Check the [API Reference](API_REFERENCE.md)
2. Review [Examples](Examples/) for common patterns
3. Open an issue on [GitHub](https://github.com/1amageek/bleu/issues)
4. Contact support at support@bleu.framework

---

This migration guide covers the major changes. For detailed API documentation, see [API_REFERENCE.md](API_REFERENCE.md).