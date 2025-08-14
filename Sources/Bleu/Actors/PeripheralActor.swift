import Foundation
import Distributed

/// Protocol for all BLE peripheral actors
public protocol PeripheralActor: DistributedActor where ActorSystem == BLEActorSystem {
    // DistributedActor already provides nonisolated let id: ID (which is BLEActorSystem.ActorID)
    // No need to redefine id here
}

/// Protocol for sensor peripherals
public protocol SensorPeripheral: PeripheralActor {
    associatedtype MeasurementType: Codable & Sendable
    
    /// Read the current measurement
    distributed func readMeasurement() async throws -> MeasurementType
}

/// Protocol for actuator peripherals
public protocol ActuatorPeripheral: PeripheralActor {
    associatedtype CommandType: Codable & Sendable
    
    /// Execute a command
    distributed func execute(_ command: CommandType) async throws
}

/// Protocol for peripherals that support notifications
public protocol NotifyingPeripheral: PeripheralActor {
    associatedtype NotificationType: Codable & Sendable
    
    // Note: AsyncStream cannot be used as a return type for distributed methods
    // as it doesn't conform to Codable. Use polling or callback patterns instead.
    
    /// Get the latest notification value
    distributed func getLatestNotification() async throws -> NotificationType?
    
    /// Enable notifications
    distributed func enableNotifications() async throws
    
    /// Disable notifications
    distributed func disableNotifications() async throws
}