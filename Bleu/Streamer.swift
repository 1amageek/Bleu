//
//  Streamer.swift
//  Bleu
//
//  Created by 1amageek on 2017/06/11.
//  Copyright © 2017年 Stamp inc. All rights reserved.
//

import Foundation
import CoreBluetooth

@available(iOS 11.0, *)
public class Streamer: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {

    public enum StreamerError: Error {
        case timeout
        case canceled
        case invalidRequest
        
        public var localizedDescription: String {
            switch self {
            case .timeout: return "[Bleu Streamer] *** Error: Scanning timeout."
            case .canceled: return "[Bleu Streamer] *** Error: Scan was canceled."
            case .invalidRequest: return "[Bleu Streamer] *** Error: Invalid Request."
            }
        }
    }

    /// Streamer options
    public struct Options {

        /// Same as CBCentralManagerOptionShowPowerAlertKey.
        public var showPowerAlertKey: Bool = false

        /// Same as CBCentralManagerOptionRestoreIdentifierKey.
        public var restoreIdentifierKey: String

        /// Same as CBCentralManagerScanOptionAllowDuplicatesKey
        public var allowDuplicatesKey: Bool = false

        /// Set up RSSI that can communicate
        public var thresholdRSSI: Int = -30         // This value is the distance between the devices is about 20 cm.

        /// Set communication timeout.
        public var timeout: Int = 10                // This value is the time to stop scanning Default 10s

