//
//  Antenna.swift
//  Antenna
//
//  Created by 1amageek on 2016/01/01.
//  Copyright © 2016年 Stamp inc. All rights reserved.
//

import Foundation
import UIKit
import CoreBluetooth

/**
 AntennaはCBCentralManagerを制御します。
 */

public class Antenna: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    
    weak var delegate: BleuClientDelegate?
    
    private let restoreIdentifierKey = "antenna.antenna.restore.key"
    
    private lazy var centralManager: CBCentralManager = {
        let options: [String: Any] = [CBCentralManagerOptionRestoreIdentifierKey: self.restoreIdentifierKey]
        let manager: CBCentralManager = CBCentralManager(delegate: self, queue: self.queue, options: options)
        return manager
    }()
    
    /// Queue
    private let queue: DispatchQueue = DispatchQueue(label: "antenna.antenna.queue")
    
    /// Discoverd peripherals
    private(set) var discoveredPeripherals: Set<CBPeripheral> = []
    
    /// Connected peripherals
    private(set) var connectedPeripherals: Set<CBPeripheral> = []
    
    var status: CBManagerState {
        return self.centralManager.state
    }
    
    private var thresholdRSSI: NSNumber?
    
    private var allowDuplicates: Bool = false
    
    private var scanOptions: [String: Any]?
    
    private var startScanBlock: (([String : Any]?) -> Void)?
    
    private var timeoutWorkItem: DispatchWorkItem?
    
    // MARK: -
    
    func applicationDidEnterBackground() {
        stopScan(cleaned: false)
    }
    
    func applicationWillResignActive() {
        // TODO:
    }
    
    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidEnterBackground), name: NSNotification.Name.UIApplicationDidEnterBackground, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applicationWillResignActive), name: NSNotification.Name.UIApplicationDidBecomeActive, object: nil)
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK - method
    
    /**
     Scan
     */
    
    /// Antenna is scanning
    var isScanning: Bool {
        return self.centralManager.isScanning
    }
    
    /// Start scan

    func startScan(thresholdRSSI: NSNumber? = nil, allowDuplicates: Bool = false, options: [String: Any]? = nil) {
        self.thresholdRSSI = thresholdRSSI
        self.allowDuplicates = allowDuplicates
        
        guard let serviceUUID: CBUUID = self.delegate?.serviceUUID else {
            return
        }
        
        if let options: [String: Any] = options {
            self.scanOptions = options
        } else {
            let options: [String: Any] = [
                // 連続的にスキャンする
                CBCentralManagerScanOptionAllowDuplicatesKey: allowDuplicates,
                // サービスを指定する
                CBCentralManagerScanOptionSolicitedServiceUUIDsKey: [serviceUUID],
                
            ]
            self.scanOptions = options
        }
        
        if status == .poweredOn {
            if !isScanning {
                self.centralManager.scanForPeripherals(withServices: [serviceUUID], options: self.scanOptions)
                debugPrint("[Bleu Antenna] start scan.")
            }
        } else {
            self.startScanBlock = { [unowned self] (options) in
                if !self.isScanning {
                    self.centralManager.scanForPeripherals(withServices: [serviceUUID], options: self.scanOptions)
                    debugPrint("[Bleu Antenna] start scan.")
                }
            }
        }
        
        let workItem: DispatchWorkItem = DispatchWorkItem {
            if self.centralManager.isScanning {
                self.stopScan(cleaned: false)
            }
            self.timeoutWorkItem = nil
        }
        
        self.timeoutWorkItem = workItem
        
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(20), execute: workItem)
        
    }

    
    /// Clear and scan
    func reScan() {
        self.stopScan(cleaned: true)
        self.startScan(thresholdRSSI: self.thresholdRSSI, allowDuplicates: self.allowDuplicates, options: self.scanOptions)
    }
    
    /// Stop scan
    func stopScan(cleaned: Bool) {
        self.timeoutWorkItem?.cancel()
        self.centralManager.stopScan()
        debugPrint("[Bleu Antenna] Stop scan.")
        if cleaned {
            cleanup()
        }
    }
    
    /// cleanup
    func cleanup() {
        self.discoveredPeripherals = []
        self.connectedPeripherals = []
        self.thresholdRSSI = nil
        self.scanOptions = nil
    }
    
    // MARK: - CBCentralManagerDelegate
    
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: self.startScanBlock?(self.scanOptions)
        case .unauthorized: break
        default:
            break
        }
    }
    
    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        self.discoveredPeripherals.insert(peripheral)
        if let thresholdRSSI: NSNumber = self.thresholdRSSI {
            if thresholdRSSI.intValue < RSSI.intValue {
                self.centralManager.connect(peripheral, options: nil)
                stopScan(cleaned: false)
            }
        } else {
            self.centralManager.connect(peripheral, options: nil)
        }
        debugPrint("[Bleu Antenna] discover peripheral. ", peripheral, RSSI)        
    }
    
    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard let serviceUUID: CBUUID = self.delegate?.serviceUUID else {
            return
        }
        peripheral.delegate = self
        peripheral.discoverServices([serviceUUID])
        self.connectedPeripherals.insert(peripheral)
        debugPrint("[Bleu Antenna] donnect peripheral. ", peripheral)
    }
    
    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        debugPrint("[Bleu Antenna] fail to connect peripheral. ", peripheral, error ?? "")
        self.connectedPeripherals.remove(peripheral)
    }
    
    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        debugPrint("[Bleu Antenna] did disconnect peripheral. ", peripheral, error ?? "")
        self.connectedPeripherals.remove(peripheral)
    }
    
    public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        //let peripherals: [CBPeripheral] = dict[CBAdvertisementDataLocalNameKey]
    }
    
    // MARK: -
    // MARK: Serivce
    
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        debugPrint("[Bleu Antenna] did discover service. peripheral", peripheral, error ?? "")
        guard let services: [CBService] = peripheral.services else {
            return
        }
        debugPrint("[Bleu Antenna] did discover service. services", services)
        guard let characteristicUUIDs: [CBUUID] = self.delegate?.characteristicUUIDs else {
            return
        }
        for service in services {
            peripheral.discoverCharacteristics(characteristicUUIDs, for: service)
        }
    }
    
    public func peripheralDidUpdateName(_ peripheral: CBPeripheral) {
        debugPrint("[Bleu Antenna] update name ", peripheral)
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        debugPrint("[Bleu Antenna] didModifyServices ", peripheral, invalidatedServices)
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverIncludedServicesFor service: CBService, error: Error?) {
        debugPrint("[Bleu Antenna] did discover included services for ", peripheral, service)
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        debugPrint("[Bleu Antenna] did read RSSI ", RSSI)
    }
    
    // MARK: Characteristic
    
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        debugPrint("[Bleu Antenna] did discover characteristics for service. ", peripheral, error ?? "")
        for characteristic in service.characteristics! {
            
            guard let characteristicUUIDs: [CBUUID] = self.delegate?.characteristicUUIDs else {
                return
            }
            
            if characteristicUUIDs.contains(characteristic.uuid) {
                let properties: CBCharacteristicProperties = characteristic.properties
                if properties.contains(.notify) {
                    debugPrint("[Bleu Antenna] characteristic properties notify")
                    self.delegate?.notify(peripheral: peripheral, characteristic: characteristic)
                }
                if properties.contains(.read) {
                    debugPrint("[Bleu Antenna] characteristic properties read")
                    self.delegate?.get(peripheral: peripheral, characteristic: characteristic)
                }
                if properties.contains(.write) {
                    debugPrint("[Bleu Antenna] characteristic properties write")
                    self.delegate?.post(peripheral: peripheral, characteristic: characteristic)
                }
            }
        }
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        debugPrint("[Bleu Antenna] did update value for characteristic", peripheral, characteristic)
        self.delegate?.receiveResponse(peripheral: peripheral, characteristic: characteristic, error: error)
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        debugPrint("[Bleu Antenna] did write value for characteristic", peripheral, characteristic)
        self.delegate?.receiveResponse(peripheral: peripheral, characteristic: characteristic, error: error)
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        debugPrint("[Bleu Antenna] did update notification state for characteristic", peripheral, characteristic)
        self.delegate?.receiveResponse(peripheral: peripheral, characteristic: characteristic, error: error)
    }
    
    // MARK: Descriptor
    
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic, error: Error?) {
        debugPrint("[Bleu Antenna] did discover descriptors for ", peripheral, characteristic)
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor descriptor: CBDescriptor, error: Error?) {
        debugPrint("[Bleu Antenna] did update value for descriptor", peripheral, descriptor)
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor descriptor: CBDescriptor, error: Error?) {
        debugPrint("[Bleu Antenna] did write value for descriptor", peripheral, descriptor)
    }

    
    // MARK: -
    
    internal func _debug() {
        debugPrint("discoveredPeripherals", self.discoveredPeripherals)
        debugPrint("connectedPeripherals ", self.connectedPeripherals)
    }
    
}
