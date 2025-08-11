//
//  BleuExampleApp.swift
//  SwiftUIApp
//
//  SwiftUIアプリケーションの例
//  SwiftUI application example for Bleu v2
//

import SwiftUI
import Bleu
import CoreBluetooth

@main
struct BleuExampleApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}

struct ContentView: View {
    @StateObject private var bluetoothManager = BluetoothManager()
    
    var body: some View {
        NavigationView {
            VStack(spacing: 20) {
                // Bluetooth状態表示
                BluetoothStatusView(manager: bluetoothManager)
                
                // サーバー例
                NavigationLink(destination: ServerExampleView()) {
                    Label("Server Example", systemImage: "antenna.radiowaves.left.and.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                
                // クライアント例
                NavigationLink(destination: ClientExampleView()) {
                    Label("Client Example", systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                
                Spacer()
            }
            .padding()
            .navigationTitle("Bleu Examples")
        }
    }
}

// MARK: - Bluetooth Status View

struct BluetoothStatusView: View {
    @ObservedObject var manager: BluetoothManager
    
    var body: some View {
        HStack {
            Image(systemName: manager.isAvailable ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(manager.isAvailable ? .green : .red)
            
            Text(manager.stateDescription)
                .font(.subheadline)
            
            Spacer()
        }
        .padding()
        .background(Color.gray.opacity(0.1))
        .cornerRadius(8)
    }
}

#Preview {
    ContentView()
}