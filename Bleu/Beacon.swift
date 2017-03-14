//
//  Beacon.swift
//  Antenna
//
//  Created by 1amageek on 2017/01/25.
//  Copyright © 2017年 Stamp inc. All rights reserved.
//

import Foundation
import CoreBluetooth

/**
 BeaconはCBPeripheralManagerを制御します。
 */

public class Beacon: NSObject, CBPeripheralManagerDelegate {
    
    weak var delegate: BleuServerDelegate?
    
    static let ReceiveWritePeripheralKey: AnyHashable = "antenna.beacon.receive.peripheral.key"
    
    static let ReceiveWriteDataKey: AnyHashable = "antenna.beacon.receive.data.key"
    
    static let ReceiveWriteCBATTRequestKey: AnyHashable = "antenna.beacon.receive.CBATTRequest.key"
    
    // MARK: - public
    
    public var localName: String?
    
    public var serviceData: Data?
    
    public var isAdvertising: Bool {
        return self.peripheralManager.isAdvertising
    }
    
    public var authorizationStatus: CBPeripheralManagerAuthorizationStatus {
        return CBPeripheralManager.authorizationStatus()
    }
    
    public var didReceiveReadBlock: ((CBPeripheralManager, CBATTRequest) -> Void)?
    
    @available(iOS 10.0, *)
    public var state: CBManagerState {
        return self.peripheralManager.state
    }
    
    public var poweredOffBlock: (() -> Void)?
    
    override init() {
        super.init()
        _ = self.peripheralManager
    }
    
    // MARK: - private
    
    private let queue: DispatchQueue = DispatchQueue(label: "antenna.beacon.queue", attributes: [], target: nil)
    
    private let restoreIdentifierKey: String = "antenna.beacon.restore.key"
    
    private var advertisementData: [String: Any]?
    
    private var startAdvertisingBlock: (([String : Any]?) -> Void)?
    
    private lazy var peripheralManager: CBPeripheralManager = {
        let options: [String: Any] = [CBPeripheralManagerOptionRestoreIdentifierKey: self.restoreIdentifierKey]
        let peripheralManager: CBPeripheralManager = CBPeripheralManager(delegate: self,
                                                                         queue: self.queue,
                                                                         options: options)
        return peripheralManager
    }()
    
    // MARK: - functions
    
    private func setup() {
        queue.async { [unowned self] in
            guard let service: CBMutableService = self.delegate?.service else {
                return
            }
            self.services = [service]
        }
    }
    
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
    
    public func startAdvertising() {        
        var advertisementData: [String: Any] = [:]
        
        // Set serviceUUIDs
        guard let serviceUUID: CBUUID = self.delegate?.serviceUUID else {
            return
        }
        advertisementData[CBAdvertisementDataServiceUUIDsKey] = [serviceUUID]
        
        // Set localName. if beacon have localName
        if let localName: String = self.localName {
            advertisementData[CBAdvertisementDataLocalNameKey] = localName
        }    
        
        // Set service data
//        if let serviceData: Data = self.serviceData {
//            advertisementData[CBAdvertisementDataServiceDataKey] = serviceData
//        }
        
        startAdvertising(advertisementData)
    }
    
    public func startAdvertising(_ advertisementData: [String : Any]?) {
        _startAdvertising(advertisementData)
    }
    
    private var canStartAdvertising: Bool = false
    
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
    
    public func stopAdvertising() {
        self.peripheralManager.stopAdvertising()
    }
    
    
    // MARK: -
    
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
        debugPrint("[Bleu Beacon] did add service service", service, error ?? "")
        self.canStartAdvertising = true
        self.startAdvertisingBlock?(self.advertisementData)
    }
    
    public func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        debugPrint("[Bleu Beacon] did start advertising", peripheral, error ?? "")
    }
    
    public func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String : Any]) {
        debugPrint("[Bleu Beacon] will restore state ", dict)
        
//        let a = dict[CBPeripheralManagerRestoredStateServicesKey]
//        let b = dict[CBPeripheralManagerRestoredStateAdvertisementDataKey]
        
    }
    
    public func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        debugPrint("[Bleu Beacon] is ready to update subscribers ", peripheral)
    }
    
    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didSubscribeTo characteristic: CBCharacteristic) {
        debugPrint("[Bleu Beacon] did subscribe to ", peripheral, central, characteristic)
    }
    
    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral, didUnsubscribeFrom characteristic: CBCharacteristic) {
        debugPrint("[Bleu Beacon] did unsubscribe from ", peripheral, central, characteristic)
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

extension NSNotification.Name {
    static let BeaconDidReceiveReadNotificationKey: NSNotification.Name = NSNotification.Name(rawValue: "antenna.beacon.receive.read.notification.key")
    static let BeaconDidReceiveWriteNotificationKey: NSNotification.Name = NSNotification.Name(rawValue: "antenna.beacon.receive.write.notification.key")
}
