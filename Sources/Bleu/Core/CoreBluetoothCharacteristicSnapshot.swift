import CoreBluetooth

struct CoreBluetoothCharacteristicSnapshot: Sendable {
    let uuid: String
    let properties: UInt

    init(from characteristic: CBCharacteristic) {
        self.uuid = characteristic.uuid.uuidString
        self.properties = characteristic.properties.rawValue
    }
}
