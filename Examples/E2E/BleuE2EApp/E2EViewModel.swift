import Foundation
import Bleu

@MainActor
final class E2EViewModel: ObservableObject {
    @Published var role: E2ERole = E2EPlatform.defaultRole
    @Published var phase: E2EPhase = .idle
    @Published var isBusy = false
    @Published var localActorID: UUID?
    @Published var discoveredPeers: [E2EPeer] = []
    @Published var selectedPeerID: UUID?
    @Published var testResults: [E2ETestResult] = []
    @Published var diagnosticMetrics: BleuDiagnosticMetrics?
    @Published var logEntries: [E2ELogEntry] = []

    private let actorSystem = BLEActorSystem.shared
    private var localPeripheral: E2EPeripheral?
    private var remotePeripherals: [UUID: E2EPeripheral] = [:]
    private var scanTask: Task<Void, Never>?
    private var diagnosticTask: Task<Void, Never>?
    private let launchConfiguration: E2ELaunchConfiguration
    private var didRunLaunchAutomation = false

    init(launchConfiguration: E2ELaunchConfiguration = .parse()) {
        self.launchConfiguration = launchConfiguration
        if let role = launchConfiguration.role {
            self.role = role
        }
        startDiagnosticStream()
    }

    deinit {
        scanTask?.cancel()
        diagnosticTask?.cancel()
    }

    func startPeripheral() async {
        guard !isBusy else { return }
        isBusy = true
        defer { isBusy = false }

        guard await waitForActorSystemReady() else {
            phase = .failed
            appendLog("Failed to start advertising: actor system was not ready")
            await refreshDiagnostics()
            return
        }

        do {
            let peripheral = E2EPeripheral(
                actorSystem: actorSystem,
                serverName: "\(E2EPlatform.name) E2E Peripheral"
            )
            try await actorSystem.startAdvertising(peripheral)
            localPeripheral = peripheral
            localActorID = peripheral.id
            phase = .advertising
            appendLog("Advertising started as \(peripheral.id.e2eShortID)")
        } catch {
            phase = .failed
            appendLog("Failed to start advertising: \(String(describing: error))")
        }

        await refreshDiagnostics()
    }

    func stopPeripheral() async {
        await actorSystem.stopAdvertising()
        localPeripheral = nil
        localActorID = nil
        phase = .idle
        appendLog("Advertising stopped")
        await refreshDiagnostics()
    }

    func startScan() {
        guard !isBusy else { return }
        scanTask?.cancel()
        scanTask = Task { [weak self] in
            guard let self else { return }
            await self.scanForPeers()
        }
    }

    func stopScan() {
        scanTask?.cancel()
        scanTask = nil
        if phase == .scanning {
            phase = discoveredPeers.isEmpty ? .idle : .connected
        }
        appendLog("Scan stopped")
    }

