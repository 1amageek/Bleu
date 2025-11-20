import Testing
import CoreBluetooth
@testable import Bleu

/// Test suite for Bleu v2 core functionality using Swift Testing
@Suite("Bleu v2 Core Tests")
struct BleuV2CoreTests {
    
    // Note: BleuVersion is not yet implemented
    // Version tests will be added when the feature is implemented
}

@Suite("Characteristic Properties Tests")
struct CharacteristicPropertiesTests {
    
    @Test("Characteristic properties conversion")
    func characteristicProperties() {
        var props = CharacteristicProperties()
        props.insert(.read)
        props.insert(.write)
        props.insert(.notify)
        
        #expect(props.contains(.read))
        #expect(props.contains(.write))
        #expect(props.contains(.notify))
        #expect(!props.contains(.broadcast))
        
        // Test CB conversion
        let cbProps = props.cbProperties
        #expect(cbProps.contains(.read))
        #expect(cbProps.contains(.write))
        #expect(cbProps.contains(.notify))
    }
    
    @Test("Characteristic permissions")
    func characteristicPermissions() {
        var perms = CharacteristicPermissions()
        perms.insert(.readable)
        perms.insert(.writeable)
        
        #expect(perms.contains(.readable))
        #expect(perms.contains(.writeable))
        
        // Test CB conversion
        let cbPerms = perms.cbPermissions
        #expect(cbPerms.contains(.readable))
        #expect(cbPerms.contains(.writeable))
    }
}

@Suite("Service Metadata Tests")
struct ServiceMetadataTests {
    
    @Test("Service metadata creation")
    func serviceMetadata() {
        let serviceUUID = UUID()
        let charUUID1 = UUID()
        let charUUID2 = UUID()
        
        let char1 = CharacteristicMetadata(
            uuid: charUUID1,
            properties: [.read, .notify],
            permissions: [.readable]
        )
        
        let char2 = CharacteristicMetadata(
            uuid: charUUID2,
            properties: [.write],
            permissions: [.writeable]
        )
        
        let metadata = ServiceMetadata(
            uuid: serviceUUID,
            isPrimary: true,
            characteristics: [char1, char2]
        )
        
        #expect(metadata.uuid == serviceUUID)
        #expect(metadata.isPrimary == true)
        #expect(metadata.characteristics.count == 2)
        #expect(metadata.characteristics[0].uuid == charUUID1)
        #expect(metadata.characteristics[1].uuid == charUUID2)
    }
}

@Suite("Advertisement Data Tests")
struct AdvertisementDataTests {
    
    @Test("Advertisement data creation")
    func advertisementData() {
        let serviceUUID = UUID()
        let localName = "Test Device"
        let manufacturerData = Data([0x01, 0x02, 0x03])
        
        let adData = AdvertisementData(
            localName: localName,
            manufacturerData: manufacturerData,
            serviceUUIDs: [serviceUUID]
        )
        
        #expect(adData.localName == localName)
        #expect(adData.serviceUUIDs.contains(serviceUUID))
        #expect(adData.manufacturerData == manufacturerData)
    }
}

@Suite("BLE Error Tests")
struct BLEErrorTests {
    
    @Test("Error types")
    func errorTypes() {
        let error1 = BleuError.bluetoothUnavailable
        let error2 = BleuError.bluetoothPoweredOff
        let error3 = BleuError.peripheralNotFound(UUID())
        _ = BleuError.connectionTimeout

        // Just verify these compile and can be created
        // Note: BleuError doesn't conform to Equatable, so we can't compare directly
        // We'll just verify they can be created
        switch error1 {
        case .bluetoothUnavailable:
            #expect(true)
        default:
            Issue.record("Expected bluetoothUnavailable error")
        }

        switch error2 {
        case .bluetoothPoweredOff:
            #expect(true)
        default:
            Issue.record("Expected bluetoothPoweredOff error")
        }

        switch error3 {
        case .peripheralNotFound:
            #expect(true)
        default:
            Issue.record("Expected peripheralNotFound error")
        }
    }
}

// Note: Tests for unimplemented features have been removed
// These included:
// - DeviceIdentifier
// - BleuVersion
// - BleuConnectionManager
// - BleuSecurityManager
// These will be added when the corresponding features are implemented