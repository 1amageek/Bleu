//
//  Beacon.swift
//  Bleu
//
//  Created by 1amageek on 2017/01/25.
//  Copyright © 2017年 Stamp inc. All rights reserved.
//

import Foundation
import CoreBluetooth

/**
 Beacons control the CBPeripheralManager.
 */
public class Beacon: NSObject, CBPeripheralManagerDelegate {

    weak var delegate: BleuServerDelegate?

    /// Receive write peripheral key
    static let ReceiveWritePeripheralKey: AnyHashable = "bleu.beacon.receive.peripheral.key"

    /// Receive write data key
    static let ReceiveWriteDataKey: AnyHashable = "bleu.beacon.receive.data.key"

    /// Receive write CBATTRequest key
    static let ReceiveWriteCBATTRequestKey: AnyHashable = "bleu.beacon.receive.CBATTRequest.key"

    /// localName for Advertising
    public var localName: String?

    /// serviceData for Advertising
    public var serviceData: Data?

    /// Whether or not the peripheral is currently advertising data.
    public var isAdvertising: Bool {
        return self.peripheralManager.isAdvertising
    }

    /// This method does not prompt the user for access. You can use it to detect restricted access and simply hide UI instead of prompting for access.
    public var authorizationStatus: CBPeripheralManagerAuthorizationStatus {
        return CBPeripheralManager.authorizationStatus()
    }

    /// Represents the current state of a CBManager.
    public var state: CBManagerState {
        return self.peripheralManager.state
    }

    /// Qeueu
    private let queue: DispatchQueue = DispatchQueue(label: "bleu.beacon.queue", attributes: [], target: nil)

    /// Resotre Identifier key
    private let restoreIdentifierKey: String = "bleu.beacon.restore.key"

    /// Data Advertised by Beacon
    private var advertisementData: [String: Any]?

    /// Callback called when Beacon gets advertisable
    private var startAdvertisingBlock: (([String : Any]?) -> Void)?

    /// CBPeripheralManager
    private lazy var peripheralManager: CBPeripheralManager = {
        let options: [String: Any] = [
            // Set IdentifierKey to be stored in the OS
            CBPeripheralManagerOptionRestoreIdentifierKey: self.restoreIdentifierKey,
            // Alert when Bluetooth goes off
            CBPeripheralManagerOptionShowPowerAlertKey: true]
        let peripheralManager: CBPeripheralManager = CBPeripheralManager(delegate: self,
                                                                         queue: self.queue,
                                                                         options: options)
        return peripheralManager
    }()

    override init() {
        super.init()
        // Bluetooth is slow to start up
        _ = self.peripheralManager
    }

    // MARK: - functions

    /// Set service
    private func setup() {
        queue.async { [unowned self] in
            guard let services: [CBMutableService] = self.delegate?.services else {
                return
            }
            self.services = services
        }
    }

    /// Services managed by Beacon
    private var services: [CBMutableService]? {
        didSet {
            self.peripheralManager.removeAllServices()
            guard let services: [CBMutableService] = services else {
                return
            }
            for service: CBMutableService in services {
                self.peripheralManager.add(service)
            }
        }
    }

    /// Start advertising
    public func startAdvertising() {
        self.setup()
        var advertisementData: [String: Any] = [:]

        // Set serviceUUIDs
        guard let serviceUUIDs: [CBUUID] = self.delegate?.receivers.map({ return $0.serviceUUID }) else {
            return
        }
        advertisementData[CBAdvertisementDataServiceUUIDsKey] = serviceUUIDs

        // Set localName. if beacon have localName
        if let localName: String = self.localName {
            advertisementData[CBAdvertisementDataLocalNameKey] = localName
        }    
        
        // Set service data
        if let serviceData: Data = self.serviceData {
            advertisementData[CBAdvertisementDataServiceDataKey] = serviceData
        }

        startAdvertising(advertisementData)
    }

