# 真の問題：Bleuが独自のMethodRegistryを持っている

## 問題の本質

Bleuは `swift-actor-runtime` を統合したが、**MethodRegistryだけは独自実装を使い続けている**。

これが8つのテスト失敗の根本原因。

## アーキテクチャの矛盾

### 現在の実装（間違っている）

```
Bleu/Sources/Bleu/
├── Core/
│   ├── BleuTypes.swift
│   │   ├── ❌ InvocationEnvelope (削除済み - ActorRuntimeを使用)
│   │   └── ❌ ResponseEnvelope (削除済み - ActorRuntimeを使用)
│   └── BLEActorSystem.swift
│       └── ✅ import ActorRuntime (InvocationEnvelope使用)
│
└── Mapping/
    └── MethodRegistry.swift
        └── ❌ Bleu独自のMethodRegistry（ActorRuntimeと重複）
```

### 正しいアーキテクチャ（あるべき姿）

```
swift-actor-runtime (Universal primitives)
├── InvocationEnvelope ✅
├── ResponseEnvelope ✅
└── MethodRegistry ⚠️ Bleuはこれも使うべき！

Bleu (BLE-specific transport)
├── BLEActorSystem (ActorRuntimeのMethodRegistryを使用)
└── BLETransport (MTU fragmentation)
```

## コード比較

### swift-actor-runtime の MethodRegistry

```swift
// swift-actor-runtime/Sources/ActorRuntime/Core/MethodRegistry.swift

/// Thread-safe registry for distributed method handlers
public final class MethodRegistry: Sendable {
    public typealias MethodHandler = @Sendable (Data) async throws -> Data

    /// Register a method handler
    ///
    /// - Parameters:
    ///   - methodName: Method identifier (typically mangled Swift name)
    ///   - handler: Async closure that executes the method
    ///
    public func register(_ methodName: String, handler: @escaping MethodHandler) {
        mutex.withLock { state in
            state.methods[methodName] = handler
        }
    }

    /// Execute a registered method
    public func execute(_ methodName: String, arguments: Data) async throws -> Data {
        guard let handler = mutex.withLock({ state in state.methods[methodName] }) else {
            throw RuntimeError.methodNotFound(methodName)
        }
        return try await handler(arguments)
    }
}
```

**特徴**:
- ✅ `Sendable` (Mutex使用)
- ✅ メソッド名のみで管理（actorID不要）
- ✅ **マングル名を想定**
- ✅ シンプルなAPI

### Bleu の MethodRegistry（重複実装）

```swift
// Bleu/Sources/Bleu/Mapping/MethodRegistry.swift

/// Registry for distributed actor methods
public actor MethodRegistry {
    private struct MethodEntry {
        let actorID: UUID
        let methodName: String
        let handler: MethodHandler
        let isVoid: Bool
    }

    private var methods: [UUID: [String: MethodEntry]] = [:]

    /// Register a method handler
    public func register(
        actorID: UUID,
        methodName: String,
        handler: @escaping MethodHandler,
        isVoid: Bool = false
    ) {
        if methods[actorID] == nil {
            methods[actorID] = [:]
        }
        methods[actorID]?[methodName] = MethodEntry(...)
    }

    /// Execute a registered method
    public func execute(
        actorID: UUID,
        methodName: String,
        arguments: [Data]
    ) async throws -> Data {
        guard let entry = methods[actorID]?[methodName] else {
            throw BleuError.methodNotSupported(methodName)
        }
        // ...
    }
}
```

**特徴**:
- ❌ `actor` (不必要なactor isolation)
- ❌ actorID + methodName の2層構造（複雑）
- ❌ `[Data]` 引数（ActorRuntimeは単一`Data`）
- ❌ `isVoid` フラグ（不要な複雑さ）
- ❌ マングル名を想定していない

## なぜマングル名が来るのか

```swift
// BLEActorSystem.swift:292
let methodName = target.identifier

// Swift Distributed Actorsでは、target.identifierは
// コンパイラが生成したマングル名を返す
// 例: "$s9BleuTests11SensorActorC15readTemperatureSdyYaKFTE"
```

これは**Swiftの仕様**であり、変更できません。

## swift-actor-runtimeの設計思想

`swift-actor-runtime` のコメントより：

```swift
/// ## Design Rationale
///
/// Swift does not expose public APIs to execute distributed actor methods by name.
/// `DistributedActorSystem.executeDistributedTarget` delegates to internal
/// runtime APIs. MethodRegistry provides a workaround through manual registration.
```

つまり：
1. **Swiftはdistributed methodを名前で実行するAPIを公開していない**
2. **マングル名を使って手動登録するしかない**
3. **これはSwift Distributed Actorsの既知の制限**

## 正しい統合方法

### Step 1: Bleuの独自MethodRegistryを削除

```bash
rm /Users/1amageek/Desktop/Bleu/Sources/Bleu/Mapping/MethodRegistry.swift
```

### Step 2: ActorRuntimeのMethodRegistryをインポート

```swift
// BLEActorSystem.swift
import ActorRuntime  // ✅ 既にある

// MethodRegistry.sharedの代わりに
// ActorRuntime.MethodRegistry()を各actorごとに持つ
```

