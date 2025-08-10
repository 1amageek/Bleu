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
                BluetoothStatusCard(bluetoothManager: bluetoothManager)
                
                NavigationLink("BLE Server Example") {
                    ServerView()
                }
                .buttonStyle(.borderedProminent)
                
                NavigationLink("BLE Client Example") {
                    ClientView()
                }
                .buttonStyle(.borderedProminent)
                
                NavigationLink("Remote Actor Communication") {
                    RemoteActorDemoView()
                }
                .buttonStyle(.borderedProminent)
                
                Spacer()
            }
            .padding()
            .navigationTitle("Bleu Examples")
        }
    }
}

struct BluetoothStatusCard: View {
    @ObservedObject var bluetoothManager: BluetoothManager
    
    var body: some View {
        VStack {
            HStack {
                Image(systemName: bluetoothManager.isAvailable ? "antenna.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right.slash")
                    .foregroundColor(bluetoothManager.isAvailable ? .green : .red)
                    .font(.title2)
                
                Text("Bluetooth")
                    .font(.headline)
                
                Spacer()
                
                Text(bluetoothManager.stateDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            if bluetoothManager.isAvailable {
                Text("✓ Ready for BLE communication")
                    .font(.caption)
                    .foregroundColor(.green)
            } else {
                Text("⚠️ Bluetooth not available")
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        .padding()
        .background(Color(UIColor.systemBackground))
        .cornerRadius(12)
        .shadow(radius: 2)
    }
}

@MainActor
class BluetoothManager: ObservableObject {
    @Published var isAvailable = false
    @Published var state: CBManagerState = .unknown
    
    private var stateMonitorTask: Task<Void, Never>?
    
    init() {
        startMonitoring()
    }
    
    deinit {
        stateMonitorTask?.cancel()
    }
    
    private func startMonitoring() {
        stateMonitorTask = Task {
            let stateStream = Bleu.monitorBluetoothState()
            
            for await newState in stateStream {
                self.state = newState
                self.isAvailable = newState == .poweredOn
            }
        }
    }
    
    var stateDescription: String {
        switch state {
        case .unknown: return "Unknown"
        case .resetting: return "Resetting"
        case .unsupported: return "Unsupported"
        case .unauthorized: return "Unauthorized"
        case .poweredOff: return "Powered Off"
        case .poweredOn: return "Powered On"
        @unknown default: return "Unknown State"
        }
    }
}

// MARK: - Server Example

struct ServerView: View {
    @StateObject private var serverManager = BleuServerManager()
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("BLE Server")
                .font(.largeTitle)
                .bold()
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Service UUID:")
                    .font(.headline)
                Text("12345678-1234-5678-9ABC-123456789ABC")
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            
            HStack {
                Button(serverManager.isRunning ? "Stop Server" : "Start Server") {
                    if serverManager.isRunning {
                        await serverManager.stopServer()
                    } else {
                        await serverManager.startServer()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(serverManager.isLoading)
                
                if serverManager.isLoading {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }
            
            if serverManager.isRunning {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Server Status: Running")
                        .foregroundColor(.green)
                        .bold()
                    
                    Text("Clients can connect and send requests")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            if !serverManager.receivedRequests.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Received Requests:")
                        .font(.headline)
                    
                    ForEach(serverManager.receivedRequests, id: \.timestamp) { request in
                        RequestCard(request: request)
                    }
                }
            }
            
            Spacer()
        }
        .padding()
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct RequestCard: View {
    let request: ReceivedRequest
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Device Info Request")
                    .font(.caption)
                    .bold()
                Spacer()
                Text(request.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Text("Response: \(request.response.deviceName) (v\(request.response.firmwareVersion))")
                .font(.caption)
        }
        .padding(8)
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(8)
    }
}

@MainActor
class BleuServerManager: ObservableObject {
    @Published var isRunning = false
    @Published var isLoading = false
    @Published var receivedRequests: [ReceivedRequest] = []
    
    private var server: BleuServer?
    
    func startServer() async {
        isLoading = true
        
        do {
            let serviceUUID = UUID(uuidString: "12345678-1234-5678-9ABC-123456789ABC")!
            let characteristicUUID = UUID(uuidString: "87654321-4321-8765-CBA9-987654321CBA")!
            
            server = try await BleuServer(
                serviceUUID: serviceUUID,
                characteristicUUIDs: [characteristicUUID],
                localName: "Bleu Example Server"
            )
            
            // Handle device info requests
            await server?.handleRequests(ofType: GetDeviceInfoRequest.self) { request in
                let response = GetDeviceInfoRequest.Response(
                    deviceName: "Bleu Demo Device",
                    firmwareVersion: "2.0.0",
                    batteryLevel: Int.random(in: 20...100)
                )
                
                await MainActor.run {
                    self.receivedRequests.append(ReceivedRequest(
                        timestamp: Date(),
                        response: response
                    ))
                }
                
                return response
            }
            
            isRunning = true
        } catch {
            print("Failed to start server: \(error)")
        }
        
        isLoading = false
    }
    
    func stopServer() async {
        await server?.shutdown()
        server = nil
        isRunning = false
        receivedRequests.removeAll()
    }
}

struct ReceivedRequest {
    let timestamp: Date
    let response: GetDeviceInfoRequest.Response
}

// MARK: - Client Example

struct ClientView: View {
    @StateObject private var clientManager = BleuClientManager()
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("BLE Client")
                .font(.largeTitle)
                .bold()
            
            HStack {
                Button("Scan for Devices") {
                    await clientManager.scanForDevices()
                }
                .buttonStyle(.borderedProminent)
                .disabled(clientManager.isScanning)
                
                if clientManager.isScanning {
                    ProgressView()
                        .scaleEffect(0.8)
                }
            }
            
            if !clientManager.discoveredDevices.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Discovered Devices:")
                        .font(.headline)
                    
                    ForEach(clientManager.discoveredDevices, id: \.identifier.uuid) { device in
                        DeviceCard(
                            device: device,
                            onConnect: { await clientManager.connect(to: device) },
                            isConnecting: clientManager.connectingDevices.contains(device.identifier.uuid)
                        )
                    }
                }
            }
            
            if !clientManager.responses.isEmpty {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Responses:")
                        .font(.headline)
                    
                    ForEach(clientManager.responses, id: \.timestamp) { response in
                        ResponseCard(response: response)
                    }
                }
            }
            
            Spacer()
        }
        .padding()
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct DeviceCard: View {
    let device: DeviceInfo
    let onConnect: () async -> Void
    let isConnecting: Bool
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(device.advertisementData.localName ?? "Unknown Device")
                    .font(.subheadline)
                    .bold()
                Text(device.identifier.uuid.uuidString)
                    .font(.caption)
                    .foregroundColor(.secondary)
                if let rssi = device.rssi {
                    Text("RSSI: \(rssi) dBm")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            Button("Connect") {
                Task { await onConnect() }
            }
            .buttonStyle(.bordered)
            .disabled(isConnecting)
            
            if isConnecting {
                ProgressView()
                    .scaleEffect(0.6)
            }
        }
        .padding()
        .background(Color(UIColor.systemBackground))
        .cornerRadius(8)
        .shadow(radius: 1)
    }
}

struct ResponseCard: View {
    let response: DeviceResponse
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Device: \(response.deviceName)")
                    .font(.subheadline)
                    .bold()
                Spacer()
                Text(response.timestamp, style: .time)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            
            HStack {
                Text("Firmware: \(response.firmwareVersion)")
                    .font(.caption)
                Text("•")
                    .foregroundColor(.secondary)
                Text("Battery: \(response.batteryLevel)%")
                    .font(.caption)
            }
        }
        .padding()
        .background(Color(UIColor.secondarySystemBackground))
        .cornerRadius(8)
    }
}

