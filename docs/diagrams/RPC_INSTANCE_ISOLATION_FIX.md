# RPC Instance Isolation Fix - Visual Diagrams

## Problem: Instance Isolation Broken

### Before Fix (BROKEN)

```
┌─────────────────────────────────────────────────────────────┐
│                     User Application                        │
└─────────────────────────────────────────────────────────────┘
                               │
                               │ let system = BLEActorSystem.production()
                               │ system.startAdvertising(actor)
                               ↓
┌─────────────────────────────────────────────────────────────┐
│                 BLEActorSystem Instance A                   │
│  ┌───────────────────────────────────────────────────────┐  │
│  │ InstanceRegistry:                                     │  │
│  │   • actor123 → TemperatureSensor instance            │  │
│  │                                                       │  │
│  │ MethodRegistry:                                       │  │
│  │   • actor123.readTemperature() → handler             │  │
│  └───────────────────────────────────────────────────────┘  │
│                                                             │
│  ┌───────────────────────────────────────────────────────┐  │
│  │ CoreBluetoothPeripheralManager                        │  │
│  │   • Receives write request                            │  │
│  │   • Calls handleRPCInvocation()                       │  │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                               │
                               │ handleRPCInvocation() does:
                               │ let actorSystem = BLEActorSystem.shared
                               ↓
┌─────────────────────────────────────────────────────────────┐
│              BLEActorSystem.shared (Instance B)             │
│  ┌───────────────────────────────────────────────────────┐  │
│  │ InstanceRegistry:                                     │  │
│  │   • EMPTY! ❌                                         │  │
│  │                                                       │  │
│  │ MethodRegistry:                                       │  │
│  │   • EMPTY! ❌                                         │  │
│  └───────────────────────────────────────────────────────┘  │
│                                                             │
│  handleIncomingRPC(envelope):                               │
│    → Look for actor123 in InstanceRegistry                  │
│    → NOT FOUND! ❌                                          │
│    → Return ResponseEnvelope(result: .failure(              │
│         RuntimeError.actorNotFound("actor123")             │
│       ))                                                    │
└─────────────────────────────────────────────────────────────┘

Result: RPC FAILS with "actor not found" error ❌
```

### After Fix (CORRECT)

```
┌─────────────────────────────────────────────────────────────┐
│                     User Application                        │
└─────────────────────────────────────────────────────────────┘
                               │
                               │ let system = BLEActorSystem.production()
                               │ system.startAdvertising(actor)
                               ↓
┌─────────────────────────────────────────────────────────────┐
│                 BLEActorSystem Instance A                   │
│  ┌───────────────────────────────────────────────────────┐  │
│  │ InstanceRegistry:                                     │  │
│  │   • actor123 → TemperatureSensor instance            │  │
│  │                                                       │  │
│  │ MethodRegistry:                                       │  │
│  │   • actor123.readTemperature() → handler             │  │
│  └───────────────────────────────────────────────────────┘  │
│                                                             │
│  ┌───────────────────────────────────────────────────────┐  │
│  │ EventBridge (Instance A's bridge)                     │  │
│  │   rpcRequestHandler = { envelope in                   │  │
│  │     return await self.handleIncomingRPC(envelope)     │  │
│  │   }                                                   │  │
│  └───────────────────────────────────────────────────────┘  │
│                                                             │
│  ┌───────────────────────────────────────────────────────┐  │
│  │ CoreBluetoothPeripheralManager                        │  │
│  │   • Receives write request                            │  │
│  │   • Calls handleRPCInvocation()                       │  │
│  └───────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────┘
                               │
                               │ handleRPCInvocation() does:
                               │ eventChannel.send(.writeRequestReceived(...))
                               ↓
┌─────────────────────────────────────────────────────────────┐
│           EventBridge (same Instance A's bridge)            │
│                                                             │
│  distribute(event) → handleWriteRequest() → calls:          │
│                                                             │
│  rpcRequestHandler(envelope)                                │
│     ↓                                                       │
│     Returns to SAME Instance A!                             │
└─────────────────────────────────────────────────────────────┘
                               │
                               │ Back to Instance A
                               ↓
┌─────────────────────────────────────────────────────────────┐
│              BLEActorSystem Instance A (CORRECT!)           │
│                                                             │
│  handleIncomingRPC(envelope):                               │
│    → Look for actor123 in THIS instance's registry          │
│    → FOUND! ✅                                              │
│    → Execute method via THIS instance's MethodRegistry      │
│    → FOUND! ✅                                              │
│    → Return ResponseEnvelope(result: .success(data))        │
└─────────────────────────────────────────────────────────────┘

Result: RPC SUCCEEDS! ✅
```