    func runSelectedE2E() async {
        isBusy = true
        phase = .running
        testResults.removeAll()
        defer { isBusy = false }

        let runID = UUID()
        let totalIterations = max(1, launchConfiguration.iterations)
        let payloadSizes = launchConfiguration.payloadSizes
        let expectedBytesPerIteration = payloadSizes.reduce(0, +)
        appendLog(
            "E2E run \(runID.e2eShortID) started with \(totalIterations) iteration(s), payloads \(payloadSizes)"
        )

        for iteration in 1...totalIterations {
            if selectedPeerID == nil || (launchConfiguration.reconnectBetweenIterations && iteration > 1) {
                await scanForPeersUntilMinimumCount()
            }

            guard discoveredPeers.count >= launchConfiguration.minimumPeerCount else {
                phase = .failed
                appendResult(
                    name: resultName("Peer count", iteration: iteration, totalIterations: totalIterations),
                    status: .failed,
                    detail: "Expected at least \(launchConfiguration.minimumPeerCount), found \(discoveredPeers.count)",
                    duration: 0
                )
                appendLog("E2E aborted: minimum peer count was not met")
                break
            }

            guard let peerID = selectedPeerID, let peripheral = remotePeripherals[peerID] else {
                phase = .failed
                appendResult(
                    name: resultName("Peer discovery", iteration: iteration, totalIterations: totalIterations),
                    status: .failed,
                    detail: "No E2E peripheral found",
                    duration: 0
                )
                appendLog("E2E aborted: no peer")
                break
            }

            phase = .running
            appendLog("Iteration \(iteration) started against \(peerID.e2eShortID)")

            await runHandshake(
                peripheral: peripheral,
                runID: runID,
                iteration: iteration,
                totalIterations: totalIterations
            )

            for (offset, size) in payloadSizes.enumerated() {
                await runEcho(
                    peripheral: peripheral,
                    runID: runID,
                    sequence: ((iteration - 1) * payloadSizes.count) + offset + 1,
                    size: size,
                    iteration: iteration,
                    totalIterations: totalIterations
                )
            }

            await runMetricsCheck(
                peripheral: peripheral,
                expectedHandshakes: iteration,
                expectedEchoes: iteration * payloadSizes.count,
                expectedBytes: iteration * expectedBytesPerIteration,
                iteration: iteration,
                totalIterations: totalIterations
            )

            if launchConfiguration.reconnectBetweenIterations && iteration < totalIterations {
                await runDisconnectForReconnect(iteration: iteration, totalIterations: totalIterations)
            }
        }

        let failed = testResults.contains { $0.status == .failed }
        phase = failed ? .failed : .passed
        appendLog(failed ? "E2E run failed" : "E2E run passed")
        await refreshDiagnostics()
    }

    func disconnectSelectedPeer() async {
        guard let peerID = selectedPeerID else { return }

        do {
            try await actorSystem.disconnect(from: peerID)
            remotePeripherals.removeValue(forKey: peerID)
            discoveredPeers.removeAll { $0.id == peerID }
            selectedPeerID = discoveredPeers.first?.id
            phase = discoveredPeers.isEmpty ? .idle : .connected
            appendLog("Disconnected \(peerID.e2eShortID)")
        } catch {
            phase = .failed
            appendLog("Disconnect failed: \(String(describing: error))")
        }

        await refreshDiagnostics()
    }

    func refreshDiagnostics() async {
        diagnosticMetrics = await actorSystem.diagnosticMetrics()
    }

    func runLaunchAutomationIfNeeded() async {
        guard launchConfiguration.hasAutomation, !didRunLaunchAutomation else {
            return
        }

        didRunLaunchAutomation = true

        if let role = launchConfiguration.role {
            self.role = role
        }

        if launchConfiguration.startsPeripheral {
            await startPeripheral()
        }

        if launchConfiguration.runsCentral {
            await runSelectedE2E()
            await writeRunSummaryIfNeeded()
            exitIfRequested()
        }
    }

    private func scanForPeers() async {
        isBusy = true
        phase = .scanning
        discoveredPeers.removeAll()
        remotePeripherals.removeAll()
        selectedPeerID = nil
        appendLog("Scanning for E2E peripherals")

        guard await waitForActorSystemReady() else {
            phase = .failed
            appendLog("Scan failed: actor system was not ready")
            isBusy = false
            await refreshDiagnostics()
            return
        }

        do {
            let peripherals = try await actorSystem.discover(
                E2EPeripheral.self,
                timeout: launchConfiguration.scanTimeout
            )
            for peripheral in peripherals {
                remotePeripherals[peripheral.id] = peripheral
                discoveredPeers.append(E2EPeer(
                    id: peripheral.id,
                    title: "E2E Peripheral \(peripheral.id.e2eShortID)"
                ))
            }
            selectedPeerID = discoveredPeers.first?.id
            phase = discoveredPeers.isEmpty ? .idle : .connected
            appendLog("Scan completed with \(discoveredPeers.count) peer(s)")
        } catch {
            phase = .failed
            appendLog("Scan failed: \(String(describing: error))")
        }

        isBusy = false
        await refreshDiagnostics()
    }

