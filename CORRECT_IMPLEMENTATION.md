# 正しい実装：executeDistributedTargetを使用

## 発見

`swift-distributed-actors`を調査した結果、**BleuがMethodRegistryを使っているのは間違ったアプローチ**であることが判明しました。

## swift-distributed-actorsの正しい実装

### executeDistributedTargetとは

`executeDistributedTarget`は**Swiftコンパイラが自動生成する関数**で、distributed methodを実行するための標準的な方法です。

```swift
// Swift標準ライブラリ（Distributedモジュール）
public func executeDistributedTarget<Act, Err, Res>(
    on actor: Act,
    target: RemoteCallTarget,
    invocationDecoder: inout InvocationDecoder,
    handler: DistributedTargetInvocationResultHandler
) async throws -> Res
    where Act: DistributedActor
```

**重要なポイント**:
1. これは**publicな関数**（内部APIではない）
2. **コンパイラが実装を生成**（手動実装不要）
3. `RemoteCallTarget`を使って**正しいメソッドを自動的に呼び出す**
4. **MethodRegistryは不要**

### swift-distributed-actorsの実装例

#### ローカル呼び出し（Local Call）

```swift
// ClusterSystem+RemoteCall.swift
func localCall<Act, Err, Res>(
    on actor: Act,
    target: RemoteCallTarget,
    invocation: inout InvocationEncoder,
    throwing: Err.Type,
    returning: Res.Type
) async throws -> Res {
    // InvocationEncoderからDecoderを作成
    var decoder = ClusterInvocationDecoder(from: invocation)

    // ResultHandlerを作成
    let resultHandler = ClusterInvocationResultHandler<Res>()

    // ✅ executeDistributedTargetを呼び出す
    // コンパイラが生成したコードが実際のメソッドを実行
    return try await executeDistributedTarget(
        on: actor,
        target: target,
        invocationDecoder: &decoder,
        handler: resultHandler
    )
}
```

#### リモートからの受信（Inbound Remote Call）

```swift
// ClusterSystem+RemoteCall.swift
func receiveInvocation(_ message: InvocationMessage) async {
    // Actorインスタンスを解決
    guard let actor = resolveLocalActor(message.actorID) else {
        return
    }

    // InvocationMessageからDecoderを作成
    var decoder = ClusterInvocationDecoder(from: message)

    // ResultHandlerを作成（レスポンスを送信するため）
    let resultHandler = ClusterInvocationResultHandler<Any>()

    // ✅ executeDistributedTargetを呼び出す
    try await executeDistributedTarget(
        on: actor,
        target: target,  // message.targetIdentifierから再構築
        invocationDecoder: &decoder,
        handler: resultHandler
    )

    // resultHandlerから結果を取得して返送
    sendResponse(resultHandler.result)
}
```

### Bleuの間違った実装

#### 現在の実装（executeDistributedTarget未実装）

```swift
// BLEActorSystem.swift:367-378
public func executeDistributedTarget<Act, Err, Res>(
    on actor: Act,
    target: RemoteCallTarget,
    invocation: inout InvocationDecoder,
    throwing: Err.Type,
    returning: Res.Type
) async throws -> Res
    where Act: DistributedActor,
          Act.ID == ActorID,
          Err: Error,
          Res: SerializationRequirement {

    // ❌ 実装されていない
    // NOTE: This requires access to Swift's internal distributed actor runtime APIs
    // which are not publicly available. Will be implemented when Swift exposes these APIs.
    throw BleuError.methodNotSupported(target.identifier)
}
```

**問題点**:
1. コメントが間違っている（APIはpublic）
2. この関数は**実装不要**（コンパイラが自動生成）
3. `MethodRegistry`という回避策を使っている

#### 間違った回避策（MethodRegistry使用）

```swift
// BLEActorSystem.swift:381-415
public func handleIncomingRPC(_ envelope: InvocationEnvelope) async -> ResponseEnvelope {
    // ❌ MethodRegistryを使っている
    let registry = await getMethodRegistry(for: actorID)

    // ❌ マングル名で手動実行
    let resultData = try await registry.execute(
        envelope.target,
        arguments: envelope.arguments
    )
}
```

**問題点**:
1. 各アクターで手動メソッド登録が必要
2. マングル名を扱う必要がある
3. 型安全性が失われる
4. Swiftの標準機能を使っていない

## 正しい実装方法

### Step 1: executeDistributedTargetの実装を削除

```swift
// ❌ この実装を削除
public func executeDistributedTarget<Act, Err, Res>(...) async throws -> Res {
    throw BleuError.methodNotSupported(target.identifier)
}

// ✅ 何も書かない（コンパイラが自動生成）
// または、デバッグ用のログだけ追加
```

### Step 2: handleIncomingRPCを書き直し

