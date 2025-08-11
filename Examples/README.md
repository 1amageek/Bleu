# Bleu Examples

Bleu v2の使い方を学ぶためのサンプルコード集です。

## 📁 ディレクトリ構成

### BasicUsage/ - 基本的な使い方
最小限のコードでBleuの基本機能を理解できます。

- **Server.swift** - BLEサーバーの最小実装
- **Client.swift** - BLEクライアントの最小実装
- **Communication.swift** - 型安全な通信パターンの例

### SwiftUIApp/ - SwiftUIサンプルアプリ
実践的なSwiftUIアプリケーションの実装例です。

- **BleuExampleApp.swift** - アプリのエントリーポイント
- **ServerExample.swift** - サーバー機能のUI実装
- **ClientExample.swift** - クライアント機能のUI実装
- **BluetoothState.swift** - Bluetooth状態管理

### Common/ - 共通定義
例全体で使用する共通の型定義です。

- **RemoteProcedures.swift** - リモートプロシージャ定義
- **Notifications.swift** - 通知型定義

## 🚀 実行方法

### Examplesディレクトリに移動

```bash
cd Examples
```

### 基本的な使い方の例を実行

```bash
# サーバーを起動
swift run BasicServer

# 別のターミナルでクライアントを起動
swift run BasicClient
```

### SwiftUIアプリを実行

```bash
# Xcodeで開く
open Package.swift

# BleuExampleAppターゲットを選択して実行
# または
swift run BleuExampleApp
```

## 📖 学習の流れ

1. **BasicUsage/Server.swift** と **Client.swift** で基本的な通信を理解
2. **Communication.swift** で型安全な通信パターンを学習
3. **SwiftUIApp/** で実践的なアプリケーション実装を確認
4. **Common/** の定義を参考に独自のプロトコルを実装

## 💡 ポイント

### 型安全な通信
```swift
// リクエスト/レスポンスを型で定義
struct GetTemperatureRequest: RemoteProcedure {
    struct Response: Sendable, Codable {
        let temperature: Double
        let humidity: Double
    }
}
```

### 非同期処理
```swift
// async/awaitを使った直感的な実装
let response = try await client.sendRequest(request, to: deviceId)
```

### SwiftUIとの統合
```swift
// ObservableObjectでリアクティブなUI更新
@Published var isScanning = false
@Published var devices: [Device] = []
```

## 📚 詳細なドキュメント

より詳しい情報は[メインのREADME](../README.md)を参照してください。