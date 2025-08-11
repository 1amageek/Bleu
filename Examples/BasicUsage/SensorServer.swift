import Foundation
import Bleu
import BleuCommon

/// Example BLE Sensor Server
@main
struct SensorServer {
    static func main() async throws {
        print("🌡️ Starting Temperature Sensor Server...")
        
        // Create the actor system
        let actorSystem = BLEActorSystem.shared
        
        // Create temperature sensor
        let sensor = TemperatureSensor(actorSystem: actorSystem)
        
        // Start simulation
        try await sensor.startSimulation()
        print("✅ Temperature simulation started")
        
        // Start advertising
        try await actorSystem.startAdvertising(sensor)
        print("📡 Advertising as Temperature Sensor")
        print("   Service UUID: \(UUID.serviceUUID(for: TemperatureSensor.self))")
        
        // Keep running
        print("\nPress Ctrl+C to stop the server")
        print("Server is running... Temperature readings will be available to connected clients.")
        
        // Keep the program running
        try await Task.sleep(nanoseconds: .max)
    }
}