```swift
public func handleIncomingRPC(_ envelope: InvocationEnvelope) async -> ResponseEnvelope {
    do {
        let instanceRegistry = InstanceRegistry.shared

        // 1. ActorIDを解決
        guard let actorID = UUID(uuidString: envelope.recipientID) else {
            return ResponseEnvelope(
                callID: envelope.callID,
                result: .failure(.invalidEnvelope("Invalid recipient ID"))
            )
        }

        // 2. Actorインスタンスを取得
        guard let actor = await instanceRegistry.get(actorID, as: (any DistributedActor).self) else {
            return ResponseEnvelope(
                callID: envelope.callID,
                result: .failure(.actorNotFound(envelope.recipientID))
            )
        }

        // 3. ❓問題: RemoteCallTargetをどうやって作る？
        // envelope.target (String) → RemoteCallTarget

        // RemoteCallTargetはopaqueな構造体で外部から作成できない
        // この問題をどう解決するか？
    }
}
```

### 問題：RemoteCallTargetの作成

`RemoteCallTarget`は内部構造体で、外部から作成できません：

```swift
// Distributedモジュール（Swift標準ライブラリ）
public struct RemoteCallTarget {
    internal let identifier: String  // マングル名
    // その他の内部フィールド

    // ❌ public initがない
}
```

### 解決策：remoteCallからexecuteDistributedTargetへ直接

実は、**handleIncomingRPCでexecuteDistributedTargetを呼ぶ必要はありません**。

正しいフローは：

```
Central側:
1. remoteCall() → InvocationEnvelopeを作成 → BLE送信

Peripheral側:
2. BLE受信 → InvocationEnvelopeをデコード
3. ❌ executeDistributedTarget()を直接呼ぶのではない
4. ✅ InvocationEncoderを再構築して、remoteCall()を**ローカルで呼ぶ**
```

### 正しい実装：ローカルremoteCallへのリダイレクト

```swift
// BLEActorSystem.swift

public func handleIncomingRPC(_ envelope: InvocationEnvelope) async -> ResponseEnvelope {
    do {
        // 1. Actorを解決
        guard let actorID = UUID(uuidString: envelope.recipientID) else {
            return ResponseEnvelope(
                callID: envelope.callID,
                result: .failure(.invalidEnvelope("Invalid recipient ID"))
            )
        }

        guard let actor = await instanceRegistry.get(actorID, as: (any DistributedActor).self) else {
            return ResponseEnvelope(
                callID: envelope.callID,
                result: .failure(.actorNotFound(envelope.recipientID))
            )
        }

        // 2. InvocationDecoderを作成
        var decoder = BLEInvocationDecoder(from: envelope)

        // 3. ✅ ここが重要：
        //    localCall() または executeDistributedTarget() を呼ぶ
        //    ただし、RemoteCallTargetが必要...

        // ⚠️ 問題: RemoteCallTargetを作れない

    } catch {
        // エラー処理
    }
}
```

### 本当の問題：アーキテクチャの根本的な誤り

実は、Bleuのアーキテクチャには**根本的な設計ミス**があります：

#### 問題のあるフロー

```
Central (Device A):
  remoteCall() → BLEActorSystem.remoteCall()
  ↓
  InvocationEnvelope作成 → BLE送信
  ↓
Peripheral (Device B):
  BLE受信 → handleIncomingRPC()
  ↓
  ❌ executeDistributedTarget()を呼びたいが、RemoteCallTargetがない
  ↓
  ❌ MethodRegistryで回避（間違った方法）
```

#### 正しいフロー（swift-distributed-actorsと同じ）

```
Central (Device A):
  remoteCall() → ClusterSystem.remoteCall()
  ↓
  リモート判定 → InvocationMessage作成 → ネットワーク送信
  ↓
Peripheral (Device B):
  ネットワーク受信 → receiveInvocation()
  ↓
  ✅ executeDistributedTarget()を直接呼ぶ
     （RemoteCallTargetはメッセージに含まれている）
```

**違い**:
- swift-distributed-actors: `InvocationMessage`に`RemoteCallTarget`を含める
- Bleu: `InvocationEnvelope`に`target: String`（マングル名のみ）

### 解決策：InvocationEnvelopeにRemoteCallTargetを追加

#### Option A: InvocationEnvelopeを拡張（swift-actor-runtimeを変更）

```swift
// swift-actor-runtime/Sources/ActorRuntime/Envelope.swift
public struct InvocationEnvelope: Codable, Sendable {
    public let recipientID: String
    public let senderID: String?
    public let target: String  // ← マングル名だけ

    // ⚠️ これを追加したいが...
    // public let remoteCallTarget: RemoteCallTarget  // ← Codableではない

    public let arguments: Data
    public let metadata: InvocationMetadata
}
```

**問題**: `RemoteCallTarget`は`Codable`ではないため、シリアライズできない。

#### Option B: BLE Transport層でRemoteCallTargetを保持