    /**
     Start advertising
     
     - parameter advertisementData: Data to be advertised
    */
    public func startAdvertising(_ advertisementData: [String : Any]?) {
        _startAdvertising(advertisementData)
    }

    /// Return whether advertising is possible or not
    private var canStartAdvertising: Bool = false

    /**
     Start advertising

     - parameter advertisementData: Data to be advertised
     */
    private func _startAdvertising(_ advertisementData: [String : Any]?) {
        queue.async { [unowned self] in
            self.advertisementData = advertisementData
            self.startAdvertisingBlock = { [unowned self] (advertisementData) in
                if !self.isAdvertising {
                    self.peripheralManager.startAdvertising(advertisementData)
                    debugPrint("[Bleu Beacon] Start advertising", advertisementData ?? [:])
                } else {
                    debugPrint("[Bleu Beacon] Beacon has already advertising.")
                }
            }
            if self.canStartAdvertising {
                self.startAdvertisingBlock!(advertisementData)
            }
        }
    }

    /// Stop advertising
    public func stopAdvertising() {
        self.peripheralManager.stopAdvertising()
    }

    /**
     Update the value of characteristic.

     - parameter value: Set the data to be updated.
     - parameter characteristic: Set the target characteristic.
     - parameter centrals: Set the target centrals.
     - returns: `true` if the update could be sent, or `false` if the underlying transmit queue is full. If `false` was returned,
     the delegate method peripheralManagerIsReadyToUpdateSubscribers: will be called once space has become available,
     and the update should be re-sent if so desired.
     */
    public func updateValue(_ value: Data, for characteristic: CBMutableCharacteristic, onSubscribedCentrals centrals: [CBCentral]?) -> Bool {
        return self.peripheralManager.updateValue(value, for: characteristic, onSubscribedCentrals: centrals)
    }

    // MARK: - CBPeripheralManagerDelegate

    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            debugPrint("[Bleu Beacon] did update status POWERD ON")
            setup()
        case .poweredOff:
            debugPrint("[Bleu Beacon] did update status POWERD OFF")
        case .resetting:
            debugPrint("[Bleu Beacon] did update status RESETTING")
        case .unauthorized:
            debugPrint("[Bleu Beacon] did update status UNAUTHORIZED")
        case .unknown:
            debugPrint("[Bleu Beacon] did update status UNKNOWN")
        case .unsupported:
            debugPrint("[Bleu Beacon] did update status UNSUPPORTED")
        }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService, error: Error?) {
        if let error: Error = error {
            debugPrint("[Bleu Beacon] did add service error", error)
            return
        }
        debugPrint("[Bleu Beacon] did add service service", service)
        self.canStartAdvertising = true
        self.startAdvertisingBlock?(self.advertisementData)
    }

    public func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        if let error: Error = error {
            debugPrint("[Bleu Beacon] did start advertising", error)
            return
        }
        debugPrint("[Bleu Beacon] did start advertising", peripheral, peripheral)
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String : Any]) {
        debugPrint("[Bleu Beacon] will restore state ", dict)
    }

    public func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        debugPrint("[Bleu Beacon] is ready to update subscribers ", peripheral)
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        debugPrint("[Bleu Beacon] did subscribe to ", peripheral, central, characteristic)
        self.delegate?.subscribe(peripheralManager: peripheral, central: central, characteristic: characteristic)
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        debugPrint("[Bleu Beacon] did unsubscribe from ", peripheral, central, characteristic)
        self.delegate?.unsubscribe(peripheralManager: peripheral, central: central, characteristic: characteristic)
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        debugPrint("[Bleu Beacon] did receive read ", peripheral, request)
        self.delegate?.get(peripheralManager: peripheral, request: request)
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        debugPrint("[Bleu Beacon] did receive write", peripheral, requests)
        self.delegate?.post(peripheralManager: peripheral, requests: requests)
    }
}