@MainActor
class BleuClientManager: ObservableObject {
    @Published var isScanning = false
    @Published var discoveredDevices: [DeviceInfo] = []
    @Published var connectingDevices: Set<UUID> = []
    @Published var responses: [DeviceResponse] = []
    
    private var client: BleuClient?
    
    init() {
        Task {
            do {
                client = try await BleuClient(
                    serviceUUIDs: [UUID(uuidString: "12345678-1234-5678-9ABC-123456789ABC")!]
                )
            } catch {
                print("Failed to create client: \(error)")
            }
        }
    }
    
    func scanForDevices() async {
        guard let client = client else { return }
        
        isScanning = true
        discoveredDevices.removeAll()
        
        do {
            let devices = try await client.discover(timeout: 10.0)
            discoveredDevices = devices
        } catch {
            print("Scan failed: \(error)")
        }
        
        isScanning = false
    }
    
    func connect(to device: DeviceInfo) async {
        guard let client = client else { return }
        
        connectingDevices.insert(device.identifier.uuid)
        
        do {
            _ = try await client.connect(to: device)
            
            // Send device info request
            let request = GetDeviceInfoRequest()
            let response = try await client.sendRequest(request, to: device.identifier)
            
            responses.append(DeviceResponse(
                deviceName: response.deviceName,
                firmwareVersion: response.firmwareVersion,
                batteryLevel: response.batteryLevel,
                timestamp: Date()
            ))
            
        } catch {
            print("Connection failed: \(error)")
        }
        
        connectingDevices.remove(device.identifier.uuid)
    }
}

