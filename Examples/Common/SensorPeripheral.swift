import Foundation
import Distributed
import Bleu

/// Temperature sensor peripheral actor
distributed public actor TemperatureSensor: PeripheralActor {
    public typealias ActorSystem = BLEActorSystem
    
    /// Sensor reading data
    public struct Temperature: Codable, Sendable {
        public let celsius: Double
        public let fahrenheit: Double
        public let timestamp: Date
        
        public init(celsius: Double) {
            self.celsius = celsius
            self.fahrenheit = celsius * 9.0 / 5.0 + 32.0
            self.timestamp = Date()
        }
    }
    
    /// Current temperature value
    private var currentTemperature: Temperature = Temperature(celsius: 20.0)
    
    /// Simulation timer for generating readings
    private var simulationTask: Task<Void, Never>?
    
    public distributed func readTemperature() async throws -> Temperature {
        return currentTemperature
    }
    
    public distributed func startSimulation() async throws {
        // Cancel existing simulation if any
        simulationTask?.cancel()
        
        // Start new simulation
        simulationTask = Task {
            while !Task.isCancelled {
                // Simulate temperature variations
                let variation = Double.random(in: -0.5...0.5)
                let newCelsius = max(15.0, min(35.0, currentTemperature.celsius + variation))
                currentTemperature = Temperature(celsius: newCelsius)
                
                // Wait before next update
                try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
            }
        }
    }
    
    public distributed func stopSimulation() async throws {
        simulationTask?.cancel()
        simulationTask = nil
    }
}

/// Humidity sensor peripheral actor
distributed public actor HumiditySensor: PeripheralActor {
    public typealias ActorSystem = BLEActorSystem
    
    /// Sensor reading data
    public struct Humidity: Codable, Sendable {
        public let percentage: Double
        public let timestamp: Date
        
        public init(percentage: Double) {
            self.percentage = max(0, min(100, percentage))
            self.timestamp = Date()
        }
    }
    
    /// Current humidity value
    private var currentHumidity: Humidity = Humidity(percentage: 50.0)
    
    /// Simulation timer
    private var simulationTask: Task<Void, Never>?
    
    public distributed func readHumidity() async throws -> Humidity {
        return currentHumidity
    }
    
    public distributed func startSimulation() async throws {
        simulationTask?.cancel()
        
        simulationTask = Task {
            while !Task.isCancelled {
                // Simulate humidity variations
                let variation = Double.random(in: -2.0...2.0)
                let newPercentage = currentHumidity.percentage + variation
                currentHumidity = Humidity(percentage: newPercentage)
                
                try? await Task.sleep(nanoseconds: 3_000_000_000) // 3 seconds
            }
        }
    }
    
    public distributed func stopSimulation() async throws {
        simulationTask?.cancel()
        simulationTask = nil
    }
}

/// Combined environment sensor
distributed public actor EnvironmentSensor: PeripheralActor {
    public typealias ActorSystem = BLEActorSystem
    
    public struct Environment: Codable, Sendable {
        public let temperature: TemperatureSensor.Temperature
        public let humidity: HumiditySensor.Humidity
        public let airQualityIndex: Int
        
        public init(temperature: TemperatureSensor.Temperature, 
                   humidity: HumiditySensor.Humidity,
                   airQualityIndex: Int) {
            self.temperature = temperature
            self.humidity = humidity
            self.airQualityIndex = max(0, min(500, airQualityIndex))
        }
    }
    
    private var temperatureSensor = TemperatureSensor(actorSystem: .shared)
    private var humiditySensor = HumiditySensor(actorSystem: .shared)
    private var airQualityIndex: Int = 50
    
    public distributed func readEnvironment() async throws -> Environment {
        let temp = try await temperatureSensor.readTemperature()
        let humidity = try await humiditySensor.readHumidity()
        
        return Environment(
            temperature: temp,
            humidity: humidity,
            airQualityIndex: airQualityIndex
        )
    }
    
    public distributed func startMonitoring() async throws {
        try await temperatureSensor.startSimulation()
        try await humiditySensor.startSimulation()
        
        // Simulate AQI changes
        Task {
            while !Task.isCancelled {
                airQualityIndex = Int.random(in: 20...150)
                try? await Task.sleep(nanoseconds: 5_000_000_000) // 5 seconds
            }
        }
    }
    
    public distributed func stopMonitoring() async throws {
        try await temperatureSensor.stopSimulation()
        try await humiditySensor.stopSimulation()
    }
}