import Testing
import CoreBluetooth
@testable import Bleu

/// Test suite for Bleu v2 core functionality using Swift Testing
@Suite("Bleu v2 Core Tests")
struct BleuV2CoreTests {
    
    @Test("Version information is correct")
    func versionInfo() {
        #expect(BleuVersion.current == "2.0.0")
        #expect(BleuVersion.swiftRequirement == "6.1")
        #expect(BleuVersion.platforms == ["iOS 18.0+", "macOS 15.0+", "watchOS 11.0+", "tvOS 18.0+"])
    }
}

@Suite("Data Types Tests")
struct DataTypesTests {
    
    @Test("DeviceIdentifier initialization and properties")
    func deviceIdentifier() {
        let uuid = UUID()
        let identifier = DeviceIdentifier(uuid: uuid, name: "Test Device")
        
        #expect(identifier.uuid == uuid)
        #expect(identifier.name == "Test Device")
        
        // Test without name
        let identifierNoName = DeviceIdentifier(uuid: uuid)
        #expect(identifierNoName.uuid == uuid)
        #expect(identifierNoName.name == nil)
    }
    
    @Test("ServiceConfiguration creation")
    func serviceConfiguration() {
        let serviceUUID = UUID()
        let characteristicUUIDs = [UUID(), UUID()]
        
        let config = ServiceConfiguration(
            serviceUUID: serviceUUID,
            characteristicUUIDs: characteristicUUIDs,
            isPrimary: true
        )
        
        #expect(config.serviceUUID == serviceUUID)
        #expect(config.characteristicUUIDs == characteristicUUIDs)
        #expect(config.isPrimary == true)
        
        // Test default isPrimary
        let configDefault = ServiceConfiguration(
            serviceUUID: serviceUUID,
            characteristicUUIDs: characteristicUUIDs
        )
        #expect(configDefault.isPrimary == true)
    }
    
    @Test("BleuMessage creation and properties")
    func bleuMessage() {
        let serviceUUID = UUID()
        let characteristicUUID = UUID()
        let testData = "Hello, Bleu!".data(using: .utf8)
        
        let message = BleuMessage(
            serviceUUID: serviceUUID,
            characteristicUUID: characteristicUUID,
            data: testData,
            method: .write
        )
        
        #expect(message.serviceUUID == serviceUUID)
        #expect(message.characteristicUUID == characteristicUUID)
        #expect(message.data == testData)
        #expect(message.method == .write)
        #expect(message.id != UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
        #expect(message.timestamp <= Date())
    }
    
    @Test("RequestMethod properties mapping")
    func requestMethodProperties() {
        #expect(RequestMethod.read.properties == .read)
        #expect(RequestMethod.write.properties == .write)
        #expect(RequestMethod.writeWithoutResponse.properties == .writeWithoutResponse)
        #expect(RequestMethod.notify.properties == .notify)
        #expect(RequestMethod.indicate.properties == .indicate)
    }
    
    @Test("RequestMethod permissions mapping")
    func requestMethodPermissions() {
        #expect(RequestMethod.read.permissions == .readable)
        #expect(RequestMethod.write.permissions == .writeable)
        #expect(RequestMethod.writeWithoutResponse.permissions == .writeable)
        #expect(RequestMethod.notify.permissions == .readable)
        #expect(RequestMethod.indicate.permissions == .readable)
    }
    
    @Test("AdvertisementData initialization")
    func advertisementData() {
        let serviceUUIDs = [UUID(), UUID()]
        let manufacturerData = Data([0x01, 0x02, 0x03])
        let serviceData = [UUID(): Data([0x04, 0x05])]
        
        let adData = AdvertisementData(
            localName: "Test Device",
            serviceUUIDs: serviceUUIDs,
            manufacturerData: manufacturerData,
            serviceData: serviceData,
            txPowerLevel: -10
        )
        
        #expect(adData.localName == "Test Device")
        #expect(adData.serviceUUIDs == serviceUUIDs)
        #expect(adData.manufacturerData == manufacturerData)
        #expect(adData.serviceData == serviceData)
        #expect(adData.txPowerLevel == -10)
        
        // Test default values
        let defaultAdData = AdvertisementData()
        #expect(defaultAdData.localName == nil)
        #expect(defaultAdData.serviceUUIDs.isEmpty)
        #expect(defaultAdData.manufacturerData == nil)
        #expect(defaultAdData.serviceData.isEmpty)
        #expect(defaultAdData.txPowerLevel == nil)
    }
    
    @Test("ConnectionOptions configuration")
    func connectionOptions() {
        let options = ConnectionOptions(
            notifyOnConnection: false,
            notifyOnDisconnection: false,
            notifyOnNotification: false,
            timeout: 60.0
        )
        
        #expect(options.notifyOnConnection == false)
        #expect(options.notifyOnDisconnection == false)
        #expect(options.notifyOnNotification == false)
        #expect(options.timeout == 60.0)
        
        // Test default values
        let defaultOptions = ConnectionOptions()
        #expect(defaultOptions.notifyOnConnection == true)
        #expect(defaultOptions.notifyOnDisconnection == true)
        #expect(defaultOptions.notifyOnNotification == true)
        #expect(defaultOptions.timeout == 30.0)
    }
}