    private func scanForPeersUntilMinimumCount() async {
        for attempt in 1...launchConfiguration.scanAttempts {
            await scanForPeers()
            if discoveredPeers.count >= launchConfiguration.minimumPeerCount {
                return
            }

            guard attempt < launchConfiguration.scanAttempts else {
                return
            }

            appendLog(
                "Scan attempt \(attempt) found \(discoveredPeers.count) peer(s); retrying"
            )

            do {
                try await Task.sleep(nanoseconds: 500_000_000)
            } catch {
                appendLog("Scan retry delay was cancelled")
                return
            }
        }
    }

    private func runHandshake(
        peripheral: E2EPeripheral,
        runID: UUID,
        iteration: Int,
        totalIterations: Int
    ) async {
        let start = Date()
        do {
            let response = try await peripheral.handshake(E2EHandshakeRequest(
                runID: runID,
                clientPlatform: E2EPlatform.name,
                startedAt: start
            ))
            let passed = response.runID == runID && response.peripheralID == peripheral.id
            appendResult(
                name: resultName("Handshake", iteration: iteration, totalIterations: totalIterations),
                status: passed ? .passed : .failed,
                detail: "\(response.serverName) on \(response.serverPlatform)",
                duration: Date().timeIntervalSince(start)
            )
        } catch {
            appendResult(
                name: resultName("Handshake", iteration: iteration, totalIterations: totalIterations),
                status: .failed,
                detail: String(describing: error),
                duration: Date().timeIntervalSince(start)
            )
        }
    }

    private func runEcho(
        peripheral: E2EPeripheral,
        runID: UUID,
        sequence: Int,
        size: Int,
        iteration: Int,
        totalIterations: Int
    ) async {
        let start = Date()
        let payload = E2EPayload(
            runID: runID,
            sequence: sequence,
            bytes: deterministicPayload(size: size),
            sentAt: start
        )

        do {
            let response = try await peripheral.echo(payload)
            appendResult(
                name: resultName("Echo \(size)B", iteration: iteration, totalIterations: totalIterations),
                status: response == payload ? .passed : .failed,
                detail: response == payload ? "Payload matched" : "Payload mismatch",
                duration: Date().timeIntervalSince(start)
            )
        } catch {
            appendResult(
                name: resultName("Echo \(size)B", iteration: iteration, totalIterations: totalIterations),
                status: .failed,
                detail: String(describing: error),
                duration: Date().timeIntervalSince(start)
            )
        }
    }

    private func runMetricsCheck(
        peripheral: E2EPeripheral,
        expectedHandshakes: Int,
        expectedEchoes: Int,
        expectedBytes: Int,
        iteration: Int,
        totalIterations: Int
    ) async {
        let start = Date()
        do {
            let metrics = try await peripheral.metrics()
            let passed =
                metrics.handshakeCount >= expectedHandshakes
                && metrics.echoCount >= expectedEchoes
                && metrics.bytesReceived >= expectedBytes
            appendResult(
                name: resultName("Remote metrics", iteration: iteration, totalIterations: totalIterations),
                status: passed ? .passed : .failed,
                detail: "\(metrics.handshakeCount) handshake(s), \(metrics.echoCount) echo(s), \(metrics.bytesReceived)B",
                duration: Date().timeIntervalSince(start)
            )
        } catch {
            appendResult(
                name: resultName("Remote metrics", iteration: iteration, totalIterations: totalIterations),
                status: .failed,
                detail: String(describing: error),
                duration: Date().timeIntervalSince(start)
            )
        }
    }

    private func runDisconnectForReconnect(iteration: Int, totalIterations: Int) async {
        let start = Date()
        guard let peerID = selectedPeerID else {
            appendResult(
                name: resultName("Disconnect", iteration: iteration, totalIterations: totalIterations),
                status: .failed,
                detail: "No connected peer",
                duration: 0
            )
            return
        }

        do {
            try await actorSystem.disconnect(from: peerID)
            remotePeripherals.removeValue(forKey: peerID)
            discoveredPeers.removeAll { $0.id == peerID }
            selectedPeerID = nil
            phase = .idle
            appendResult(
                name: resultName("Disconnect", iteration: iteration, totalIterations: totalIterations),
                status: .passed,
                detail: "Disconnected \(peerID.e2eShortID)",
                duration: Date().timeIntervalSince(start)
            )
            appendLog("Disconnected \(peerID.e2eShortID) before reconnect")

            do {
                try await Task.sleep(nanoseconds: 500_000_000)
            } catch {
                appendLog("Reconnect delay was cancelled")
            }
        } catch {
            phase = .failed
            appendResult(
                name: resultName("Disconnect", iteration: iteration, totalIterations: totalIterations),
                status: .failed,
                detail: String(describing: error),
                duration: Date().timeIntervalSince(start)
            )
            appendLog("Disconnect before reconnect failed: \(String(describing: error))")
        }
    }