        public init(showPowerAlertKey: Bool = false,
                    restoreIdentifierKey: String = UUID().uuidString,
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

    private(set) lazy var centralManager: CBCentralManager = {
        var options: [String: Any] = [:]
        options[CBCentralManagerOptionRestoreIdentifierKey] = self.restoreIdentifierKey
        options[CBCentralManagerOptionShowPowerAlertKey] = self.showPowerAlert
        let manager: CBCentralManager = CBCentralManager(delegate: self, queue: self.queue, options: options)
        manager.delegate = self
        return manager
    }()

    /// Queue
    internal let queue: DispatchQueue = DispatchQueue(label: "bleu.streamer.queue")

    /// Discoverd peripherals
    private(set) var discoveredPeripherals: Set<CBPeripheral> = []

    /// Connected peripherals
    private(set) var connectedPeripherals: Set<CBPeripheral> = []

    /// Controlled service UUID
    public var serviceUUID: CBUUID {
        return self.request.serviceUUID
    }

    /// Returns the status of CMCentralManager.
    public var status: CBManagerState {
        return self.centralManager.state
    }

    /// Returns the response threshold.
    public var thresholdRSSI: Int {
        return self.streamerOptions.thresholdRSSI
    }

    /// Return communication multiple times.
    public var allowDuplicates: Bool {
        return self.streamerOptions.allowDuplicatesKey
    }

    /// Return time for communication timeout.
    public var timeout: Int {
        return self.streamerOptions.timeout
    }

    /// Restore Identifier
    private var restoreIdentifierKey: String?

    /// Show Power alert
    private var showPowerAlert: Bool = false

    /// Radar's options
    private var streamerOptions: Options!

    /// Scan options
    private var scanOptions: [String: Any] = [:]

    /// It is called at the timing when Bluetooth becomes ready to communicate.
    private var startScanBlock: (([String : Any]?) -> Void)?

    /// Request managed by Radar.
    private var request: Request!

    private(set) var PSM: CBL2CAPPSM?

    internal var didOpenChannelBlock: ((CBPeripheral, CBL2CAPChannel?, Error?) -> Void)?

    // MARK: -

    /**
     It is initialization of Radar.

     - parameter requests: The server sets a request to send.
     - parameter options: Set the option to change Radar's behavior.
     */
    public init(request: Request, options: Options) {
        super.init()

        var scanOptions: [String: Any] = [:]
        let serviceUUIDs: [CBUUID] = [request.serviceUUID]
        scanOptions[CBCentralManagerScanOptionSolicitedServiceUUIDsKey] = serviceUUIDs
        scanOptions[CBCentralManagerScanOptionAllowDuplicatesKey] = options.allowDuplicatesKey
        self.restoreIdentifierKey = options.restoreIdentifierKey
        self.showPowerAlert = options.showPowerAlertKey

        self.scanOptions = scanOptions
        self.streamerOptions = options
        self.request = request
        self.PSM = request.PSM

        NotificationCenter.default.addObserver(self, selector: #selector(applicationDidEnterBackground), name: NSNotification.Name.UIApplicationDidEnterBackground, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(applicationWillResignActive), name: NSNotification.Name.UIApplicationDidBecomeActive, object: nil)
    }

    deinit {
        debugPrint("[Bleu Streamer] deinit.")
        NotificationCenter.default.removeObserver(self)
    }

    @objc func applicationDidEnterBackground() {
        stopScan(cleaned: false)
    }

    @objc func applicationWillResignActive() {
        // TODO:
    }

    // MARK: -

    /// Radar is scanning
    public var isScanning: Bool {
        return self.centralManager.isScanning
    }

    /// Start scan
    public func resume() {

        if status == .poweredOn {
            if !isScanning {
                self.centralManager.scanForPeripherals(withServices: [self.serviceUUID], options: self.scanOptions)
                debugPrint("[Bleu Streamer] start scan.")
            }
        } else {
            self.startScanBlock = { [unowned self] (options) in
                if !self.isScanning {
                    self.centralManager.scanForPeripherals(withServices: [self.serviceUUID], options: self.scanOptions)
                    debugPrint("[Bleu Streamer] start scan.")
                }
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(self.timeout)) { [weak self] in
            guard let strongSelf = self else {
                return
            }
            if !strongSelf.centralManager.isScanning {
                return
            }
//            strongSelf.stopScan(cleaned: true)
//            strongSelf.completionHandler?(strongSelf.completedRequests, StreamerError.timeout)
        }
    }

    /// Cancel
    public func cancel() {
        debugPrint("[Bleu Streamer] Cancel")
        self.stopScan(cleaned: true)
//        self.completionHandler?(self.completedRequests, StreamerError.canceled)
    }

    /// Stop scan
    private func stopScan(cleaned: Bool) {
        debugPrint("[Bleu Streamer] Stop scan.")
        self.centralManager.stopScan()
        if cleaned {
            cleanup()
        }
    }

    /// Clean CenteralManager
    private func cleanup() {
        self.discoveredPeripherals = []
        self.connectedPeripherals = []
        debugPrint("[Bleu Streamer] Clean")
    }

    /// Cancel peripheral connection
    private func cancelPeripheralConnection(_ peripheral: CBPeripheral) {
        self.centralManager.cancelPeripheralConnection(peripheral)
    }

    // MARK: - CBCentralManagerDelegate

    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: self.startScanBlock?(self.scanOptions)
        case .resetting: debugPrint("[Bleu Streamer] central manager state resetting")
        case .unauthorized: debugPrint("[Bleu Streamer] central manager state unauthorized")
        case .poweredOff: debugPrint("[Bleu Streamer] central manager state poweredOff")
        case .unknown: debugPrint("[Bleu Streamer] central manager state unknown")
        case .unsupported: debugPrint("[Bleu Streamer] central manager state unsupported")
        }
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        self.discoveredPeripherals.insert(peripheral)
        if self.allowDuplicates {
            let thresholdRSSI: NSNumber = self.thresholdRSSI as NSNumber
            if thresholdRSSI.intValue < RSSI.intValue {
                self.centralManager.connect(peripheral, options: nil)
                stopScan(cleaned: false)
            }
        } else {
            self.centralManager.connect(peripheral, options: nil)
        }
        debugPrint("[Bleu Streamer] discover peripheral. ", peripheral, RSSI)
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        let serviceUUIDs: [CBUUID] = [self.serviceUUID]
        peripheral.delegate = self
        peripheral.discoverServices(serviceUUIDs)
        self.connectedPeripherals.insert(peripheral)
        debugPrint("[Bleu Streamer] did connect peripheral. ", peripheral)
        if let PSM: CBL2CAPPSM = self.PSM {
            peripheral.openL2CAPChannel(PSM)
        }
    }

    public func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        debugPrint("[Bleu Streamer] fail to connect peripheral. ", peripheral, error ?? "")
        self.connectedPeripherals.remove(peripheral)
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        debugPrint("[Bleu Streamer] did disconnect peripheral. ", peripheral, error ?? "")
        self.connectedPeripherals.remove(peripheral)
    }

    public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        //let peripherals: [CBPeripheral] = dict[CBAdvertisementDataLocalNameKey]
    }

    // MARK: - CBPeripheralDelegate

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        debugPrint("[Bleu Streamer] did discover service. peripheral", peripheral, error ?? "")
        guard let services: [CBService] = peripheral.services else {
            return
        }
        debugPrint("[Bleu Streamer] did discover service. services", services)
    }

    public func peripheralDidUpdateName(_ peripheral: CBPeripheral) {
        debugPrint("[Bleu Streamer] update name ", peripheral)
    }

    public func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        debugPrint("[Bleu Streamer] didModifyServices ", peripheral, invalidatedServices)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverIncludedServicesFor service: CBService, error: Error?) {
        debugPrint("[Bleu Streamer] did discover included services for ", peripheral, service)
    }

    public func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        debugPrint("[Bleu Streamer] did read RSSI ", RSSI)
    }

    // MARK: - L2CAP

    public func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        debugPrint("[Bleu Streamer] did open channel", peripheral, channel ?? "", error ?? "")
        self.didOpenChannelBlock?(peripheral, channel, error)
    }

    // MARK: -

    internal func _debug() {
        debugPrint("discoveredPeripherals", self.discoveredPeripherals)
        debugPrint("connectedPeripherals ", self.connectedPeripherals)
    }
}
