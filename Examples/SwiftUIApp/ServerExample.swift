//
//  ServerExample.swift
//  SwiftUIApp
//
//  BLEサーバーのSwiftUI実装例
//  SwiftUI implementation example of BLE server
//

import SwiftUI
import Bleu
import Distributed
import BleuCommon

struct ServerExampleView: View {
    @StateObject private var serverManager = ServerManager()
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            // ステータス表示
            ServerStatusView(isRunning: serverManager.isRunning)
            
            // コントロール
            HStack {
                Button(serverManager.isRunning ? "Stop Server" : "Start Server") {
                    Task {
                        if serverManager.isRunning {
                            await serverManager.stopServer()
                        } else {
                            await serverManager.startServer()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(serverManager.isLoading)
                
                if serverManager.isLoading {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }
            
            // デバイス情報
            if serverManager.isRunning {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Device Information")
                        .font(.headline)
                    
                    InfoRow(label: "Device Name", value: serverManager.deviceName)
                    InfoRow(label: "Firmware", value: serverManager.firmwareVersion)
                    InfoRow(label: "Hardware", value: serverManager.hardwareVersion)
                    InfoRow(label: "Serial Number", value: String(serverManager.serialNumber.prefix(8)) + "...")
                }
                .padding()
                .background(Color.gray.opacity(0.1))
                .cornerRadius(8)
            }
            
            // アクセスログ
            if !serverManager.accessLogs.isEmpty {
                Text("Access Logs")
                    .font(.headline)
                
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(serverManager.accessLogs) { log in
                            AccessLogView(log: log)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
            
            Spacer()
        }
        .padding()
        .navigationTitle("Server Example")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - Server Status View

struct ServerStatusView: View {
    let isRunning: Bool
    
    var body: some View {
        HStack {
            Circle()
                .fill(isRunning ? Color.green : Color.gray)
                .frame(width: 12, height: 12)
            
            Text(isRunning ? "Server is advertising" : "Server is stopped")
                .font(.subheadline)
            
            Spacer()
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
    }
}

// MARK: - Access Log View

struct AccessLogView: View {
    let log: AccessLog
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(log.action)
                    .font(.caption)
                    .fontWeight(.medium)
                
                Text(log.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            if log.success {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .font(.caption)
            } else {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
                    .font(.caption)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.gray.opacity(0.1))
        .cornerRadius(6)
    }
}

// MARK: - Server Manager

@MainActor
class ServerManager: ObservableObject {
    @Published var isRunning = false
    @Published var isLoading = false
    @Published var accessLogs: [AccessLog] = []
    
    // Device Info
    let deviceName = "Bleu Example Device"
    let firmwareVersion = "2.0.0"
    let hardwareVersion = "Rev A"
    let serialNumber = UUID().uuidString
    
    private var deviceInfoPeripheral: DeviceInfoPeripheral?
    private let actorSystem = BLEActorSystem.shared
    
    /// サーバーを開始
    /// Start the BLE server
    func startServer() async {
        isLoading = true
        defer { isLoading = false }
        
        do {
            // Create and configure the peripheral actor
            deviceInfoPeripheral = DeviceInfoPeripheral(
                actorSystem: actorSystem,
                deviceName: deviceName,
                firmwareVersion: firmwareVersion,
                hardwareVersion: hardwareVersion,
                serialNumber: serialNumber
            )
            
            // Start advertising
            if let peripheral = deviceInfoPeripheral {
                try await actorSystem.startAdvertising(peripheral)
                isRunning = true
                
                // Add log entry
                accessLogs.append(AccessLog(
                    action: "Started advertising as \(deviceName)",
                    success: true,
                    timestamp: Date()
                ))
                
                // Simulate access logs for demo
                startAccessLogSimulation()
            }
            
        } catch {
            print("Failed to start server: \(error)")
            accessLogs.append(AccessLog(
                action: "Failed to start: \(error.localizedDescription)",
                success: false,
                timestamp: Date()
            ))
        }
    }
    
    /// サーバーを停止
    /// Stop the BLE server
    func stopServer() async {
        await actorSystem.stopAdvertising()
        deviceInfoPeripheral = nil
        isRunning = false
        
        accessLogs.append(AccessLog(
            action: "Stopped advertising",
            success: true,
            timestamp: Date()
        ))
    }
    
    /// アクセスログのシミュレーション
    /// Simulate access logs for demo purposes
    private func startAccessLogSimulation() {
        Task {
            while isRunning {
                try await Task.sleep(nanoseconds: UInt64.random(in: 5_000_000_000...15_000_000_000))
                
                if !isRunning { break }
                
                let actions = [
                    "Device info requested",
                    "Connection established",
                    "Characteristic read",
                    "Service discovered"
                ]
                
                accessLogs.append(AccessLog(
                    action: actions.randomElement()!,
                    success: Bool.random(),
                    timestamp: Date()
                ))
                
                // Keep only last 20 logs
                if accessLogs.count > 20 {
                    accessLogs.removeFirst()
                }
            }
        }
    }
}

// MARK: - Data Models

struct AccessLog: Identifiable {
    let id = UUID()
    let action: String
    let success: Bool
    let timestamp: Date
}

#Preview {
    NavigationView {
        ServerExampleView()
    }
}