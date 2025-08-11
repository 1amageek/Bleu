//
//  Notifications.swift
//  Common
//
//  共通で使用する通知型定義
//  Common notification type definitions used across examples
//

import Foundation
import Bleu

// MARK: - Sensor Notifications
// センサー通知

/// センサーデータ通知
/// Periodic sensor data notification
struct SensorDataNotification: Sendable, Codable {
    let temperature: Double  // Celsius
    let humidity: Double     // Percentage
    let pressure: Double     // hPa
    let lightLevel: Double   // Lux
    let timestamp = Date()
}

/// 加速度センサー通知
/// Accelerometer data notification
struct AccelerometerNotification: Sendable, Codable {
    let x: Double
    let y: Double
    let z: Double
    let timestamp = Date()
}

/// ジャイロスコープ通知
/// Gyroscope data notification
struct GyroscopeNotification: Sendable, Codable {
    let pitch: Double  // Degrees
    let roll: Double   // Degrees
    let yaw: Double    // Degrees
    let timestamp = Date()
}

// MARK: - System Notifications
// システム通知

/// バッテリーレベル通知
/// Battery level notification
struct BatteryLevelNotification: Sendable, Codable {
    let level: Int  // 0-100
    let voltage: Double  // Volts
    let isCharging: Bool
    let estimatedTimeRemaining: TimeInterval?  // Seconds
    let timestamp = Date()
}

/// デバイス状態通知
/// Device status notification
struct DeviceStatusNotification: Sendable, Codable {
    enum Status: String, Codable {
        case idle
        case active
        case sleeping
        case error
    }
    
    let status: Status
    let errorMessage: String?
    let uptime: TimeInterval  // Seconds since boot
    let timestamp = Date()
}

/// メモリ使用状況通知
/// Memory usage notification
struct MemoryUsageNotification: Sendable, Codable {
    let usedMemory: Int      // Bytes
    let totalMemory: Int     // Bytes
    let availableMemory: Int // Bytes
    let timestamp = Date()
    
    var usagePercentage: Double {
        Double(usedMemory) / Double(totalMemory) * 100
    }
}

// MARK: - Alert Notifications
// アラート通知

/// 閾値超過アラート
/// Threshold exceeded alert
struct ThresholdAlertNotification: Sendable, Codable {
    enum AlertType: String, Codable {
        case temperature
        case humidity
        case pressure
        case battery
        case memory
    }
    
    enum Severity: String, Codable {
        case info
        case warning
        case critical
    }
    
    let type: AlertType
    let severity: Severity
    let currentValue: Double
    let threshold: Double
    let message: String
    let timestamp = Date()
}

/// エラー通知
/// Error notification
struct ErrorNotification: Sendable, Codable {
    enum ErrorCode: Int, Codable {
        case sensorFailure = 1001
        case communicationError = 1002
        case hardwareFailure = 1003
        case softwareError = 1004
        case unknown = 9999
    }
    
    let code: ErrorCode
    let message: String
    let details: String?
    let recoveryAction: String?
    let timestamp = Date()
}

// MARK: - Data Transfer Notifications
// データ転送通知

/// ファイル転送進捗通知
/// File transfer progress notification
struct FileTransferProgressNotification: Sendable, Codable {
    let fileId: UUID
    let fileName: String
    let bytesTransferred: Int
    let totalBytes: Int
    let transferRate: Double  // Bytes per second
    let estimatedTimeRemaining: TimeInterval
    let timestamp = Date()
    
    var progressPercentage: Double {
        Double(bytesTransferred) / Double(totalBytes) * 100
    }
}

/// データ同期状態通知
/// Data sync status notification
struct DataSyncNotification: Sendable, Codable {
    enum SyncState: String, Codable {
        case idle
        case syncing
        case completed
        case failed
    }
    
    let state: SyncState
    let itemsSynced: Int
    let totalItems: Int
    let lastSyncTime: Date?
    let timestamp = Date()
}