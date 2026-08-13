import Charts
import SwiftUI

struct RuntimeActivityDestinationView: View {
    let destination: AppDestination
    let lifecycle: BackendLifecycleModel

    var body: some View {
        switch destination {
        case .connections: ConnectionsView(lifecycle: lifecycle)
        case .traffic: TrafficView(lifecycle: lifecycle)
        case .logs: LogsView(lifecycle: lifecycle)
        case .dashboard, .profiles: EmptyView()
        }
    }
}

struct ConnectionsView: View {
    @Bindable var lifecycle: BackendLifecycleModel

    var body: some View {
        VStack(spacing: 0) {
            TargetPageHeader("connections.title", subtitleKey: "connections.subtitle")
                .frame(maxWidth: TargetUI.pageContentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, TargetUI.pagePadding)
                .padding(.top, TargetUI.pagePadding)
                .padding(.bottom, 16)
            content
        }
        .navigationTitle("connections.title")
        .task { lifecycle.setConnectionObservationActive(true) }
        .onDisappear { lifecycle.setConnectionObservationActive(false) }
    }

    @ViewBuilder
    private var content: some View {
        switch lifecycle.runtimeConnections.state {
        case .available where lifecycle.runtimeConnections.connections.isEmpty:
            ActivityStateView(symbol: "point.3.connected.trianglepath.dotted", titleKey: "connections.empty.title", messageKey: "connections.empty.message")
        case .available:
            Table(lifecycle.runtimeConnections.connections) {
                TableColumn("connections.column.destination") { connection in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(connection.destination.isEmpty ? "—" : connection.destination)
                            .lineLimit(1)
                        if let port = connection.destinationPort {
                            Text(":\(port)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .width(min: 180, ideal: 260)
                TableColumn("connections.column.network") { connection in
                    Text([connection.network, connection.inbound].compactMap { $0 }.joined(separator: " · "))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .width(min: 120, ideal: 170)
                TableColumn("connections.column.route") { connection in
                    Text(connection.outboundChain.joined(separator: " → ").isEmpty ? (connection.rule ?? "—") : connection.outboundChain.joined(separator: " → "))
                        .lineLimit(1)
                }
                .width(min: 150, ideal: 220)
                TableColumn("connections.column.traffic") { connection in
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("↑ \(connection.uploadBytes.map { RuntimeByteFormatter.format(bytes: Double($0)) } ?? "—")")
                        Text("↓ \(connection.downloadBytes.map { RuntimeByteFormatter.format(bytes: Double($0)) } ?? "—")")
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
                .width(min: 115, ideal: 130)
                TableColumn("connections.column.started") { connection in
                    if let startedAt = connection.startedAt {
                        Text(startedAt, format: .dateTime.hour().minute().second())
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    } else {
                        Text("—")
                            .foregroundStyle(.secondary)
                    }
                }
                .width(min: 90, ideal: 100)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: true))
            .frame(minHeight: 340)
        case .stopped:
            ActivityStateView(symbol: "bolt.slash", titleKey: "activity.stopped.title", messageKey: "connections.stopped.message")
        case .loading:
            ActivityLoadingView(messageKey: "connections.loading.message")
        case .unavailable:
            ActivityStateView(symbol: "exclamationmark.triangle", titleKey: "activity.unavailable.title", messageKey: "connections.unavailable.message")
        }
    }
}

struct TrafficView: View {
    @Bindable var lifecycle: BackendLifecycleModel

    private var observation: RuntimeObservationPresentation {
        .init(observation: lifecycle.runtimeObservation)
    }

    var body: some View {
        TargetPageLayout {
            TargetPageHeader("traffic.title", subtitleKey: "traffic.subtitle")
            switch lifecycle.runtimeObservation.state {
            case .available:
                metricGrid
                trafficChart
            case .stopped:
                ActivityStateView(symbol: "bolt.slash", titleKey: "activity.stopped.title", messageKey: "traffic.stopped.message")
            case .loading:
                ActivityLoadingView(messageKey: "traffic.loading.message")
            case .unavailable:
                ActivityStateView(symbol: "exclamationmark.triangle", titleKey: "activity.unavailable.title", messageKey: "traffic.unavailable.message")
            }
        }
        .frame(minWidth: 500, minHeight: 460)
        .navigationTitle("traffic.title")
    }

    private var metricGrid: some View {
        Grid(horizontalSpacing: 18, verticalSpacing: 18) {
            GridRow {
                TrafficMetric(titleKey: "traffic.upload-rate", value: observation.uploadRate)
                TrafficMetric(titleKey: "traffic.download-rate", value: observation.downloadRate)
            }
            GridRow {
                TrafficMetric(titleKey: "traffic.uploaded-total", value: observation.uploadedTotal)
                TrafficMetric(titleKey: "traffic.downloaded-total", value: observation.downloadedTotal)
            }
            GridRow {
                TrafficMetric(titleKey: "traffic.active-connections", value: observation.activeConnections)
                TrafficMetric(titleKey: "traffic.observation-state", valueKey: observation.stateKey)
            }
        }
    }

    @ViewBuilder
    private var trafficChart: some View {
        TargetSectionTitle("traffic.history.title", systemImage: "chart.xyaxis.line")
        if lifecycle.trafficHistory.isEmpty {
            Text("traffic.history.empty")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 160, alignment: .center)
        } else {
            Chart(lifecycle.trafficHistory) { sample in
                LineMark(
                    x: .value("traffic.chart.time", sample.observedAt),
                    y: .value("traffic.chart.upload", sample.uploadBytesPerSecond),
                    series: .value("traffic.chart.direction", "upload")
                )
                .foregroundStyle(by: .value("traffic.chart.direction", "upload"))
                LineMark(
                    x: .value("traffic.chart.time", sample.observedAt),
                    y: .value("traffic.chart.download", sample.downloadBytesPerSecond),
                    series: .value("traffic.chart.direction", "download")
                )
                .foregroundStyle(by: .value("traffic.chart.direction", "download"))
            }
            .chartForegroundStyleScale(["upload": .orange, "download": .blue])
            .chartLegend(position: .bottom, alignment: .leading) {
                HStack(spacing: 14) {
                    Label("traffic.chart.upload", systemImage: "circle.fill").foregroundStyle(.orange)
                    Label("traffic.chart.download", systemImage: "circle.fill").foregroundStyle(.blue)
                }
                .font(.caption)
            }
            .chartYAxis { AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let rate = value.as(Double.self) {
                        Text(RuntimeByteFormatter.format(bytes: rate, suffix: "/s"))
                    }
                }
            } }
            .frame(height: 210)
            .accessibilityLabel(Text("traffic.history.title"))
        }
    }
}

struct LogsView: View {
    @Bindable var lifecycle: BackendLifecycleModel

