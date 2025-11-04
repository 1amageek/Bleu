import Foundation
import Distributed
@testable import Bleu

/// Example distributed actors for testing purposes
/// These actors demonstrate various RPC patterns and can be used across test suites

// MARK: - Simple Value Actor

/// Simple actor that returns a constant value
distributed actor SimpleValueActor: PeripheralActor {
    typealias ActorSystem = BLEActorSystem

    distributed func getValue() async -> Int {
        return 42
    }
}

// MARK: - Echo Actor

/// Actor that echoes back the data it receives
distributed actor EchoActor: PeripheralActor {
    typealias ActorSystem = BLEActorSystem

    distributed func echo(_ message: String) async -> String {
        return message
    }

    distributed func echoData(_ data: Data) async -> Data {
        return data
    }
}

// MARK: - Sensor Actor

/// Simulated sensor actor for testing sensor-like peripherals
distributed actor SensorActor: PeripheralActor {
    typealias ActorSystem = BLEActorSystem

    private var temperature: Double = 22.5
    private var humidity: Double = 45.0

    distributed func readTemperature() async -> Double {
        return temperature
    }

    distributed func readHumidity() async -> Double {
        return humidity
    }

    distributed func readAll() async -> SensorReading {
        return SensorReading(temperature: temperature, humidity: humidity)
    }

    // Non-distributed method (local only)
    func updateTemperature(_ temp: Double) {
        temperature = temp
    }

    func updateHumidity(_ hum: Double) {
        humidity = hum
    }
}

struct SensorReading: Codable, Equatable {
    let temperature: Double
    let humidity: Double
}

// MARK: - Counter Actor

/// Actor with mutable state for testing state changes
distributed actor CounterActor: PeripheralActor {
    typealias ActorSystem = BLEActorSystem

    private var count: Int = 0

    distributed func increment() async -> Int {
        count += 1
        return count
    }

    distributed func decrement() async -> Int {
        count -= 1
        return count
    }

    distributed func getCount() async -> Int {
        return count
    }

    distributed func reset() async {
        count = 0
    }

    distributed func add(_ value: Int) async -> Int {
        count += value
        return count
    }
}

// MARK: - Device Control Actor

/// Actor simulating a controllable device (LED, motor, etc.)
distributed actor DeviceControlActor: PeripheralActor {
    typealias ActorSystem = BLEActorSystem

    private var isOn: Bool = false
    private var brightness: Int = 0

    distributed func turnOn() async {
        isOn = true
    }

    distributed func turnOff() async {
        isOn = false
    }

    distributed func setBrightness(_ level: Int) async {
        brightness = max(0, min(100, level))
    }

    distributed func getStatus() async -> DeviceStatus {
        return DeviceStatus(isOn: isOn, brightness: brightness)
    }
}

struct DeviceStatus: Codable, Equatable {
    let isOn: Bool
    let brightness: Int
}

// MARK: - Data Storage Actor

/// Actor that stores and retrieves data
distributed actor DataStorageActor: PeripheralActor {
    typealias ActorSystem = BLEActorSystem

    private var storage: [String: Data] = [:]

    distributed func store(key: String, value: Data) async {
        storage[key] = value
    }

    distributed func retrieve(key: String) async -> Data? {
        return storage[key]
    }

    distributed func delete(key: String) async {
        storage.removeValue(forKey: key)
    }

    distributed func keys() async -> [String] {
        return Array(storage.keys)
    }

    distributed func clear() async {
        storage.removeAll()
    }
}

// MARK: - Error-Throwing Actor

/// Actor that can throw errors for testing error handling
distributed actor ErrorThrowingActor: PeripheralActor {
    typealias ActorSystem = BLEActorSystem

    enum TestError: Error, Codable {
        case simulatedError
        case valueError(Int)
        case messageError(String)
    }

    distributed func alwaysThrows() async throws -> Int {
        throw TestError.simulatedError
    }

    distributed func throwsIf(_ condition: Bool) async throws -> String {
        if condition {
            throw TestError.messageError("Condition was true")
        }
        return "Success"
    }

    distributed func throwsForValue(_ value: Int) async throws -> Int {
        if value < 0 {
            throw TestError.valueError(value)
        }
        return value * 2
    }
}

// MARK: - Complex Response Actor

/// Actor that returns complex nested data structures
distributed actor ComplexDataActor: PeripheralActor {
    typealias ActorSystem = BLEActorSystem

    distributed func getComplexData() async -> ComplexData {
        return ComplexData(
            id: UUID(),
            values: [1, 2, 3, 4, 5],
            metadata: Metadata(
                timestamp: Date(),
                version: "1.0.0"
            ),
            nested: NestedData(
                flag: true,
                description: "Test data"
            )
        )
    }
}

struct ComplexData: Codable, Equatable {
    let id: UUID
    let values: [Int]
    let metadata: Metadata
    let nested: NestedData

    static func == (lhs: ComplexData, rhs: ComplexData) -> Bool {
        return lhs.id == rhs.id &&
               lhs.values == rhs.values &&
               lhs.nested == rhs.nested
    }
}

struct Metadata: Codable {
    let timestamp: Date
    let version: String
}

struct NestedData: Codable, Equatable {
    let flag: Bool
    let description: String
}

// MARK: - Async Stream Actor

/// Actor that demonstrates async stream patterns
distributed actor StreamingActor: PeripheralActor {
    typealias ActorSystem = BLEActorSystem

    // Note: AsyncStream cannot be directly returned from distributed methods
    // This actor demonstrates the limitation and potential workarounds

    distributed func getSequence(count: Int) async -> [Int] {
        return Array(0..<count)
    }

    distributed func generateValues(start: Int, count: Int) async -> [Int] {
        return (start..<(start + count)).map { $0 }
    }
}