@Suite("Error Handling Tests")
struct ErrorHandlingTests {
    
    @Test("BleuError descriptions")
    func bleuErrorDescriptions() {
        #expect(BleuError.bluetoothUnavailable.localizedDescription == "Bluetooth is not available")
        #expect(BleuError.deviceNotFound.localizedDescription == "Target device not found")
        #expect(BleuError.communicationTimeout.localizedDescription == "Communication timeout")
        #expect(BleuError.serializationFailed.localizedDescription == "Failed to serialize data")
        #expect(BleuError.deserializationFailed.localizedDescription == "Failed to deserialize data")
        #expect(BleuError.authenticationFailed.localizedDescription == "Authentication failed")
        #expect(BleuError.permissionDenied.localizedDescription == "Permission denied")
        #expect(BleuError.remoteActorUnavailable.localizedDescription == "Remote actor is unavailable")
        #expect(BleuError.invalidRequest.localizedDescription == "Invalid request")
    }
    
    @Test("BleuError with parameters")
    func bleuErrorWithParameters() {
        let connectionError = BleuError.connectionFailed("Network timeout")
        #expect(connectionError.localizedDescription == "Connection failed: Network timeout")
        
        let serviceUUID = UUID()
        let serviceError = BleuError.serviceNotFound(serviceUUID)
        #expect(serviceError.localizedDescription.contains("Service not found"))
        #expect(serviceError.localizedDescription.contains(serviceUUID.uuidString))
        
        let characteristicUUID = UUID()
        let characteristicError = BleuError.characteristicNotFound(characteristicUUID)
        #expect(characteristicError.localizedDescription.contains("Characteristic not found"))
        #expect(characteristicError.localizedDescription.contains(characteristicUUID.uuidString))
    }
    
    @Test("ActorIsolationError descriptions")
    func actorIsolationErrorDescriptions() {
        #expect(ActorIsolationError.isolationViolation.localizedDescription == "Actor isolation violation detected")
        #expect(ActorIsolationError.deadlock.localizedDescription == "Potential deadlock detected")
        #expect(ActorIsolationError.stateCorruption.localizedDescription == "Actor state corruption detected")
    }
}

@Suite("Remote Procedures Tests")
struct RemoteProceduresTests {
    
    @Test("GetDeviceInfoRequest serialization", .serialized)
    func getDeviceInfoRequestSerialization() throws {
        let request = GetDeviceInfoRequest()
        
        // Verify UUIDs are set
        #expect(request.serviceUUID.uuidString == "12345678-1234-5678-9ABC-123456789ABC")
        #expect(request.characteristicUUID.uuidString == "87654321-4321-8765-CBA9-987654321CBA")
        #expect(request.method == .write)
        
        // Test JSON serialization
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        
        let requestData = try encoder.encode(request)
        let decodedRequest = try decoder.decode(GetDeviceInfoRequest.self, from: requestData)
        #expect(decodedRequest.serviceUUID == request.serviceUUID)
        #expect(decodedRequest.characteristicUUID == request.characteristicUUID)
    }
    
    @Test("GetDeviceInfoRequest.Response serialization", .serialized)
    func getDeviceInfoResponseSerialization() throws {
        let response = GetDeviceInfoRequest.Response(
            deviceName: "Test Device",
            firmwareVersion: "1.0.0",
            batteryLevel: 85
        )
        
        #expect(response.deviceName == "Test Device")
        #expect(response.firmwareVersion == "1.0.0")
        #expect(response.batteryLevel == 85)
        
        // Test JSON serialization
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        
        let responseData = try encoder.encode(response)
        let decodedResponse = try decoder.decode(GetDeviceInfoRequest.Response.self, from: responseData)
        #expect(decodedResponse.deviceName == response.deviceName)
        #expect(decodedResponse.firmwareVersion == response.firmwareVersion)
        #expect(decodedResponse.batteryLevel == response.batteryLevel)
    }
    
    @Test("SendDataRequest functionality", .serialized)
    func sendDataRequest() throws {
        let testData = "Hello World".data(using: .utf8)!
        let request = SendDataRequest(data: testData)
        
        #expect(request.data == testData)
        #expect(request.serviceUUID.uuidString == "12345678-1234-5678-9ABC-123456789ABC")
        #expect(request.characteristicUUID.uuidString == "11111111-2222-3333-4444-555555555555")
        
        // Test response
        let response = SendDataRequest.Response(success: true, message: "Data received")
        #expect(response.success == true)
        #expect(response.message == "Data received")
        
        // Test serialization
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        
        let requestData = try encoder.encode(request)
        let decodedRequest = try decoder.decode(SendDataRequest.self, from: requestData)
        #expect(decodedRequest.data == request.data)
    }
    
