import Foundation
@preconcurrency import CoreBluetooth

/// Delegate proxy for CBCentralManager to forward callbacks to LocalCentralActor
final class CentralManagerDelegateProxy: NSObject, CBCentralManagerDelegate, @unchecked Sendable {
    weak var actor: LocalCentralActor?
    
    init(actor: LocalCentralActor) {
        self.actor = actor
        super.init()
    }
    
    // MARK: - CBCentralManagerDelegate
    
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { [weak actor] in
            await actor?.handleStateUpdate(central.state)
        }
    }
    
    public func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        // Convert advertisement data to Sendable type
        let rssiInt = RSSI.intValue
        let adData = AdvertisementData(from: advertisementData)
        let peripheralID = peripheral.identifier
        let peripheralName = peripheral.name
        
        Task { [weak actor] in
            // Create a new discovered peripheral struct to avoid capturing non-Sendable peripheral
            let discovered = DiscoveredPeripheral(
                id: peripheralID,
                name: peripheralName,
                rssi: rssiInt,
                advertisementData: adData
            )
            
            // Store the peripheral separately (needs to be refactored)
            await actor?.handlePeripheralDiscovery(discovered, peripheral: peripheral)
        }
    }
    
    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { [weak actor] in
            await actor?.handleConnection(peripheral)
        }
    }
    
    public func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { [weak actor] in
            await actor?.handleConnectionFailure(peripheral, error: error)
        }
    }
    
    public func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        Task { [weak actor] in
            await actor?.handleDisconnection(peripheral, error: error)
        }
    }
}