## Code Flow Comparison

### Before Fix (BROKEN)

```
┌─────────────────────────┐
│  Write Request Arrives  │
└───────────┬─────────────┘
            │
            ↓
┌──────────────────────────────────────────┐
│ CoreBluetoothPeripheralManager           │
│   (CBPeripheralManagerDelegate)          │
│                                          │
│   didReceiveWrite() callback             │
└───────────┬──────────────────────────────┘
            │
            ↓
┌──────────────────────────────────────────┐
│ handleWriteRequests()                    │
│   • Extract request data                 │
│   • Check if RPC characteristic          │
│   • Reassemble fragments                 │
└───────────┬──────────────────────────────┘
            │
            ↓
┌──────────────────────────────────────────┐
│ handleRPCInvocation()                    │
│   • Decode InvocationEnvelope            │
│   • let system = BLEActorSystem.shared ❌│
│   • system.handleIncomingRPC()           │
└───────────┬──────────────────────────────┘
            │
            ↓ WRONG INSTANCE!
┌──────────────────────────────────────────┐
│ BLEActorSystem.shared (Instance B)       │
│   • Empty InstanceRegistry ❌            │
│   • Empty MethodRegistry ❌              │
│   • Returns "actor not found" error      │
└──────────────────────────────────────────┘
```

### After Fix (CORRECT)

```
┌─────────────────────────┐
│  Write Request Arrives  │
└───────────┬─────────────┘
            │
            ↓
┌──────────────────────────────────────────┐
│ CoreBluetoothPeripheralManager           │
│   (CBPeripheralManagerDelegate)          │
│                                          │
│   didReceiveWrite() callback             │
└───────────┬──────────────────────────────┘
            │
            ↓
┌──────────────────────────────────────────┐
│ handleWriteRequests()                    │
│   • Extract request data                 │
│   • Check if RPC characteristic          │
│   • Reassemble fragments                 │
└───────────┬──────────────────────────────┘
            │
            ↓
┌──────────────────────────────────────────┐
│ handleRPCInvocation()                    │
│   • Emit .writeRequestReceived event ✅  │
│   • No direct system access!             │
└───────────┬──────────────────────────────┘
            │
            ↓ EVENT
┌──────────────────────────────────────────┐
│ EventBridge (Instance A's bridge)        │
│   • distribute(event)                    │
│   • handleWriteRequest()                 │
│   • Decode InvocationEnvelope            │
│   • Call rpcRequestHandler               │
└───────────┬──────────────────────────────┘
            │
            ↓ CORRECT INSTANCE!
┌──────────────────────────────────────────┐
│ BLEActorSystem (Instance A)              │
│   • handleIncomingRPC()                  │
│   • Look in THIS instance's registries ✅│
│   • Execute method ✅                    │
│   • Return ResponseEnvelope              │
└───────────┬──────────────────────────────┘
            │
            ↓
┌──────────────────────────────────────────┐
│ EventBridge                              │
│   • Fragment response                    │
│   • Send via peripheralManager           │
└──────────────────────────────────────────┘
```

## Multi-Instance Scenario

### Why Instance Isolation Matters