### Step 3: BLEActorSystemの修正

```swift
// BLEActorSystem.swift

public final class BLEActorSystem: DistributedActorSystem, @unchecked Sendable {

    // ✅ Actor単位でMethodRegistryを管理
    private actor RegistryManager {
        private var registries: [UUID: ActorRuntime.MethodRegistry] = [:]

        func getOrCreate(for actorID: UUID) -> ActorRuntime.MethodRegistry {
            if let registry = registries[actorID] {
                return registry
            }
            let registry = ActorRuntime.MethodRegistry()
            registries[actorID] = registry
            return registry
        }

        func remove(_ actorID: UUID) {
            registries.removeValue(forKey: actorID)
        }
    }

    private let registryManager = RegistryManager()

    // handleIncomingRPC()の修正
    public func handleIncomingRPC(_ envelope: InvocationEnvelope) async -> ResponseEnvelope {
        do {
            guard let actorID = UUID(uuidString: envelope.recipientID) else {
                return ResponseEnvelope(
                    callID: envelope.callID,
                    result: .failure(.invalidEnvelope("Invalid recipient ID"))
                )
            }

            // ✅ ActorRuntimeのMethodRegistryを使用
            let registry = await registryManager.getOrCreate(for: actorID)

            // ✅ マングル名で直接実行
            let resultData = try await registry.execute(
                envelope.target,  // マングル名をそのまま使用
                arguments: envelope.arguments
            )

            return ResponseEnvelope(
                callID: envelope.callID,
                result: .success(resultData)
            )
        } catch let error as RuntimeError {
            return ResponseEnvelope(
                callID: envelope.callID,
                result: .failure(error)
            )
        } catch {
            return ResponseEnvelope(
                callID: envelope.callID,
                result: .failure(.executionFailed("Unexpected error", underlying: error.localizedDescription))
            )
        }
    }
}
```

### Step 4: アクターのメソッド登録

```swift
// MockActorExamples.swift

distributed actor SensorActor: PeripheralActor {
    typealias ActorSystem = BLEActorSystem

    private var temperature: Double = 22.5

    // ✅ マングル名で登録
    func registerMethods(with registry: ActorRuntime.MethodRegistry) async {
        // ⚠️ 問題: マングル名をどうやって取得するか？

        // Option 1: target.identifierをキャプチャ（実装困難）
        // Option 2: #functionマクロ（マングル名は取れない）
        // Option 3: 手動で指定（保守性最悪）

        // 実は、これも間違ったアプローチ...
    }

    distributed func readTemperature() async -> Double {
        return temperature
    }
}
```

## 本当の問題：メソッド登録は不要かもしれない

### executeDistributedTarget の存在

```swift
// DistributedActorSystem protocol
func executeDistributedTarget(
    on actor: any DistributedActor,
    target: RemoteCallTarget,
    invocationDecoder: inout InvocationDecoder,
    handler: (inout InvocationDecoder) async throws -> InvocationResult
) async throws
```

これは**Swiftランタイムが呼び出すメソッド**で、distributed funcを実行します。

### 正しい実装パターン

他のDistributed Actor実装を見ると：

```swift
// Typical DistributedActorSystem implementation
public func executeDistributedTarget(...) async throws {
    // Swiftランタイムがここを呼ぶ
    // target.identifierにはマングル名が入っている
    // handlerを呼ぶと実際のメソッドが実行される

    return try await handler(&invocationDecoder)
}
```

つまり、**MethodRegistryは本来不要**です！

### なぜMethodRegistryが存在するのか？

`swift-actor-runtime` のコメントをもう一度見ると：

```swift
/// Swift does not expose public APIs to execute distributed actor methods by name.
/// `DistributedActorSystem.executeDistributedTarget` delegates to internal
/// runtime APIs. MethodRegistry provides a workaround through manual registration.
```

これは**リモート側の実行**のための回避策です。

#### ローカル実行（正常）

```swift
// Central側
let temp = try await remoteSensor.readTemperature()
// ↓
// BLEActorSystem.remoteCall() → BLE送信
// ↓
// Peripheral側でBLE受信 → handleIncomingRPC()
// ↓
// ⚠️ ここでどうやってローカルのSensorActor.readTemperature()を呼ぶ？
```

#### 問題点

Peripheral側には**実際のSensorActorインスタンス**がいるのに、
`envelope.target`（マングル名）から**そのメソッドを実行する方法がない**。

### 正しい解決策：executeDistributedTargetを使う

```swift
// BLEActorSystem.handleIncomingRPC()

public func handleIncomingRPC(_ envelope: InvocationEnvelope) async -> ResponseEnvelope {
    do {
        guard let actorID = UUID(uuidString: envelope.recipientID) else {
            return ResponseEnvelope(...)
        }

        // ✅ InstanceRegistryからアクターを取得
        guard let actor = await instanceRegistry.get(actorID, as: (any DistributedActor).self) else {
            return ResponseEnvelope(
                callID: envelope.callID,
                result: .failure(.actorNotFound(envelope.recipientID))
            )
        }

        // ✅ RemoteCallTargetを再構築
        // ⚠️ 問題: envelope.targetからRemoteCallTargetを作れない
        //    RemoteCallTargetはopaqueな構造体で、外部から作成できない

        // ❌ これは不可能
        // let target = RemoteCallTarget(identifier: envelope.target)

        // ✅ 結論: MethodRegistryが必要
    }
}
```

