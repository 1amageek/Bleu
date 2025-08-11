//
//  Client.swift
//  BasicUsage
//
//  最小限のBLEクライアント実装例
//  This example shows the minimal code needed to create a BLE client
//

import Foundation
import Bleu
import CoreBluetooth

// MARK: - Basic BLE Client

/// 最小限のBLEクライアント実装
/// Minimal BLE client implementation
@main
struct BasicClient {
    static func main() async throws {
        print("Starting BLE Client...")
        
        // 1. クライアントを作成
        // Create a BLE client that will look for specific service UUIDs
        let serviceUUID = UUID(uuidString: "12345678-1234-5678-9ABC-123456789ABC")!
        
        let client = try await BleuClient(
            serviceUUIDs: [serviceUUID]
        )
        
        // 2. デバイスを探す
        // Discover nearby devices (timeout after 10 seconds)
        print("Scanning for devices...")
        let devices = try await client.discover(timeout: 10.0)
        
        print("Found \(devices.count) device(s)")
        
        // 3. 最初のデバイスに接続
        // Connect to the first discovered device
        guard let device = devices.first else {
            print("No devices found")
            return
        }
        
        print("Connecting to \(device.advertisementData.localName ?? "Unknown Device")...")
        let peripheral = try await client.connect(to: device)
        
        // 4. リクエストを送信
        // Send a type-safe request to the device
        let request = GetDeviceInfoRequest()
        let response = try await client.sendRequest(request, to: device.identifier)
        
        // 5. レスポンスを表示
        // Display the response
        print("Device Info:")
        print("  Name: \(response.deviceName)")
        print("  Firmware: \(response.firmwareVersion)")
        print("  Battery: \(response.batteryLevel)%")
        
        // 6. 切断
        // Disconnect from the device
        try await client.disconnect(from: device.identifier)
        print("Disconnected")
    }
}

// MARK: - Request Definition

/// デバイス情報取得リクエスト
/// Device information request - must match the server's definition
struct GetDeviceInfoRequest: RemoteProcedure {
    let serviceUUID = UUID(uuidString: "12345678-1234-5678-9ABC-123456789ABC")!
    let characteristicUUID = UUID(uuidString: "87654321-4321-8765-CBA9-987654321CBA")!
    
    struct Response: Sendable, Codable {
        let deviceName: String
        let firmwareVersion: String
        let batteryLevel: Int
    }
}