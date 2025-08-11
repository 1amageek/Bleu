import Foundation
import Distributed

/// Protocol for all BLE peripheral actors
public protocol PeripheralActor: DistributedActor where ActorSystem == BLEActorSystem {
    /// The unique identifier of this peripheral
    nonisolated var id: UUID { get }
}

// Note: Each PeripheralActor implementation must provide its own id property.
// The BLEActorSystem will use the actor's ID which corresponds to the peripheral's UUID.

/// Protocol for sensor peripherals
public protocol SensorPeripheral: PeripheralActor {
    associatedtype MeasurementType: Codable
    
    /// Read the current measurement
    distributed func readMeasurement() async throws -> MeasurementType
}

/// Protocol for actuator peripherals
public protocol ActuatorPeripheral: PeripheralActor {
    associatedtype CommandType: Codable
    
    /// Execute a command
    distributed func execute(_ command: CommandType) async throws
}

/// Protocol for peripherals that support notifications
public protocol NotifyingPeripheral: PeripheralActor {
    associatedtype NotificationType: Codable
    
    // Note: AsyncStream cannot be used as a return type for distributed methods
    // as it doesn't conform to Codable. Use polling or callback patterns instead.
    
    /// Get the latest notification value
    distributed func getLatestNotification() async throws -> NotificationType?
    
    /// Enable notifications
    distributed func enableNotifications() async throws
    
    /// Disable notifications
    distributed func disableNotifications() async throws
}