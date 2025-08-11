//
//  PeripheralActors.swift
//  Common
//
//  共通で使用するPeripheralActor定義
//  Common PeripheralActor definitions used across examples
//

import Foundation
import Distributed
import Bleu

// MARK: - Service UUIDs
// サービスUUID定義

enum BleuServiceUUIDs {
    static let deviceInfo = UUID(uuidString: "12345678-1234-5678-9ABC-123456789ABC")!
    static let sensor = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    static let control = UUID(uuidString: "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF")!
}

// MARK: - Device Information Peripheral Actor

/// デバイス情報を提供するPeripheralActor
/// PeripheralActor that provides device information
public distributed actor DeviceInfoPeripheral: PeripheralActor {
    public typealias ActorSystem = BLEActorSystem
    
    private let deviceName: String
    private let firmwareVersion: String
    private let hardwareVersion: String
    private let serialNumber: String
    
    public init(
        actorSystem: ActorSystem,
        deviceName: String = "Bleu Device",
        firmwareVersion: String = "1.0.0",
        hardwareVersion: String = "Rev A",
        serialNumber: String = UUID().uuidString
    ) {
        self.actorSystem = actorSystem
        self.deviceName = deviceName
        self.firmwareVersion = firmwareVersion
        self.hardwareVersion = hardwareVersion
        self.serialNumber = serialNumber
    }
    
    /// デバイス情報を取得
    /// Get device information
    public distributed func getDeviceInfo() async throws -> DeviceInfo {
        return DeviceInfo(
            deviceName: deviceName,
            firmwareVersion: firmwareVersion,
            hardwareVersion: hardwareVersion,
            serialNumber: serialNumber,
            timestamp: Date()
        )
    }
}

/// デバイス情報
/// Device information
public struct DeviceInfo: Codable, Sendable {
    public let deviceName: String
    public let firmwareVersion: String
    public let hardwareVersion: String
    public let serialNumber: String
    public let timestamp: Date
}

// MARK: - Sensor Peripheral Actor

/// センサーデータを提供するPeripheralActor
/// PeripheralActor that provides sensor data
public distributed actor SensorPeripheral: PeripheralActor {
    public typealias ActorSystem = BLEActorSystem
    
    private var temperature: Double = 25.0
    private var humidity: Double = 50.0
    private var pressure: Double = 1013.25
    
    public init(actorSystem: ActorSystem) {
        self.actorSystem = actorSystem
        
        // Simulate sensor data changes
        Task { [weak self] in
            while true {
                try await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
                // Update values inline to avoid calling private method
                guard let self = self else { break }
                try? await self.simulateValueChanges()
            }
        }
    }
    
    /// 温度を取得
    /// Get temperature
    public distributed func getTemperature() async throws -> TemperatureReading {
        return TemperatureReading(
            value: temperature,
            unit: .celsius,
            timestamp: Date()
        )
    }
    
    /// 湿度を取得
    /// Get humidity
    public distributed func getHumidity() async throws -> HumidityReading {
        return HumidityReading(
            value: humidity,
            timestamp: Date()
        )
    }
    
    /// 気圧を取得
    /// Get pressure
    public distributed func getPressure() async throws -> PressureReading {
        return PressureReading(
            value: pressure,
            unit: .hectopascal,
            timestamp: Date()
        )
    }
    
    /// 全センサーデータを取得
    /// Get all sensor data
    public distributed func getAllSensorData() async throws -> SensorData {
        return SensorData(
            temperature: temperature,
            humidity: humidity,
            pressure: pressure,
            timestamp: Date()
        )
    }
    
    distributed func simulateValueChanges() {
        // Simulate sensor value changes
        temperature += Double.random(in: -0.5...0.5)
        humidity += Double.random(in: -2...2)
        pressure += Double.random(in: -1...1)
        
        // Keep values in realistic ranges
        temperature = max(15, min(35, temperature))
        humidity = max(20, min(80, humidity))
        pressure = max(990, min(1030, pressure))
    }
}

/// 温度測定値
/// Temperature reading
public struct TemperatureReading: Codable, Sendable {
    public enum Unit: String, Codable, Sendable {
        case celsius
        case fahrenheit
        case kelvin
    }
    
    public let value: Double
    public let unit: Unit
    public let timestamp: Date
    
    public var fahrenheit: Double {
        switch unit {
        case .celsius:
            return value * 9/5 + 32
        case .fahrenheit:
            return value
        case .kelvin:
            return (value - 273.15) * 9/5 + 32
        }
    }
}

/// 湿度測定値
/// Humidity reading
public struct HumidityReading: Codable, Sendable {
    public let value: Double  // Percentage (0-100)
    public let timestamp: Date
}

/// 気圧測定値
/// Pressure reading
public struct PressureReading: Codable, Sendable {
    public enum Unit: String, Codable, Sendable {
        case hectopascal
        case millibar
        case inchesHg
    }
    
    public let value: Double
    public let unit: Unit
    public let timestamp: Date
}

/// 全センサーデータ
/// All sensor data
public struct SensorData: Codable, Sendable {
    public let temperature: Double  // Celsius
    public let humidity: Double     // Percentage
    public let pressure: Double     // hPa
    public let timestamp: Date
}

// MARK: - Control Peripheral Actor

/// デバイス制御を提供するPeripheralActor
/// PeripheralActor that provides device control
public distributed actor ControlPeripheral: PeripheralActor {
    public typealias ActorSystem = BLEActorSystem
    
    private var ledState: Bool = false
    private var ledColor: LEDColor = .white
    private var motorSpeed: Double = 0.0  // 0-100%
    
    public init(actorSystem: ActorSystem) {
        self.actorSystem = actorSystem
    }
    
    /// LED状態を設定
    /// Set LED state
    public distributed func setLED(on: Bool, color: LEDColor? = nil) async throws -> LEDStatus {
        ledState = on
        if let color = color {
            ledColor = color
        }
        
        return LEDStatus(
            isOn: ledState,
            color: ledColor,
            brightness: on ? 100 : 0
        )
    }
    
    /// LED状態を取得
    /// Get LED status
    public distributed func getLEDStatus() async throws -> LEDStatus {
        return LEDStatus(
            isOn: ledState,
            color: ledColor,
            brightness: ledState ? 100 : 0
        )
    }
    
    /// モーター速度を設定
    /// Set motor speed
    public distributed func setMotorSpeed(_ speed: Double) async throws -> MotorStatus {
        motorSpeed = max(0, min(100, speed))
        
        return MotorStatus(
            speed: motorSpeed,
            isRunning: motorSpeed > 0,
            direction: .forward
        )
    }
    
    /// モーター状態を取得
    /// Get motor status
    public distributed func getMotorStatus() async throws -> MotorStatus {
        return MotorStatus(
            speed: motorSpeed,
            isRunning: motorSpeed > 0,
            direction: .forward
        )
    }
}

/// LED色
/// LED color
public enum LEDColor: String, Codable, Sendable {
    case red
    case green
    case blue
    case white
    case yellow
    case purple
    case cyan
}

/// LED状態
/// LED status
public struct LEDStatus: Codable, Sendable {
    public let isOn: Bool
    public let color: LEDColor
    public let brightness: Int  // 0-100
}

/// モーター状態
/// Motor status
public struct MotorStatus: Codable, Sendable {
    public enum Direction: String, Codable, Sendable {
        case forward
        case reverse
    }
    
    public let speed: Double  // 0-100%
    public let isRunning: Bool
    public let direction: Direction
}