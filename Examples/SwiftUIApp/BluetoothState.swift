//
//  BluetoothState.swift
//  SwiftUIApp
//
//  Bluetooth状態管理
//  Bluetooth state management for SwiftUI
//

import SwiftUI
import CoreBluetooth

// MARK: - Bluetooth Manager

/// Bluetooth状態を管理するObservableObject
/// ObservableObject that manages Bluetooth state
@MainActor
class BluetoothManager: ObservableObject {
    @Published var isAvailable = false
    @Published var state: CBManagerState = .unknown
    
    private var centralManager: CBCentralManager?
    private var delegateProxy: BluetoothDelegate?
    
    init() {
        setupBluetooth()
    }
    
    /// Bluetooth状態の監視を開始
    /// Start monitoring Bluetooth state changes
    private func setupBluetooth() {
        delegateProxy = BluetoothDelegate { [weak self] newState in
            Task { @MainActor in
                self?.state = newState
                self?.isAvailable = (newState == .poweredOn)
            }
        }
        centralManager = CBCentralManager(delegate: delegateProxy, queue: nil)
    }
    
    /// 状態の説明文
    /// Human-readable state description
    var stateDescription: String {
        switch state {
        case .poweredOn: return "Bluetooth Ready"
        case .poweredOff: return "Bluetooth Off"
        case .unauthorized: return "Bluetooth Unauthorized"
        case .unsupported: return "Bluetooth Unsupported"
        case .resetting: return "Bluetooth Resetting"
        default: return "Bluetooth Unavailable"
        }
    }
}

// MARK: - Bluetooth Delegate

private class BluetoothDelegate: NSObject, CBCentralManagerDelegate {
    let onStateUpdate: (CBManagerState) -> Void
    
    init(onStateUpdate: @escaping (CBManagerState) -> Void) {
        self.onStateUpdate = onStateUpdate
        super.init()
    }
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        onStateUpdate(central.state)
    }
}