```swift
// BLEActorSystem.swift

private actor RemoteCallTargetCache {
    private var cache: [String: RemoteCallTarget] = [:]

    func store(_ target: RemoteCallTarget, for callID: String) {
        cache[callID] = target
    }

    func retrieve(for callID: String) -> RemoteCallTarget? {
        return cache[callID]
    }
}

public func remoteCall<Act, Err, Res>(...) async throws -> Res {
    let callID = UUID().uuidString

    // ✅ RemoteCallTargetをキャッシュ
    await remoteCallTargetCache.store(target, for: callID)

    let envelope = InvocationEnvelope(
        callID: callID,
        recipientID: actor.id.uuidString,
        target: target.identifier,
        arguments: argumentsData
    )

    // BLE送信...
}

public func handleIncomingRPC(_ envelope: InvocationEnvelope) async -> ResponseEnvelope {
    // ❌ これも間違い：callIDは送信側のもの、受信側にはキャッシュがない
}
```

**問題**: キャッシュは送信側にしかない。

#### Option C: マングル名からRemoteCallTargetを再構築（不可能）

```swift
// ❌ このようなAPIは存在しない
let target = RemoteCallTarget(identifier: envelope.target)
```

## 結論：MethodRegistryは必要

`RemoteCallTarget`を外部から作成できない以上、**MethodRegistryによる手動登録が唯一の解決策**です。

### なぜswift-distributed-actorsはMethodRegistryが不要なのか？

`swift-distributed-actors`は**同じプロセス内で通信**するため：

```swift
// ClusterSystem (同じプロセス内)
func receiveInvocation(_ message: InvocationMessage) async {
    // ✅ メッセージに RemoteCallTarget が含まれている
    let target: RemoteCallTarget = message.target

    // ✅ executeDistributedTarget を直接呼べる
    try await executeDistributedTarget(
        on: actor,
        target: target,  // ← これがある
        invocationDecoder: &decoder,
        handler: resultHandler
    )
}
```

### なぜBleuはMethodRegistryが必要なのか？

Bleuは**異なるプロセス間（BLEデバイス間）で通信**するため：

```swift
// BLE経由の通信（別プロセス）
func handleIncomingRPC(_ envelope: InvocationEnvelope) async -> ResponseEnvelope {
    // ❌ InvocationEnvelopeには RemoteCallTarget がない
    // envelope.target は String（マングル名）のみ

    // ❌ RemoteCallTargetを作成できない
    // let target = RemoteCallTarget(identifier: envelope.target)  // 不可能

    // ❌ executeDistributedTarget を呼べない
    // try await executeDistributedTarget(
    //     on: actor,
    //     target: ???,  // ← これがない
    //     ...
    // )

    // ✅ よって、MethodRegistryで手動実行するしかない
    let registry = await getMethodRegistry(for: actorID)
    return try await registry.execute(envelope.target, arguments: envelope.arguments)
}
```

## 最終的な推奨

### 短期（現状維持）

**MethodRegistryを使い続ける**（現在の実装を維持）

理由：
1. `RemoteCallTarget`をシリアライズできない
2. BLEを超えてRemoteCallTargetを送信する方法がない
3. MethodRegistryは実用的な回避策

### 中期（改善）

**Swift Macroで自動登録**を実装：

```swift
@DistributedActor
@AutoRegisterMethods  // ← カスタムマクロ
distributed actor Sensor: PeripheralActor {
    distributed func readTemperature() async -> Double {
        return 22.5
    }

    // マクロが自動生成↓
    // func registerMethods(with registry: MethodRegistry) async {
    //     registry.register("$s...readTemperature...") { ... }
    // }
}
```

### 長期（理想）

**Swiftに提案**：
1. `RemoteCallTarget`を`Codable`にする
2. または、`RemoteCallTarget(identifier:)`のpublic initを追加

これにより、BLE越しに`RemoteCallTarget`を送信でき、`executeDistributedTarget`を直接呼べるようになる。

## ドキュメント更新

### BLEActorSystem.swiftのコメント修正

```swift
// ❌ 間違ったコメント
// NOTE: This requires access to Swift's internal distributed actor runtime APIs
// which are not publicly available. Will be implemented when Swift exposes these APIs.

// ✅ 正しいコメント
// NOTE: executeDistributedTarget is a compiler-synthesized function and does not
// need manual implementation. However, for cross-process (BLE) communication,
// we cannot serialize RemoteCallTarget. Therefore, we use MethodRegistry as a
// workaround to execute distributed methods by their mangled name strings.
// See handleIncomingRPC() for the actual implementation.
```

### AGENTS.mdとREAL_ISSUE_ANALYSIS.mdの更新

これらのドキュメントに以下を追加：

1. `executeDistributedTarget`はpublic APIであり、コンパイラが自動生成すること
2. BLEの制約により`RemoteCallTarget`をシリアライズできないこと
3. よって、MethodRegistryが必要な正当な理由があること
4. これはBleuの制限ではなく、Swiftの`RemoteCallTarget`の制限であること
