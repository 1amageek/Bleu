import SwiftUI
import Bleu

struct E2ERootView: View {
    @ObservedObject var model: E2EViewModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    StatusHeader(model: model)
                    RoleControl(model: model)

                    switch model.role {
                    case .peripheral:
                        PeripheralPanel(model: model)
                    case .central:
                        CentralPanel(model: model)
                    }

                    ResultPanel(results: model.testResults)
                    DiagnosticsPanel(metrics: model.diagnosticMetrics)
                    LogPanel(entries: model.logEntries)
                }
                .padding()
            }
            .navigationTitle("Bleu E2E")
        }
        .task {
            await model.runLaunchAutomationIfNeeded()
        }
    }
}

private struct StatusHeader: View {
    @ObservedObject var model: E2EViewModel

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: iconName)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 36, height: 36)

            VStack(alignment: .leading, spacing: 4) {
                Text(model.phase.rawValue)
                    .font(.headline)
                Text(E2EPlatform.name)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if model.isBusy {
                ProgressView()
            }
        }
        .padding()
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var iconName: String {
        switch model.phase {
        case .passed:
            return "checkmark.seal.fill"
        case .failed:
            return "xmark.octagon.fill"
        case .advertising:
            return "antenna.radiowaves.left.and.right"
        case .scanning:
            return "dot.radiowaves.left.and.right"
        case .connected:
            return "link"
        case .running:
            return "arrow.triangle.2.circlepath"
        case .idle:
            return "circle"
        }
    }

    private var color: Color {
        switch model.phase {
        case .passed:
            return .green
        case .failed:
            return .red
        case .advertising, .scanning, .connected, .running:
            return .blue
        case .idle:
            return .secondary
        }
    }
}

private struct RoleControl: View {
    @ObservedObject var model: E2EViewModel

    var body: some View {
        Picker("Role", selection: $model.role) {
            ForEach(E2ERole.allCases) { role in
                Text(role.title).tag(role)
            }
        }
        .pickerStyle(.segmented)
        .disabled(model.isBusy || model.phase == .advertising || model.phase == .running)
    }
}

private struct PeripheralPanel: View {
    @ObservedObject var model: E2EViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Peripheral", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.headline)
                Spacer()
                Button {
                    Task {
                        if model.phase == .advertising {
                            await model.stopPeripheral()
                        } else {
                            await model.startPeripheral()
                        }
                    }
                } label: {
                    Label(model.phase == .advertising ? "Stop" : "Advertise", systemImage: model.phase == .advertising ? "stop.fill" : "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy)
            }

            InfoRow(label: "Actor", value: model.localActorID?.e2eShortID ?? "-")
            InfoRow(label: "Service", value: "E2EPeripheral")
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct CentralPanel: View {
    @ObservedObject var model: E2EViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Central", systemImage: "dot.radiowaves.left.and.right")
                    .font(.headline)
                Spacer()
                Button {
                    if model.phase == .scanning {
                        model.stopScan()
                    } else {
                        model.startScan()
                    }
                } label: {
                    Label(model.phase == .scanning ? "Stop" : "Scan", systemImage: model.phase == .scanning ? "stop.fill" : "magnifyingglass")
                }
                .buttonStyle(.bordered)
                .disabled(model.isBusy && model.phase != .scanning)

                Button {
                    Task {
                        await model.runSelectedE2E()
                    }
                } label: {
                    Label("Run", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy)
            }

            if model.discoveredPeers.isEmpty {
                Text("No peers")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Peer", selection: $model.selectedPeerID) {
                    ForEach(model.discoveredPeers) { peer in
                        Text(peer.title).tag(Optional(peer.id))
                    }
                }
                .pickerStyle(.menu)

                Button {
                    Task {
                        await model.disconnectSelectedPeer()
                    }
                } label: {
                    Label("Disconnect", systemImage: "link.badge.minus")
                }
                .buttonStyle(.bordered)
                .disabled(model.selectedPeerID == nil || model.isBusy)
            }
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct ResultPanel: View {
    let results: [E2ETestResult]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Results", systemImage: "checklist")
                .font(.headline)

            if results.isEmpty {
                Text("No results")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(results) { result in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: iconName(for: result.status))
                            .foregroundStyle(color(for: result.status))
                            .frame(width: 20)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(result.name)
                                .font(.subheadline)
                            Text(result.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(result.duration.formatted(.number.precision(.fractionLength(3))) + "s")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func iconName(for status: E2ETestStatus) -> String {
        switch status {
        case .pending:
            return "circle"
        case .passed:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.circle.fill"
        }
    }

    private func color(for status: E2ETestStatus) -> Color {
        switch status {
        case .pending:
            return .secondary
        case .passed:
            return .green
        case .failed:
            return .red
        }
    }
}

private struct DiagnosticsPanel: View {
    let metrics: BleuDiagnosticMetrics?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Diagnostics", systemImage: "waveform.path.ecg")
                .font(.headline)
            InfoRow(label: "Rejected packets", value: "\(metrics?.transportPacketsRejected ?? 0)")
            InfoRow(label: "Decode failures", value: "\(decodeFailures)")
            InfoRow(label: "Queue drops", value: "\(metrics?.incomingRPCQueueDrops ?? 0)")
            InfoRow(label: "ATT unmatched", value: "\(metrics?.attErrorsUnmatched ?? 0)")
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var decodeFailures: Int {
        guard let metrics else { return 0 }
        return metrics.responseEnvelopeDecodeFailures + metrics.incomingInvocationDecodeFailures
    }
}

private struct LogPanel: View {
    let entries: [E2ELogEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Log", systemImage: "list.bullet.rectangle")
                .font(.headline)

            if entries.isEmpty {
                Text("No log entries")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(entries) { entry in
                    HStack(alignment: .firstTextBaseline) {
                        Text(entry.timestamp, style: .time)
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 72, alignment: .leading)
                        Text(entry.message)
                            .font(.caption)
                    }
                }
            }
        }
        .padding()
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct InfoRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
    }
}

#Preview {
    E2ERootView(model: E2EViewModel())
}
