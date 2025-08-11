import Foundation
import Bleu
import BleuCommon

/// Example BLE Sensor Client
@main
struct SensorClient {
    static func main() async throws {
        print("🔍 Starting Temperature Sensor Client...")
        
        // Create the actor system
        let actorSystem = BLEActorSystem.shared
        
        print("📡 Scanning for Temperature Sensors...")
        
        // Discover temperature sensors
        let sensors = try await actorSystem.discover(
            TemperatureSensor.self,
            timeout: 10.0
        )
        
        guard let sensor = sensors.first else {
            print("❌ No temperature sensors found")
            return
        }
        
        print("✅ Found \(sensors.count) sensor(s)")
        print("📱 Connecting to sensor: \(sensor.id)")
        
        // Connect to the sensor
        let connectedSensor = try await actorSystem.connect(
            to: sensor.id,
            as: TemperatureSensor.self
        )
        
        print("✅ Connected successfully")
        
        // Read temperature repeatedly
        for i in 1...10 {
            print("\n📊 Reading #\(i)...")
            
            do {
                let temperature = try await connectedSensor.readTemperature()
                
                print("🌡️ Temperature:")
                print("   Celsius: \(String(format: "%.1f", temperature.celsius))°C")
                print("   Fahrenheit: \(String(format: "%.1f", temperature.fahrenheit))°F")
                print("   Timestamp: \(temperature.timestamp)")
                
            } catch {
                print("❌ Failed to read temperature: \(error)")
            }
            
            // Wait before next reading
            try await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
        }
        
        // Disconnect
        print("\n👋 Disconnecting...")
        try await actorSystem.disconnect(from: sensor.id)
        print("✅ Disconnected")
    }
}