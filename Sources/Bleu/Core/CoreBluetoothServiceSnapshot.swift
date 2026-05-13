import CoreBluetooth

struct CoreBluetoothServiceSnapshot: Sendable {
    let uuid: String
    let isPrimary: Bool

    init(from service: CBService) {
        self.uuid = service.uuid.uuidString
        self.isPrimary = service.isPrimary
    }
}
