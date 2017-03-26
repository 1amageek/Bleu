//
//  Radar.swift
//  Bleu
//
//  Created by 1amageek on 2017/03/25.
//  Copyright © 2017年 Stamp inc. All rights reserved.
//

import Foundation
import UIKit
import CoreBluetooth

public class Radar: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    
    public enum RadarError: Error {
        case timeout
        case invalidRequest
    }
    
    /// Radar options
    public struct Options {
        public var showPowerAlertKey: Bool = false
        public var restoreIdentifierKey: String = Radar.restoreIdentifierKey
        public var allowDuplicatesKey: Bool = false
        public var thresholdRSSI: Int = -30         // This value is the distance between the devices is about 20 cm.
        public var timeout: Int = 10                // This value is the time to stop scanning Default 10s
        
        init(showPowerAlertKey: Bool = false,
             restoreIdentifierKey: String = Radar.restoreIdentifierKey,
             allowDuplicatesKey: Bool = false,
             thresholdRSSI: Int = -30,
             timeout: Int = 10) {
            self.showPowerAlertKey = showPowerAlertKey
            self.restoreIdentifierKey = restoreIdentifierKey
            self.allowDuplicatesKey = allowDuplicatesKey
            self.thresholdRSSI = thresholdRSSI
            self.timeout = timeout
        }
    }
    
    private static let restoreIdentifierKey = "bleu.radar.restore.key"
    
    private(set) lazy var centralManager: CBCentralManager = {
        let manager: CBCentralManager = CBCentralManager(delegate: self, queue: self.queue, options: nil)
        manager.delegate = self
        return manager
    }()
    
    /// Queue
    private let queue: DispatchQueue = DispatchQueue(label: "bleu.radar.queue")
    
    /// Discoverd peripherals
    private(set) var discoveredPeripherals: Set<CBPeripheral> = []
    
    /// Connected peripherals
    private(set) var connectedPeripherals: Set<CBPeripheral> = []
    
    public var serviceUUIDs: [CBUUID] {
        return self.requests.map({ return $0.serviceUUID })
    }
    
    public var characteristics: [CBCharacteristic] {
        return self.requests.map({ return $0.characteristic })
    }
    
    public var isNotifying: Bool {
        var isNotifying: Bool = false
        self.characteristics.forEach { (characteristic) in
            if characteristic.isNotifying {
                isNotifying = true
            }
        }
        return isNotifying
    }
    
    public var status: CBManagerState {
        return self.centralManager.state
    }
    
    public var thresholdRSSI: Int {
        return self.radarOptions.thresholdRSSI
    }
    
    public var allowDuplicates: Bool {
        return self.radarOptions.allowDuplicatesKey
    }
    
    public var timeout: Int {
        return self.radarOptions.timeout
    }

    public var completionHandler: (([CBPeripheral: Set<Request>], Error?) -> Void)?
    
    private var radarOptions: Options!
    
    private var scanOptions: [String: Any] = [:]
    
    private var startScanBlock: (([String : Any]?) -> Void)?
    
    private var requests: [Request] = []
    
    private var completedRequests: [CBPeripheral: Set<Request>] = [:]
    
    // MARK: -

    public init(requests: [Request], options: Options) {
        super.init()

        var scanOptions: [String: Any] = [:]
        let serviceUUIDs: [CBUUID] = requests.map({ return $0.serviceUUID })
        scanOptions[CBCentralManagerScanOptionSolicitedServiceUUIDsKey] = serviceUUIDs
        scanOptions[CBCentralManagerScanOptionAllowDuplicatesKey] = options.allowDuplicatesKey
        scanOptions[CBCentralManagerOptionRestoreIdentifierKey] = options.restoreIdentifierKey
        scanOptions[CBCentralManagerOptionShowPowerAlertKey] = options.showPowerAlertKey
        
        self.scanOptions = scanOptions
        self.radarOptions = options
        self.requests = requests
        
        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidEnterBackground), name: NSNotification.Name.UIApplicationDidEnterBackground, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applicationWillResignActive), name: NSNotification.Name.UIApplicationDidBecomeActive, object: nil)
    }
    
    deinit {
        debugPrint("[Bleu Radar] deinit.")
        NotificationCenter.default.removeObserver(self)
    }
    
    @objc func applicationDidEnterBackground() {
        stopScan(cleaned: false)
    }
    
    @objc func applicationWillResignActive() {
        // TODO:
    }
    
    // MARK - method
    
    /**
     Scan
     */
    
    /// Radar is scanning
    public var isScanning: Bool {
        return self.centralManager.isScanning
    }
    
    /// Start scan
    public func resume() {
        
        if status == .poweredOn {
            if !isScanning {
                self.centralManager.scanForPeripherals(withServices: self.serviceUUIDs, options: self.scanOptions)
                debugPrint("[Bleu Radar] start scan.")
            }
        } else {
            self.startScanBlock = { [unowned self] (options) in
                if !self.isScanning {
                    self.centralManager.scanForPeripherals(withServices: self.serviceUUIDs, options: self.scanOptions)
                    debugPrint("[Bleu Radar] start scan.")
                }
            }
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(self.timeout)) { [weak self] in
            guard let strongSelf = self else {
                return
            }
            if strongSelf.centralManager.isScanning {
                strongSelf.stopScan(cleaned: true)
                strongSelf.completionHandler?(strongSelf.completedRequests, RadarError.timeout)
            }
        }
    }
    
    /// Stop scan
    public func stopScan(cleaned: Bool) {
        self.centralManager.stopScan()
        debugPrint("[Bleu Radar] Stop scan.")
        if cleaned {
            cleanup()
        }
    }
    
    /// Clean CenteralManager
    public func cleanup() {
        self.discoveredPeripherals = []
        self.connectedPeripherals = []
        debugPrint("[Bleu Radar] Clean")
    }
    
    /// Cancel peripheral connection
    public func cancelPeripheralConnection(_ peripheral: CBPeripheral) {
        self.centralManager.cancelPeripheralConnection(peripheral)
    }
    
    // MARK: - CBCentralManagerDelegate
    
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: self.startScanBlock?(self.scanOptions)
        case .resetting: debugPrint("[Bleu Radar] central manager state resetting")
        case .unauthorized: debugPrint("[Bleu Radar] central manager state unauthorized")
        case .poweredOff: debugPrint("[Bleu Radar] central manager state poweredOff")
        case .unknown: debugPrint("[Bleu Radar] central manager state unknown")
        case .unsupported: debugPrint("[Bleu Radar] central manager state unsupported")
        }
    }
    
    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        self.discoveredPeripherals.insert(peripheral)
        let thresholdRSSI: NSNumber = self.thresholdRSSI as NSNumber
        if thresholdRSSI.intValue < RSSI.intValue {
            self.centralManager.connect(peripheral, options: nil)
            stopScan(cleaned: false)
        } else {
            self.centralManager.connect(peripheral, options: nil)
        }
        debugPrint("[Bleu Radar] discover peripheral. ", peripheral, RSSI)
    }
    
    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let serviceUUIDs: [CBUUID] = self.serviceUUIDs
        peripheral.delegate = self
        peripheral.discoverServices(serviceUUIDs)
        self.connectedPeripherals.insert(peripheral)
        debugPrint("[Bleu Radar] donnect peripheral. ", peripheral)
    }
    
    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        debugPrint("[Bleu Radar] fail to connect peripheral. ", peripheral, error ?? "")
        self.connectedPeripherals.remove(peripheral)
    }
    
    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        debugPrint("[Bleu Radar] did disconnect peripheral. ", peripheral, error ?? "")
        self.connectedPeripherals.remove(peripheral)
        self.checkScanCompletedIfNeeded()
    }
    
    public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        //let peripherals: [CBPeripheral] = dict[CBAdvertisementDataLocalNameKey]
    }
    
    private func get(peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        self.requests.forEach { (request) in
            if request.characteristicUUID == characteristic.uuid {
                peripheral.readValue(for: characteristic)
            }
        }
    }
    
    private func post(peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        self.requests.forEach { (request) in
            if request.characteristicUUID == characteristic.uuid {
                guard let data: Data = request.value else {
                    return
                }
                peripheral.writeValue(data, for: characteristic, type: .withResponse)
            }
        }
    }
    
    private func notify(peripheral: CBPeripheral, characteristic: CBCharacteristic) {
        self.requests.forEach { (request) in
            if request.characteristicUUID == characteristic.uuid {
                switch request.method {
                case .get(let isNotify): peripheral.setNotifyValue(isNotify, for: characteristic)
                default: break
                }
            }
        }
    }
    
    private func receiveResponse(peripheral: CBPeripheral, characteristic: CBCharacteristic, error: Error?) {
        self.requests.forEach { (request) in
            if request.characteristicUUID == characteristic.uuid {
                if let handler = request.response {
                    DispatchQueue.main.async {
                        handler(peripheral, characteristic, error)
                    }
                }
                if var requests: Set<Request> = self.completedRequests[peripheral] {
                    requests.insert(request)
                } else {
                    self.completedRequests[peripheral] = [request]
                }
            }
        }
        self.checkRequestCompleted(for: peripheral)
    }
    
    private func checkRequestCompleted(for peripheral: CBPeripheral) {
        if let requests: Set<Request> = self.completedRequests[peripheral] {
            debugPrint("[Bleu Radar] Check request completed for peripheral: \(peripheral)")
            if requests.count == self.completedRequests.count {
                if !self.isNotifying {
                    self.centralManager.cancelPeripheralConnection(peripheral)
                    self.setNeedsCheckScanCompleted()
                }
            }
        }
    }
    
    private var isNeedCheckScanCompleted: Bool = false
    
    private func setNeedsCheckScanCompleted() {
        self.isNeedCheckScanCompleted = true
    }
    
    private func checkScanCompletedIfNeeded() {
        if self.isNeedCheckScanCompleted {
            checkScanCompleted()
            self.isNeedCheckScanCompleted = false
        }
    }
    
    private func checkScanCompleted() {
        debugPrint("[Bleu Radar] Check scan completed. connected peripherals count: \(self.connectedPeripherals.count)")
        if self.connectedPeripherals.count == 0 {
            self.stopScan(cleaned: true)
            self.completionHandler?(self.completedRequests, nil)
            debugPrint("[Bleu Radar] Completed")
        }
    }
    
    // MARK: -
    // MARK: Serivce
    
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        debugPrint("[Bleu Radar] did discover service. peripheral", peripheral, error ?? "")
        guard let services: [CBService] = peripheral.services else {
            return
        }
        debugPrint("[Bleu Radar] did discover service. services", services)
        let characteristicUUIDs: [CBUUID] = self.requests.map({ return $0.characteristicUUID! })
        for service in services {
            peripheral.discoverCharacteristics(characteristicUUIDs, for: service)
        }
    }
    
    public func peripheralDidUpdateName(_ peripheral: CBPeripheral) {
        debugPrint("[Bleu Radar] update name ", peripheral)
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        debugPrint("[Bleu Radar] didModifyServices ", peripheral, invalidatedServices)
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverIncludedServicesFor service: CBService, error: Error?) {
        debugPrint("[Bleu Radar] did discover included services for ", peripheral, service)
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        debugPrint("[Bleu Radar] did read RSSI ", RSSI)
    }
    
    // MARK: Characteristic
    
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error: Error = error {
            debugPrint("[Bleu Radar] did discover characteristics for service. Error", peripheral, error)
            return
        }
        debugPrint("[Bleu Radar] did discover characteristics for service.", peripheral)
        for characteristic in service.characteristics! {
            
            let characteristicUUIDs: [CBUUID] = self.requests.map({ return $0.characteristicUUID! })
            if characteristicUUIDs.contains(characteristic.uuid) {
                let properties: CBCharacteristicProperties = characteristic.properties
                if properties.contains(.notify) {
                    debugPrint("[Bleu Radar] characteristic properties notify")
                    self.notify(peripheral: peripheral, characteristic: characteristic)
                }
                if properties.contains(.read) {
                    debugPrint("[Bleu Radar] characteristic properties read")
                    self.get(peripheral: peripheral, characteristic: characteristic)
                }
                if properties.contains(.write) {
                    debugPrint("[Bleu Radar] characteristic properties write")
                    self.post(peripheral: peripheral, characteristic: characteristic)
                }
            }
        }
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        debugPrint("[Bleu Radar] did update value for characteristic", peripheral, characteristic)
        self.receiveResponse(peripheral: peripheral, characteristic: characteristic, error: error)
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        debugPrint("[Bleu Radar] did write value for characteristic", peripheral, characteristic)
        self.receiveResponse(peripheral: peripheral, characteristic: characteristic, error: error)
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        debugPrint("[Bleu Radar] did update notification state for characteristic", peripheral, characteristic)
        self.receiveResponse(peripheral: peripheral, characteristic: characteristic, error: error)
    }
    
    // MARK: Descriptor
    
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic, error: Error?) {
        debugPrint("[Bleu Radar] did discover descriptors for ", peripheral, characteristic)
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor descriptor: CBDescriptor, error: Error?) {
        debugPrint("[Bleu Radar] did update value for descriptor", peripheral, descriptor)
    }
    
    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor descriptor: CBDescriptor, error: Error?) {
        debugPrint("[Bleu Radar] did write value for descriptor", peripheral, descriptor)
    }
    
    
    // MARK: -
    
    internal func _debug() {
        debugPrint("discoveredPeripherals", self.discoveredPeripherals)
        debugPrint("connectedPeripherals ", self.connectedPeripherals)
    }
}
