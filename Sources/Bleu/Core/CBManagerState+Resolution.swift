import CoreBluetooth

extension CBManagerState {
    var isResolvedBluetoothState: Bool {
        switch self {
        case .poweredOn, .poweredOff, .unauthorized, .unsupported:
            return true
        case .unknown, .resetting:
            return false
        @unknown default:
            return true
        }
    }
}