struct DeviceResponse {
    let deviceName: String
    let firmwareVersion: String
    let batteryLevel: Int
    let timestamp: Date
}

// MARK: - Remote Actor Demo

struct RemoteActorDemoView: View {
    @StateObject private var demoManager = RemoteActorDemoManager()
    
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Remote Actor Communication")
                .font(.largeTitle)
                .bold()
            
            Text("This demonstrates distributed actors communicating over BLE as if they were local actors.")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            VStack(alignment: .leading, spacing: 12) {
                Text("Temperature Sensor Simulation")
                    .font(.headline)
                
                HStack {
                    Button(demoManager.isRunning ? "Stop Simulation" : "Start Simulation") {
                        if demoManager.isRunning {
                            await demoManager.stopSimulation()
                        } else {
                            await demoManager.startSimulation()
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    
                    if demoManager.isLoading {
                        ProgressView()
                            .scaleEffect(0.8)
                    }
                }
                
                if demoManager.isRunning {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Status: Broadcasting sensor data")
                            .foregroundColor(.green)
                            .bold()
                        
                        if let lastReading = demoManager.lastSensorReading {
                            HStack {
                                Text("Temperature: \(lastReading.temperature, specifier: "%.1f")°C")
                                Text("•")
                                    .foregroundColor(.secondary)
                                Text("Humidity: \(lastReading.humidity, specifier: "%.1f")%")
                            }
                            .font(.caption)
                            .padding(8)
                            .background(Color(UIColor.tertiarySystemBackground))
                            .cornerRadius(6)
                        }
                    }
                }
                
                if !demoManager.sensorReadings.isEmpty {
                    Text("Recent Readings:")
                        .font(.subheadline)
                        .bold()
                    
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(demoManager.sensorReadings.suffix(5), id: \.timestamp) { reading in
                            HStack {
                                Text("\(reading.temperature, specifier: "%.1f")°C")
                                Text("\(reading.humidity, specifier: "%.1f")%")
                                Spacer()
                                Text(reading.timestamp, style: .time)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            .font(.caption)
                        }
                    }
                    .padding(8)
                    .background(Color(UIColor.secondarySystemBackground))
                    .cornerRadius(8)
                }
            }
            
            Spacer()
        }
        .padding()
        .navigationBarTitleDisplayMode(.inline)
    }
}

@MainActor
class RemoteActorDemoManager: ObservableObject {
    @Published var isRunning = false
    @Published var isLoading = false
    @Published var sensorReadings: [SensorDataNotification] = []
    @Published var lastSensorReading: SensorDataNotification?
    
    private var server: BleuServer?
    private var simulationTask: Task<Void, Never>?
    
    func startSimulation() async {
        isLoading = true
        
        do {
            let serviceUUID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
            let sensorCharacteristicUUID = UUID(uuidString: "FFFFFFFF-EEEE-DDDD-CCCC-BBBBBBBBBBBB")!
            
            server = try await BleuServer(
                serviceUUID: serviceUUID,
                characteristicUUIDs: [sensorCharacteristicUUID],
                localName: "Temperature Sensor"
            )
            
            isRunning = true
            
            // Start simulation
            simulationTask = Task {
                while !Task.isCancelled {
                    let reading = SensorDataNotification(
                        temperature: Double.random(in: 18.0...28.0),
                        humidity: Double.random(in: 40.0...70.0)
                    )
                    
                    do {
                        try await server?.broadcast(reading, characteristicUUID: sensorCharacteristicUUID)
                        
                        await MainActor.run {
                            self.sensorReadings.append(reading)
                            self.lastSensorReading = reading
                            
                            // Keep only last 20 readings
                            if self.sensorReadings.count > 20 {
                                self.sensorReadings.removeFirst()
                            }
                        }
                    } catch {
                        print("Broadcast failed: \(error)")
                    }
                    
                    try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 seconds
                }
            }
            
        } catch {
            print("Failed to start simulation: \(error)")
        }
        
        isLoading = false
    }
    
    func stopSimulation() async {
        simulationTask?.cancel()
        await server?.shutdown()
        server = nil
        isRunning = false
        sensorReadings.removeAll()
        lastSensorReading = nil
    }
}

#Preview {
    ContentView()
}