# Bug Fixes

## callID Type Mismatch (2025-01-04)

**Issue**: Compilation errors at lines 146 and 435
```
Cannot convert value of type 'String' to expected argument type 'UUID'
```

**Root Cause**:
- `InvocationEnvelope.callID` and `ResponseEnvelope.callID` are `String` type (from swift-actor-runtime)
- `ProxyManager.pendingCalls` was using `UUID` as the key type
- Type mismatch when calling `storePendingCall()` and `resumePendingCall()`

**Fix**: Changed `ProxyManager.pendingCalls` dictionary key type from `UUID` to `String`

```swift
// Before
private var pendingCalls: [UUID: CheckedContinuation<Data, Error>] = [:]

// After
private var pendingCalls: [String: CheckedContinuation<Data, Error>] = [:]
```

**Updated Method Signatures**:
```swift
func storePendingCall(_ callID: String, continuation: CheckedContinuation<Data, Error>)
func resumePendingCall(_ callID: String, with result: Result<Data, Error>)
func cancelPendingCall(_ callID: String, error: Error)
```

**Files Modified**:
- `Sources/Bleu/Core/BLEActorSystem.swift` (lines 37, 56, 60, 66)

**Status**: ✅ Fixed