## 結論

### なぜMethodRegistryが必要か

Swift Distributed Actorsには**構造的な制限**があります：

1. **`RemoteCallTarget` は外部から作成できない**（internal struct）
2. **`executeDistributedTarget` はSwiftランタイムからしか呼べない**
3. **マングル名からメソッドを実行するpublic APIがない**

よって、**MethodRegistryによる手動登録が唯一の解決策**。

### 正しいアーキテクチャ

```
1. Actor作成時にメソッドを登録（マングル名で）
   ↓
2. remoteCall()でマングル名をenvelopeに入れて送信
   ↓
3. handleIncomingRPC()でマングル名からMethodRegistryで実行
```

### Bleuがすべきこと

#### Option A: ActorRuntimeのMethodRegistryを使う（推奨）

```swift
// 1. Bleu/Sources/Bleu/Mapping/MethodRegistry.swift を削除

// 2. BLEActorSystemでActorRuntime.MethodRegistryを使う
import ActorRuntime

public final class BLEActorSystem {
    private let methodRegistry = ActorRuntime.MethodRegistry()

    public func handleIncomingRPC(_ envelope: InvocationEnvelope) async -> ResponseEnvelope {
        do {
            // ✅ ActorRuntimeのMethodRegistryで実行
            let resultData = try await methodRegistry.execute(
                envelope.target,
                arguments: envelope.arguments
            )
            return ResponseEnvelope(callID: envelope.callID, result: .success(resultData))
        } catch {
            // ...
        }
    }
}

// 3. アクターでメソッド登録
distributed actor SensorActor: PeripheralActor {
    func setup(system: BLEActorSystem) async {
        let registry = system.methodRegistry  // ⚠️ publicにする必要がある

        // ⚠️ 問題: マングル名をどうやって知るか？
        //    → 次のセクション参照
    }
}
```

#### Option B: マングル名の取得方法

##### 方法1: コンパイラに頼る（不可能）

```swift
// ❌ こんなAPIは存在しない
let mangledName = #mangledName(SensorActor.readTemperature)
```

##### 方法2: RemoteCallTargetからキャプチャ（複雑）

```swift
// BLEActorSystem.remoteCall()内で
let methodName = target.identifier  // マングル名

// これをどこかに保存？
// → アクター側でアクセスできない
```

##### 方法3: ダミーRPCで取得（ハック）

```swift
distributed actor SensorActor: PeripheralActor {
    func registerMethods(system: BLEActorSystem) async {
        // ダミーのremoteCallを発行してマングル名をキャプチャ
        // ⚠️ かなりハック的
    }
}
```

##### 方法4: 手動指定（現実的だが保守性低い）

```swift
distributed actor SensorActor: PeripheralActor {
    func registerMethods(with registry: MethodRegistry) async {
        // ⚠️ マングル名を手動で指定（タイポの危険）
        await registry.register("$s9BleuTests11SensorActorC15readTemperatureSdyYaKFTE") { _ in
            let result = await self.readTemperature()
            return try JSONEncoder().encode(result)
        }
    }
}
```

##### 方法5: Swift Macroで自動生成（v3.0.0）⭐

```swift
@DistributedActor
@AutoRegisterMethods
distributed actor SensorActor: PeripheralActor {
    distributed func readTemperature() async -> Double {
        return 22.5
    }

    // マクロが自動生成↓
    // func registerMethods(with registry: MethodRegistry) async {
    //     await registry.register("$s...") { ... }
    // }
}
```

### 最終推奨

#### 短期（v2.1.1 patch）

1. **Bleuの独自MethodRegistryを削除**
2. **ActorRuntime.MethodRegistryを使用**
3. **テストアクターで手動メソッド登録**（マングル名を含む）

```swift
// MockActorExamples.swift
distributed actor SensorActor: PeripheralActor {
    typealias ActorSystem = BLEActorSystem

    // ⚠️ この関数をsetup()時に呼び出す
    func registerMethods(with registry: ActorRuntime.MethodRegistry) async {
        // マングル名を調べる方法:
        // 1. テスト実行時のエラーメッセージから取得
        // 2. または nm コマンドでシンボルを抽出

        await registry.register("$s9BleuTests11SensorActorC15readTemperatureSdyYaKFTE") { _ in
            let result = await self.readTemperature()
            return try JSONEncoder().encode(result)
        }

        await registry.register("$s9BleuTests11SensorActorC13readHumiditySdyYaKFTE") { _ in
            let result = await self.readHumidity()
            return try JSONEncoder().encode(result)
        }
    }

    distributed func readTemperature() async -> Double { 22.5 }
    distributed func readHumidity() async -> Double { 45.0 }
}
```

#### 長期（v3.0.0）

**Swift Macroでマングル名を自動解決**し、`registerMethods()`を自動生成。
