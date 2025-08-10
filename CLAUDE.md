# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Bleu is a Swift framework for Bluetooth Low Energy (BLE) communication on iOS, macOS, watchOS, and tvOS. It provides a simplified abstraction layer over CoreBluetooth, using Server/Client terminology instead of Peripheral/Central.

## Build Commands

### Xcode Build
```bash
# Build for iOS
xcodebuild -project Bleu.xcodeproj -scheme Bleu -sdk iphonesimulator -destination 'platform=iOS Simulator,name=iPhone 15'

# Build for macOS
xcodebuild -project Bleu.xcodeproj -scheme Bleu -sdk macosx

# Clean build
xcodebuild -project Bleu.xcodeproj -scheme Bleu clean
```

### CocoaPods
```bash
# Validate podspec
pod spec lint Bleu.podspec --allow-warnings

# Install dependencies for example project
cd Example && pod install

# Push to trunk (for maintainers)
pod trunk push Bleu.podspec --allow-warnings
```

## Architecture

### Core Protocol: Communicable
The `Communicable` protocol is the foundation - all data exchanged via BLE must conform to it:
- Requires `serviceUUID` and `characteristicUUID` properties
- Handles data serialization/deserialization
- Located in: `Bleu/Communicable.swift`

### Main Components

1. **Bleu** (`Bleu/Bleu.swift`): Singleton entry point
   - `Bleu.addObserver()` - Monitor bluetooth state changes
   - `Bleu.removeObserver()` - Remove state observers

2. **Beacon** (`Bleu/Beacon.swift`): BLE Server (Peripheral)
   - Advertises services
   - Handles incoming requests
   - Sends responses to connected clients

3. **Radar** (`Bleu/Radar.swift`): BLE Client (Central) 
   - Discovers servers
   - Manages connections
   - Sends requests and receives responses

4. **Request/Receiver** (`Bleu/Request.swift`, `Bleu/Receiver.swift`): Client-side communication
   - Request: Sends data to server
   - Receiver: Listens for server responses

### Data Flow
```
Client (Radar) → Request → Server (Beacon)
                    ↓
Client (Receiver) ← Response ← Server (Beacon)
```

## Key Implementation Patterns

### Creating a Communicable Type
```swift
struct MyData: Communicable {
    let serviceUUID: UUID = UUID(uuidString: "YOUR-SERVICE-UUID")!
    let characteristicUUID: UUID = UUID(uuidString: "YOUR-CHARACTERISTIC-UUID")!
    
    // Your data properties
    var value: String
    
    // Serialization
    var data: Data? {
        return value.data(using: .utf8)
    }
    
    // Deserialization
    init?(data: Data) {
        guard let value = String(data: data, encoding: .utf8) else { return nil }
        self.value = value
    }
}
```

### Server Implementation
- Use `Beacon` for advertising services
- Call `startAdvertising()` to begin
- Handle requests via `BeaconDelegate`

### Client Implementation  
- Use `Radar` for discovering servers
- Create `Request` objects to send data
- Use `Receiver` to listen for responses

## Platform Requirements
- iOS 10.0+
- macOS 10.10+
- watchOS 3.0+
- tvOS 9.0+
- Swift 5.0+

## Testing
Currently no test suite exists. When adding tests:
- Place unit tests in a `Tests/` directory
- Test Communicable protocol conformance
- Mock CoreBluetooth for testing BLE logic

## Common Development Tasks

### Adding a New Communicable Type
1. Create struct/class conforming to `Communicable`
2. Define unique service and characteristic UUIDs
3. Implement data serialization/deserialization
4. Add to Example app for testing

### Debugging BLE Issues
- Check bluetooth state via `Bleu.shared.state`
- Enable verbose logging in CoreBluetooth
- Use Console.app to view BLE system logs
- Test with real devices (simulator has limitations)

## Project Structure
```
Bleu/
├── Bleu/              # Framework source
│   ├── Beacon.swift   # Server implementation
│   ├── Radar.swift    # Client implementation  
│   ├── Request.swift  # Client request handling
│   ├── Receiver.swift # Client response handling
│   └── Communicable.swift # Core protocol
├── Example/           # Sample application
└── Bleu.podspec      # CocoaPods specification
```