    var body: some View {
        VStack(spacing: 0) {
            TargetPageHeader("logs.title", subtitleKey: "logs.subtitle")
                .frame(maxWidth: TargetUI.pageContentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, TargetUI.pagePadding)
                .padding(.top, TargetUI.pagePadding)
                .padding(.bottom, 16)
            content
        }
        .navigationTitle("logs.title")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("logs.clear", systemImage: "trash") { lifecycle.clearRuntimeLogs() }
                    .disabled(lifecycle.runtimeLogEntries.isEmpty)
                    .accessibilityLabel(Text("logs.clear"))
            }
        }
        .task { lifecycle.setLogObservationActive(true) }
        .onDisappear { lifecycle.setLogObservationActive(false) }
    }

    @ViewBuilder
    private var content: some View {
        switch lifecycle.runtimeLogState {
        case .available where lifecycle.runtimeLogEntries.isEmpty:
            ActivityStateView(symbol: "text.alignleft", titleKey: "logs.empty.title", messageKey: "logs.empty.message")
        case .available:
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lifecycle.runtimeLogEntries) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text(entry.timestamp, format: .dateTime.hour().minute().second())
                                .foregroundStyle(.secondary)
                            Text(LocalizedStringKey("logs.level.\(entry.level.rawValue)"))
                                .foregroundStyle(levelColor(entry.level))
                            Text(entry.message)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .font(.caption.monospaced())
                        .padding(.horizontal, TargetUI.pagePadding)
                        .padding(.vertical, 4)
                        .accessibilityElement(children: .combine)
                        Divider().padding(.leading, TargetUI.pagePadding)
                    }
                }
                .padding(.bottom, TargetUI.pagePadding)
            }
        case .stopped:
            ActivityStateView(symbol: "bolt.slash", titleKey: "activity.stopped.title", messageKey: "logs.stopped.message")
        case .loading:
            ActivityLoadingView(messageKey: "logs.loading.message")
        case .unavailable:
            ActivityStateView(symbol: "exclamationmark.triangle", titleKey: "activity.unavailable.title", messageKey: "logs.unavailable.message")
        }
    }

    private func levelColor(_ level: RuntimeLogLevel) -> Color {
        switch level {
        case .debug, .neutral: .secondary
        case .info: .blue
        case .warning: .orange
        case .error: .red
        }
    }
}

private struct TrafficMetric: View {
    let titleKey: String
    let value: String?
    let valueKey: String?

    init(titleKey: String, value: String? = nil, valueKey: String? = nil) {
        self.titleKey = titleKey
        self.value = value
        self.valueKey = valueKey
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(LocalizedStringKey(titleKey))
                .font(.callout)
                .foregroundStyle(.secondary)
            if let valueKey { Text(LocalizedStringKey(valueKey)).font(.title3.weight(.medium)) }
            else { Text(value ?? "—").font(.title3.monospacedDigit().weight(.medium)) }
        }
        .frame(maxWidth: .infinity, minHeight: 68, alignment: .leading)
        .padding(14)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: TargetUI.cardCornerRadius, style: .continuous))
    }
}

private struct ActivityLoadingView: View {
    let messageKey: String

    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text(LocalizedStringKey(messageKey)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(TargetUI.pagePadding)
    }
}

private struct ActivityStateView: View {
    let symbol: String
    let titleKey: String
    let messageKey: String

    var body: some View {
        ContentUnavailableView {
            Label(LocalizedStringKey(titleKey), systemImage: symbol)
        } description: {
            Text(LocalizedStringKey(messageKey))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(TargetUI.pagePadding)
    }
}
