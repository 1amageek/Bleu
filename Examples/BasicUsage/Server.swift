//
//  Server.swift
//  BasicUsage
//
//  最小限のBLEサーバー実装例
//  This example shows the minimal code needed to create a BLE server
//

import Foundation
import Bleu
import CoreBluetooth

// MARK: - Basic BLE Server

/// 最小限のBLEサーバー実装
/// Minimal BLE server implementation
@main
struct BasicServer {
    static func main() async throws {
        print("Starting BLE Server...")
        
        // 1. サーバーを作成
        // Create a BLE server with service and characteristic UUIDs
        let serviceUUID = UUID(uuidString: "12345678-1234-5678-9ABC-123456789ABC")!
        let characteristicUUID = UUID(uuidString: "87654321-4321-8765-CBA9-987654321CBA")!
        
        let server = try await BleuServer(
            serviceUUID: serviceUUID,
            characteristicUUIDs: [characteristicUUID],
            localName: "Bleu Basic Server"
        )
        
        print("Server started. Waiting for requests...")
        
        // 2. リクエストを処理
        // Handle incoming requests with type safety
        await server.handleRequests(ofType: GetDeviceInfoRequest.self) { request in
            print("Received device info request")
            
            // Return response
            return GetDeviceInfoRequest.Response(
                deviceName: "My Device",
                firmwareVersion: "1.0.0",
                batteryLevel: 85
            )
        }
        
        // Keep server running
        try await Task.sleep(nanoseconds: .max)
    }
}

// MARK: - Request Definition

/// デバイス情報取得リクエスト
/// Device information request - defines the communication protocol
struct GetDeviceInfoRequest: RemoteProcedure {
    let serviceUUID = UUID(uuidString: "12345678-1234-5678-9ABC-123456789ABC")!
    let characteristicUUID = UUID(uuidString: "87654321-4321-8765-CBA9-987654321CBA")!
    
    struct Response: Sendable, Codable {
        let deviceName: String
        let firmwareVersion: String
        let batteryLevel: Int
    }
}