    private func deterministicPayload(size: Int) -> Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(size)
        for index in 0..<size {
            bytes.append(UInt8(index % 251))
        }
        return Data(bytes)
    }

    private func waitForActorSystemReady() async -> Bool {
        let deadline = Date().addingTimeInterval(launchConfiguration.readinessTimeout)

        while Date() < deadline {
            if await actorSystem.ready {
                return true
            }

            do {
                try await Task.sleep(nanoseconds: 100_000_000)
            } catch {
                return false
            }
        }

        return await actorSystem.ready
    }

    private func appendResult(name: String, status: E2ETestStatus, detail: String, duration: TimeInterval) {
        testResults.append(E2ETestResult(
            name: name,
            status: status,
            detail: detail,
            duration: duration
        ))
    }

    private func appendLog(_ message: String) {
        logEntries.insert(E2ELogEntry(timestamp: Date(), message: message), at: 0)
        print("[BleuE2E] \(message)")
        if logEntries.count > 30 {
            logEntries.removeLast(logEntries.count - 30)
        }
    }

    private func resultName(_ baseName: String, iteration: Int, totalIterations: Int) -> String {
        guard totalIterations > 1 else {
            return baseName
        }

        return "\(baseName) [\(iteration)/\(totalIterations)]"
    }

    private func startDiagnosticStream() {
        diagnosticTask = Task { [weak self] in
            guard let self else { return }
            for await _ in self.actorSystem.diagnosticEvents {
                await self.refreshDiagnostics()
            }
        }
    }

    private func writeRunSummaryIfNeeded() async {
        guard let resultPath = launchConfiguration.resultPath else {
            return
        }

        let summary = E2ERunSummary(
            phase: phase.rawValue,
            passed: phase == .passed,
            configuration: E2ERunSummary.ConfigurationSummary(
                platform: E2EPlatform.name,
                role: role.rawValue,
                iterations: launchConfiguration.iterations,
                payloadSizes: launchConfiguration.payloadSizes,
                reconnectBetweenIterations: launchConfiguration.reconnectBetweenIterations,
                minimumPeerCount: launchConfiguration.minimumPeerCount,
                scanTimeout: launchConfiguration.scanTimeout,
                scanAttempts: launchConfiguration.scanAttempts,
                readinessTimeout: launchConfiguration.readinessTimeout
            ),
            results: testResults.map {
                E2ERunSummary.ResultSummary(
                    name: $0.name,
                    status: $0.status.rawValue,
                    detail: $0.detail,
                    duration: $0.duration
                )
            },
            logs: logEntries.map {
                E2ERunSummary.LogSummary(
                    timestamp: $0.timestamp,
                    message: $0.message
                )
            },
            diagnostics: diagnosticMetrics
        )

        do {
            let data = try JSONEncoder().encode(summary)
            let url = try resultURL(for: resultPath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: .atomic)
            appendLog("Wrote result summary to \(url.path)")
        } catch {
            appendLog("Failed to write result summary: \(String(describing: error))")
        }
    }

    private func resultURL(for path: String) throws -> URL {
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }

        let documents = try FileManager.default.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return documents.appendingPathComponent(path)
    }

    private func exitIfRequested() {
        guard launchConfiguration.exitsAfterRun else {
            return
        }

        let exitCode: Int32 = phase == .passed ? 0 : 1
        Task {
            try await Task.sleep(nanoseconds: 500_000_000)
            Foundation.exit(exitCode)
        }
    }
}