```
┌─────────────────────────────────────────────────────────────┐
│                        Application                          │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│  // Use Case: Multiple independent BLE connections         │
│                                                             │
│  let system1 = BLEActorSystem.production()                  │
│  let system2 = BLEActorSystem.production()                  │
│                                                             │
│  // System 1: Heart Rate Monitor                           │
│  let heartRate = HeartRateSensor(actorSystem: system1)      │
│  system1.startAdvertising(heartRate)                        │
│                                                             │
│  // System 2: Temperature Monitor                           │
│  let temperature = TemperatureSensor(actorSystem: system2)  │
│  system2.startAdvertising(temperature)                      │
│                                                             │
└─────────────────────────────────────────────────────────────┘
                │                                │
                │                                │
                ↓                                ↓
    ┌─────────────────────┐        ┌─────────────────────┐
    │ BLEActorSystem #1   │        │ BLEActorSystem #2   │
    ├─────────────────────┤        ├─────────────────────┤
    │ InstanceRegistry:   │        │ InstanceRegistry:   │
    │  • heartRate ✅     │        │  • temperature ✅   │
    │                     │        │                     │
    │ MethodRegistry:     │        │ MethodRegistry:     │
    │  • getBPM() ✅      │        │  • getTemp() ✅     │
    │                     │        │                     │
    │ EventBridge #1      │        │ EventBridge #2      │
    │  (routes to #1) ✅  │        │  (routes to #2) ✅  │
    └─────────────────────┘        └─────────────────────┘
                │                                │
                │                                │
                ↓                                ↓
    ┌─────────────────────┐        ┌─────────────────────┐
    │  Peripheral Mgr #1  │        │  Peripheral Mgr #2  │
    │  (Port A)           │        │  (Port B)           │
    └─────────────────────┘        └─────────────────────┘

With Fix:
  • RPC to heartRate    → EventBridge #1 → System #1 → ✅ WORKS
  • RPC to temperature  → EventBridge #2 → System #2 → ✅ WORKS

Without Fix (using .shared):
  • RPC to heartRate    → BLEActorSystem.shared → ❌ NOT FOUND
  • RPC to temperature  → BLEActorSystem.shared → ❌ NOT FOUND
```

## Component Relationships

### Architecture Layers (After Fix)

```
┌────────────────────────────────────────────────────────────┐
│                   Application Layer                        │
│                                                            │
│  distributed actor MyActor {                               │
│    typealias ActorSystem = BLEActorSystem                  │
│    distributed func myMethod() async { ... }               │
│  }                                                         │
└────────────────────────────────────────────────────────────┘
                            │
                            │ Uses
                            ↓
┌────────────────────────────────────────────────────────────┐
│                   BLEActorSystem                           │
│  ┌──────────────────────────────────────────────────────┐  │
│  │ • Owns: InstanceRegistry                             │  │
│  │ • Owns: MethodRegistry                               │  │
│  │ • Owns: EventBridge                                  │  │
│  │ • Owns: PeripheralManager                            │  │
│  │ • Owns: CentralManager                               │  │
│  │                                                      │  │
│  │ • setupEventHandlers() connects everything           │  │
│  └──────────────────────────────────────────────────────┘  │
└────────────────────────────────────────────────────────────┘
         │                     │                    │
         │ Owns                │ Owns               │ Owns
         ↓                     ↓                    ↓
┌─────────────────┐   ┌─────────────────┐   ┌─────────────────┐
│   EventBridge   │   │ PeripheralMgr   │   │   CentralMgr    │
├─────────────────┤   ├─────────────────┤   ├─────────────────┤
│ • Stores ref to │←──│ • Emits events  │   │ • Emits events  │
│   peripheral    │   │   via channel   │   │   via channel   │
│   manager       │   │                 │   │                 │
│                 │   │ • NO direct     │   │ • NO direct     │
│ • Has closure   │   │   system call   │   │   system call   │
│   back to       │   │                 │   │                 │
│   BLEActorSystem│   │ ✅ FIXED!       │   │ ✅ CORRECT!     │
└─────────────────┘   └─────────────────┘   └─────────────────┘
         │
         │ Events flow through
         ↓
┌─────────────────────────────────────────────────────────────┐
│              rpcRequestHandler Closure                      │
│  { envelope in                                              │
│    await self.handleIncomingRPC(envelope)  // 'self' is     │
│  }                                          // BLEActorSystem│
└─────────────────────────────────────────────────────────────┘
```

## Message Flow Sequence

### Complete RPC Request/Response Flow

