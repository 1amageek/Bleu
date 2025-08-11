//
//  ClientExample.swift
//  SwiftUIApp
//
//  BLEクライアントのSwiftUI実装例
//  SwiftUI implementation example of BLE client
//

import SwiftUI
import Bleu
import Distributed
import BleuCommon

struct ClientExampleView: View {
    @StateObject private var clientManager = ClientManager()
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // スキャン状態
            ScanStatusView(isScanning: clientManager.isScanning)
            
            // コントロール
            HStack {
                Button(clientManager.isScanning ? "Stop Scan" : "Start Scan") {
                    Task {
                        if clientManager.isScanning {
                            clientManager.stopScan()
                        } else {
                            await clientManager.startScan()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(clientManager.isLoading)
                
                if clientManager.isLoading {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }
            
            // 発見されたデバイス
            if !clientManager.discoveredDevices.isEmpty {
                Text("Discovered Devices")
                    .font(.headline)
                
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(clientManager.discoveredDevices) { device in
                            DeviceRowView(device: device) {
                                Task {
                                    await clientManager.connect(to: device)
                                }
                            }
                        }
                    }
                }
                .frame(maxHeight: 300)
            }
            
            // 接続されたデバイスの情報
            if let _ = clientManager.connectedDevice,
               let deviceInfo = clientManager.deviceInfo {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Connected Device")
                            .font(.headline)
                        Spacer()
                        Button("Disconnect") {
                            Task {
                                await clientManager.disconnect()
                            }
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                    }
                    
                    InfoRow(label: "Name", value: deviceInfo.deviceName)
                    InfoRow(label: "Firmware", value: deviceInfo.firmwareVersion)
                    InfoRow(label: "Hardware", value: deviceInfo.hardwareVersion)
                    InfoRow(label: "Serial", value: String(deviceInfo.serialNumber.prefix(8)) + "...")
                    InfoRow(label: "Last Updated", value: deviceInfo.timestamp.formatted(date: .omitted, time: .shortened))
                    
                    Button("Refresh Info") {
                        Task {
                            await clientManager.refreshDeviceInfo()
                        }
                    }
                    .font(.caption)
                    .buttonStyle(.borderedProminent)
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)
            }
            
            Spacer()
        }
        .padding()
        .navigationTitle("Client Example")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - Scan Status View

struct ScanStatusView: View {
    let isScanning: Bool
    
    var body: some View {
        HStack {
            if isScanning {
                ProgressView()
                    .scaleEffect(0.7)
                    .padding(.trailing, 4)
            } else {
                Circle()
                    .fill(Color.gray)
                    .frame(width: 12, height: 12)
            }
            
            Text(isScanning ? "Scanning for devices..." : "Not scanning")
                .font(.subheadline)
            
            Spacer()
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
    }
}

// MARK: - Device Row View

struct DeviceRowView: View {
    let device: DiscoveredDevice
    let onConnect: () -> Void
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(device.name)
                    .font(.subheadline)
                    .fontWeight(.medium)
                
                Text("RSSI: \(device.rssi) dBm")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button("Connect") {
                onConnect()
            }
            .font(.caption)
            .buttonStyle(.bordered)
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
    }
}

// MARK: - Client Manager

@MainActor
class ClientManager: ObservableObject {
    @Published var isScanning = false
    @Published var isLoading = false
    @Published var discoveredDevices: [DiscoveredDevice] = []
    @Published var connectedDevice: DiscoveredDevice?
    @Published var deviceInfo: DeviceInfo?
    
    private let actorSystem = BLEActorSystem.shared
    private var scanTask: Task<Void, Never>?
    private var connectedPeripheral: DeviceInfoPeripheral?
    
    /// スキャンを開始
    /// Start scanning for devices
    func startScan() async {
        isScanning = true
        discoveredDevices.removeAll()
        
        scanTask = Task {
            do {
                // Discover DeviceInfoPeripheral actors
                let peripherals = try await actorSystem.discover(
                    DeviceInfoPeripheral.self,
                    timeout: 30.0
                )
                
                for peripheral in peripherals {
                    let device = DiscoveredDevice(
                        id: peripheral.id,
                        name: "Device \(peripheral.id.uuidString.prefix(8))",
                        rssi: -50 - Int.random(in: 0...30)
                    )
                    
                    if !discoveredDevices.contains(where: { $0.id == device.id }) {
                        discoveredDevices.append(device)
                    }
                }
            } catch {
                print("Scan error: \(error)")
            }
            
            isScanning = false
        }
    }
    
    /// スキャンを停止
    /// Stop scanning
    func stopScan() {
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
    }
    
    /// デバイスに接続
    /// Connect to a device
    func connect(to device: DiscoveredDevice) async {
        isLoading = true
        defer { isLoading = false }
        
        do {
            // Connect to the peripheral
            connectedPeripheral = try await actorSystem.connect(
                to: device.id,
                as: DeviceInfoPeripheral.self
            )
            
            if let peripheral = connectedPeripheral {
                // Get device info
                deviceInfo = try await peripheral.getDeviceInfo()
                connectedDevice = device
                
                // Stop scanning
                stopScan()
            }
        } catch {
            print("Connection error: \(error)")
        }
    }
    
    /// 切断
    /// Disconnect from device
    func disconnect() async {
        if let device = connectedDevice {
            do {
                try await actorSystem.disconnect(from: device.id)
            } catch {
                print("Disconnect error: \(error)")
            }
        }
        
        connectedPeripheral = nil
        connectedDevice = nil
        deviceInfo = nil
    }
    
    /// デバイス情報を更新
    /// Refresh device information
    func refreshDeviceInfo() async {
        guard let peripheral = connectedPeripheral else { return }
        
        isLoading = true
        defer { isLoading = false }
        
        do {
            deviceInfo = try await peripheral.getDeviceInfo()
        } catch {
            print("Failed to refresh device info: \(error)")
        }
    }
}

// MARK: - Data Models

struct DiscoveredDevice: Identifiable {
    let id: UUID
    let name: String
    let rssi: Int
}

#Preview {
    NavigationView {
        ClientExampleView()
    }
}