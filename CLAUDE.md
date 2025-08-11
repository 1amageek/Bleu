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
├── Core/
│   ├── BLEActorSystem.swift        # Distributed actor system
│   ├── BleuError.swift             # Error types
│   └── BleuTypes.swift             # Common types
├── LocalActors/
│   ├── LocalPeripheralActor.swift  # CBPeripheralManager wrapper
│   └── LocalCentralActor.swift     # CBCentralManager wrapper
├── Mapping/
│   ├── ServiceMapper.swift         # Auto service generation
│   └── MethodRegistry.swift        # Method registration
├── Transport/
│   ├── BLETransport.swift          # Reliable transport
│   └── MessageRouter.swift         # Message routing
└── Extensions/
    └── AsyncChannel.swift          # Event streaming
```

### Core Components

#### BLEActorSystem
- Conforms to `DistributedActorSystem`
- Manages actor lifecycle
- Handles `remoteCall` for RPC
- Automatic service registration

#### LocalPeripheralActor
- Wraps `CBPeripheralManager`
- Converts delegate callbacks to AsyncChannel events
- Manages service/characteristic setup
- Handles advertisement

#### LocalCentralActor
- Wraps `CBCentralManager`
- Manages scanning and connection
- Service/characteristic discovery
- Connection state management

#### ServiceMapper
- Extracts distributed methods via Mirror API
- Generates deterministic UUIDs
- Creates service metadata
- Maps methods to characteristics

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

### Build
```bash
swift build
```

### Test
```bash
swift test
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

## Common Issues

### Distributed Actor Compilation Errors
**Cause**: Delegates calling distributed actor methods directly
**Fix**: Use LocalActors as intermediaries with message passing

### NSLock in Async Context
**Cause**: Legacy synchronization code
**Fix**: Replace with actor isolation

### Method Not Found
**Cause**: Method not marked as `distributed`
**Fix**: Add `distributed` keyword to methods that need RPC

## Best Practices

1. **Keep distributed methods simple** - Complex logic should be local
2. **Use AsyncStream for notifications** - Built-in support for BLE notify/indicate
3. **Let the system handle connections** - Don't manage CBPeripheral/CBCentral directly
4. **Trust automatic reconnection** - System handles transient disconnections
5. **Test on real devices** - Simulator has BLE limitations

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