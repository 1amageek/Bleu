//
//  Communication.swift
//  BasicUsage
//
//  型安全な通信パターンの例
//  Examples of type-safe communication patterns
//

import Foundation
import Bleu
import CoreBluetooth

// MARK: - Request/Response Pattern
// リクエスト/レスポンスパターン

/// 温度取得リクエスト
/// Temperature reading request
struct GetTemperatureRequest: RemoteProcedure {
    let serviceUUID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let characteristicUUID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    
    struct Response: Sendable, Codable {
        let temperature: Double  // Celsius
        let humidity: Double     // Percentage
        let timestamp: Date
    }
}

/// LED制御リクエスト
/// LED control request
struct SetLEDRequest: RemoteProcedure {
    let serviceUUID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    let characteristicUUID = UUID(uuidString: "22222222-3333-4444-5555-666666666666")!
    
    let ledIndex: Int
    let isOn: Bool
    let brightness: UInt8  // 0-255
    
    struct Response: Sendable, Codable {
        let success: Bool
        let actualBrightness: UInt8
    }
}

// MARK: - Notification Pattern
// 通知パターン

/// センサーデータ通知
/// Sensor data notification - sent periodically from server to client
struct SensorDataNotification: Sendable, Codable {
    let temperature: Double
    let humidity: Double
    let pressure: Double
    let timestamp = Date()
}

/// バッテリーレベル通知
/// Battery level notification
struct BatteryLevelNotification: Sendable, Codable {
    let level: Int  // 0-100
    let isCharging: Bool
    let timestamp = Date()
}

// MARK: - Usage Examples
// 使用例

class CommunicationExamples {
    
    /// サーバー側の実装例
    /// Server-side implementation example
    func serverExample() async throws {
        let server = try await BleuServer(
            serviceUUID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            characteristicUUIDs: [
                UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
                UUID(uuidString: "22222222-3333-4444-5555-666666666666")!,
                UUID(uuidString: "33333333-4444-5555-6666-777777777777")!
            ],
            localName: "Sensor Device"
        )
        
        // Handle temperature requests
        await server.handleRequests(ofType: GetTemperatureRequest.self) { request in
            return GetTemperatureRequest.Response(
                temperature: 23.5,
                humidity: 45.0,
                timestamp: Date()
            )
        }
        
        // Handle LED control requests
        await server.handleRequests(ofType: SetLEDRequest.self) { request in
            print("Setting LED \(request.ledIndex) to \(request.isOn ? "ON" : "OFF")")
            return SetLEDRequest.Response(
                success: true,
                actualBrightness: request.brightness
            )
        }
        
        // Send periodic sensor notifications
        Task {
            while true {
                let notification = SensorDataNotification(
                    temperature: Double.random(in: 20.0...30.0),
                    humidity: Double.random(in: 30.0...70.0),
                    pressure: Double.random(in: 1000.0...1020.0)
                )
                
                try await server.broadcast(
                    notification,
                    characteristicUUID: UUID(uuidString: "33333333-4444-5555-6666-777777777777")!
                )
                
                try await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
            }
        }
    }
    
    /// クライアント側の実装例
    /// Client-side implementation example
    func clientExample() async throws {
        let client = try await BleuClient(
            serviceUUIDs: [UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!]
        )
        
        // Discover and connect
        let devices = try await client.discover(timeout: 10.0)
        guard let device = devices.first else { return }
        
        let peripheral = try await client.connect(to: device)
        
        // Send temperature request
        let tempRequest = GetTemperatureRequest()
        let tempResponse = try await client.sendRequest(tempRequest, to: device.identifier)
        print("Temperature: \(tempResponse.temperature)°C")
        
        // Control LED
        let ledRequest = SetLEDRequest(ledIndex: 0, isOn: true, brightness: 128)
        let ledResponse = try await client.sendRequest(ledRequest, to: device.identifier)
        print("LED control success: \(ledResponse.success)")
        
        // Subscribe to sensor notifications
        let sensorStream = try await client.subscribe(
            to: SensorDataNotification.self,
            from: device.identifier,
            characteristicUUID: UUID(uuidString: "33333333-4444-5555-6666-777777777777")!
        )
        
        // Process notifications
        for await notification in sensorStream {
            print("Sensor update:")
            print("  Temperature: \(notification.temperature)°C")
            print("  Humidity: \(notification.humidity)%")
            print("  Pressure: \(notification.pressure) hPa")
        }
    }
}