    @Test("SensorDataNotification functionality", .serialized)
    func sensorDataNotification() throws {
        let notification = SensorDataNotification(
            temperature: 25.5,
            humidity: 60.2
        )
        
        #expect(notification.temperature == 25.5)
        #expect(notification.humidity == 60.2)
        #expect(notification.timestamp <= Date())
        
        // Test with custom timestamp
        let customDate = Date(timeIntervalSince1970: 1000000)
        let customNotification = SensorDataNotification(
            temperature: 30.0,
            humidity: 45.0,
            timestamp: customDate
        )
        #expect(customNotification.timestamp == customDate)
        
        // Test JSON serialization with ISO8601 dates
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        
        let data = try encoder.encode(notification)
        let decoded = try decoder.decode(SensorDataNotification.self, from: data)
        
        #expect(decoded.temperature == notification.temperature)
        #expect(decoded.humidity == notification.humidity)
        // Allow small difference in timestamps due to encoding/decoding
        #expect(abs(decoded.timestamp.timeIntervalSince1970 - notification.timestamp.timeIntervalSince1970) < 1.0)
    }
}

@Suite("Actor System Tests")
struct ActorSystemTests {
    
    @Test("BLEActorSystem creation")
    func bleActorSystemCreation() {
        let actorSystem = BLEActorSystem()
        
        // Test ID assignment
        let id1 = actorSystem.assignID(PeripheralActor.self)
        let id2 = actorSystem.assignID(CentralActor.self)
        
        #expect(id1 != id2)
        #expect(id1 != UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
        #expect(id2 != UUID(uuidString: "00000000-0000-0000-0000-000000000000"))
    }
    
    @Test("RemoteCallTarget creation")
    func remoteCallTarget() {
        let serviceUUID = UUID()
        let characteristicUUID = UUID()
        let method = "testMethod"
        
        let target = RemoteCallTarget(
            serviceUUID: serviceUUID,
            characteristicUUID: characteristicUUID,
            method: method
        )
        
        #expect(target.serviceUUID == serviceUUID)
        #expect(target.characteristicUUID == characteristicUUID)
        #expect(target.method == method)
    }
}

@Suite("Integration Tests", .serialized)
struct IntegrationTests {
    
    @Test("BluetoothActor state management")
    func bluetoothActorStateManagement() async throws {
        let bluetoothActor = BluetoothActor.shared
        
        var stateUpdates: [CBManagerState] = []
        let observerId = await bluetoothActor.addStateObserver { state in
            stateUpdates.append(state)
        }
        
        // Simulate state update
        await bluetoothActor.updateBluetoothState(.poweredOff)
        await bluetoothActor.updateBluetoothState(.poweredOn)
        
        // Clean up
        await bluetoothActor.removeStateObserver(id: observerId)
        
        // Verify we received the initial state plus updates
        #expect(stateUpdates.count >= 2)
        #expect(stateUpdates.contains(.poweredOff))
        #expect(stateUpdates.contains(.poweredOn))
    }
    
    @Test("Actor system access")
    func actorSystemAccess() async {
        let bluetoothActor = BluetoothActor.shared
        let actorSystem = await bluetoothActor.actorSystem
        
        #expect(actorSystem != nil)
    }
}

@Suite("Performance Tests")
struct PerformanceTests {
    
    @Test("Serialization performance", .timeLimit(.seconds(5)))
    func serializationPerformance() throws {
        let encoder = JSONEncoder()
        let notification = SensorDataNotification(temperature: 25.0, humidity: 50.0)
        
        // Measure encoding performance
        let iterations = 1000
        let startTime = Date()
        
        for _ in 0..<iterations {
            _ = try encoder.encode(notification)
        }
        
        let duration = Date().timeIntervalSince(startTime)
        #expect(duration < 1.0) // Should complete 1000 encodings in under 1 second
    }
    
    @Test("Deserialization performance", .timeLimit(.seconds(5)))
    func deserializationPerformance() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let notification = SensorDataNotification(temperature: 25.0, humidity: 50.0)
        let data = try encoder.encode(notification)
        
        // Measure decoding performance
        let iterations = 1000
        let startTime = Date()
        
        for _ in 0..<iterations {
            _ = try decoder.decode(SensorDataNotification.self, from: data)
        }
        
        let duration = Date().timeIntervalSince(startTime)
        #expect(duration < 1.0) // Should complete 1000 decodings in under 1 second
    }
    
    @Test("UUID generation performance", .timeLimit(.seconds(2)))
    func uuidGenerationPerformance() {
        let iterations = 10000
        var uuids = Set<UUID>()
        
        let startTime = Date()
        for _ in 0..<iterations {
            uuids.insert(UUID())
        }
        let duration = Date().timeIntervalSince(startTime)
        
        #expect(uuids.count == iterations) // All UUIDs should be unique
        #expect(duration < 0.5) // Should generate 10000 UUIDs in under 0.5 seconds
    }
}