```
Central Device                        Peripheral Device
     │                                       │
     │  1. Call: sensor.readTemperature()    │
     ├──────────────────────────────────────>│
     │      (via BLETransport)               │
     │      (fragmented if needed)           │
     │                                       │
     │                                       ↓
     │                        ┌──────────────────────────┐
     │                        │ CBPeripheralManager      │
     │                        │   didReceiveWrite()      │
     │                        └──────────┬───────────────┘
     │                                   │
     │                                   ↓
     │                        ┌──────────────────────────┐
     │                        │ CoreBluetooth            │
     │                        │ PeripheralManager        │
     │                        │   handleWriteRequests()  │
     │                        └──────────┬───────────────┘
     │                                   │
     │                                   ↓
     │                        ┌──────────────────────────┐
     │                        │ BLETransport             │
     │                        │   reassemble fragments   │
     │                        └──────────┬───────────────┘
     │                                   │
     │                                   ↓
     │                        ┌──────────────────────────┐
     │                        │ handleRPCInvocation()    │
     │                        │   emit event ✅          │
     │                        └──────────┬───────────────┘
     │                                   │
     │                                   ↓
     │                        ┌──────────────────────────┐
     │                        │ EventBridge              │
     │                        │   distribute(event)      │
     │                        └──────────┬───────────────┘
     │                                   │
     │                                   ↓
     │                        ┌──────────────────────────┐
     │                        │ EventBridge              │
     │                        │   handleWriteRequest()   │
     │                        │   decode envelope        │
     │                        └──────────┬───────────────┘
     │                                   │
     │                                   ↓
     │                        ┌──────────────────────────┐
     │                        │ rpcRequestHandler()      │
     │                        │   (closure to system)    │
     │                        └──────────┬───────────────┘
     │                                   │
     │                                   ↓
     │                        ┌──────────────────────────┐
     │                        │ BLEActorSystem           │
     │                        │   handleIncomingRPC()    │
     │                        └──────────┬───────────────┘
     │                                   │
     │                                   ↓
     │                        ┌──────────────────────────┐
     │                        │ InstanceRegistry         │
     │                        │   lookup actor ✅        │
     │                        └──────────┬───────────────┘
     │                                   │
     │                                   ↓
     │                        ┌──────────────────────────┐
     │                        │ MethodRegistry           │
     │                        │   execute method ✅      │
     │                        └──────────┬───────────────┘
     │                                   │
     │                                   ↓
     │                        ┌──────────────────────────┐
     │                        │ Actor Implementation     │
     │                        │   readTemperature()      │
     │                        │   returns 22.5           │
     │                        └──────────┬───────────────┘
     │                                   │
     │                                   ↓
     │                        ┌──────────────────────────┐
     │                        │ BLEActorSystem           │
     │                        │   encode response        │
     │                        └──────────┬───────────────┘
     │                                   │
     │                                   ↓
     │                        ┌──────────────────────────┐
     │                        │ EventBridge              │
     │                        │   fragment response ✅   │
     │                        └──────────┬───────────────┘
     │                                   │
     │                                   ↓
     │                        ┌──────────────────────────┐
     │                        │ PeripheralManager        │
     │                        │   updateValue()          │
     │                        └──────────┬───────────────┘
     │                                   │
     │  2. Response: 22.5                │
     │<──────────────────────────────────┤
     │      (via BLETransport)           │
     │      (fragmented if needed)       │
     │                                   │
     ↓                                   │
┌────────────────┐                      │
│ Central        │                      │
│   got result ✅ │                      │
└────────────────┘                      │
```

## Summary

### Key Changes

1. **Remove Direct System Access**
   - Peripheral managers no longer call `BLEActorSystem.shared`
   - Use event emission instead

2. **Leverage EventBridge**
   - EventBridge routes RPCs to correct system instance
   - Maintains instance isolation

3. **Add Response Fragmentation**
   - EventBridge now fragments large responses
   - Consistent with request fragmentation

### Benefits

- ✅ Instance isolation preserved
- ✅ Multi-system support works
- ✅ Code simplified (38 lines → 8 lines per peripheral)
- ✅ Separation of concerns maintained
- ✅ Large responses handled correctly

### Result

**RPCs now work correctly with all BLEActorSystem instances!**
