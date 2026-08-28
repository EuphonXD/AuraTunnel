import Charts
import SwiftUI

struct ActivityView: View {
    @EnvironmentObject private var vpnManager: VPNManager
    @EnvironmentObject private var connectivityTester: NodeConnectivityTester
    @State private var runtimeSnapshot = TunnelRuntimeSnapshot.inactive
    @State private var isRefreshing = false

    var body: some View {
        ZStack {
            AuraScreenBackground()

            ScrollView {
                VStack(spacing: 22) {
                    connectivitySummary
                    latencyChartCard
                    runtimeCard
                    dataBoundaryCard
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle("活动")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await refreshRuntime() }
                } label: {
                    if isRefreshing {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                }
                .disabled(isRefreshing)
                .accessibilityLabel("刷新运行数据")
            }
        }
        .task {
            await refreshRuntime()
        }
        .onChange(of: vpnManager.status) { _ in
            Task { await refreshRuntime() }
        }
    }

    private var connectivitySummary: some View {
        VStack(alignment: .leading, spacing: 14) {
            AuraSectionHeader(title: "端点检测", detail: "用户触发的最近结果")

            HStack(spacing: 10) {
                summaryMetric(
                    title: "可达",
                    value: "\(reachableCount)",
                    symbol: "checkmark.circle.fill",
                    tint: .green
                )
                summaryMetric(
                    title: "失败",
                    value: "\(failedCount)",
                    symbol: "xmark.circle.fill",
                    tint: .red
                )
                summaryMetric(
                    title: "未测试",
                    value: "\(untestedCount)",
                    symbol: "minus.circle.fill",
                    tint: .secondary
                )
            }
        }
    }

    private var latencyChartCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            AuraSectionHeader(
                title: "握手延迟",
                detail: latencySamples.isEmpty ? nil : "平均 \(averageLatency) ms"
            )

            if latencySamples.isEmpty {
                AuraEmptyState(
                    symbol: "chart.bar.xaxis",
                    title: "还没有测速数据",
                    message: "回到连接页测试单个节点或全部节点，这里只展示真实测量结果。"
                )
            } else {
                Chart(latencySamples.prefix(10)) { sample in
                    BarMark(
                        x: .value("延迟", sample.milliseconds),
                        y: .value("节点", sample.shortName)
                    )
                    .foregroundStyle(AuraPalette.aqua)
                    .cornerRadius(5)
                    .annotation(position: .trailing) {
                        Text("\(sample.milliseconds)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                .chartXAxisLabel("毫秒")
                .frame(height: CGFloat(max(180, min(latencySamples.count, 10) * 34)))
                .padding(.trailing, 20)
            }
        }
        .padding(16)
        .auraCard()
    }

    private var runtimeCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            AuraSectionHeader(title: "Network Extension", detail: runtimeSnapshot.updatedAt.formatted(date: .omitted, time: .shortened))

            HStack(spacing: 12) {
                Image(systemName: runtimeSymbol)
                    .font(.title2)
                    .foregroundStyle(runtimeTint)
                    .frame(width: 48, height: 48)
                    .background(runtimeTint.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))

                VStack(alignment: .leading, spacing: 3) {
                    Text(runtimeTitle)
                        .font(.headline)
                    Text(runtimeSnapshot.message ?? "没有活动中的隧道会话")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    Text(runtimeBuildDetail)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                }
                Spacer()
            }

            Divider()

            HStack {
                runtimeMetric(title: "数据包", value: "\(runtimeSnapshot.packetCount)")
                Divider().frame(height: 36)
                runtimeMetric(title: "流量", value: formattedBytes(runtimeSnapshot.byteCount))
            }
        }
        .padding(16)
        .auraCard()
    }

    private var dataBoundaryCard: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .foregroundStyle(AuraPalette.aqua)
            VStack(alignment: .leading, spacing: 4) {
                Text("本机活动数据")
                    .font(.subheadline.weight(.semibold))
                Text("当前页面不上传流量记录，也不会编造历史图表。运行统计只通过用户触发的低频 IPC 获取。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .auraCard()
    }

    private func summaryMetric(title: String, value: String, symbol: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Image(systemName: symbol)
                .foregroundStyle(tint)
            Text(value)
                .font(.title2.weight(.bold))
            Text(LocalizedStringKey(title))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .auraCard(cornerRadius: 17)
    }

    private func runtimeMetric(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value)
                .font(.headline.monospacedDigit())
            Text(LocalizedStringKey(title))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func refreshRuntime() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        runtimeSnapshot = await vpnManager.requestRuntimeSnapshot()
        isRefreshing = false
    }

    private var latencySamples: [LatencySample] {
        vpnManager.profiles.compactMap { profile in
            guard case .reachable(let milliseconds) = connectivityTester.state(for: profile.id) else {
                return nil
            }
            return LatencySample(id: profile.id, name: profile.name, milliseconds: milliseconds)
        }
        .sorted { $0.milliseconds < $1.milliseconds }
    }

    private var reachableCount: Int {
        connectivityTester.results.values.lazy.filter {
            if case .reachable = $0 { return true }
            return false
        }.count
    }

    private var failedCount: Int {
        connectivityTester.results.values.lazy.filter {
            switch $0 {
            case .failed, .timedOut: true
            default: false
            }
        }.count
    }

    private var untestedCount: Int {
        max(0, vpnManager.profiles.count - connectivityTester.results.count)
    }

    private var averageLatency: Int {
        guard !latencySamples.isEmpty else { return 0 }
        return latencySamples.map(\.milliseconds).reduce(0, +) / latencySamples.count
    }

    private var runtimeTitle: String {
        switch runtimeSnapshot.state {
        case .inactive: "扩展未运行"
        case .preparing: "正在准备"
        case .connected: "扩展已连接"
        case .stopping: "正在停止"
        case .failed: "扩展启动失败"
        }
    }

    private var runtimeSymbol: String {
        switch runtimeSnapshot.state {
        case .connected: "bolt.horizontal.circle.fill"
        case .failed: "exclamationmark.shield.fill"
        default: "moon.zzz.fill"
        }
    }

    private var runtimeTint: Color {
        switch runtimeSnapshot.state {
        case .connected: .green
        case .failed: .orange
        default: .secondary
        }
    }

    private var runtimeBuildDetail: String {
        let appBuild = runtimeSnapshot.appBuild
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String)
            ?? "?"
        return "App \(appBuild) · PacketTunnel \(runtimeSnapshot.extensionBuild ?? "尚未启动")"
    }

    private func formattedBytes(_ value: UInt64) -> String {
        let safeValue = Int64(min(value, UInt64(Int64.max)))
        return ByteCountFormatter.string(fromByteCount: safeValue, countStyle: .file)
    }
}

private struct LatencySample: Identifiable {
    let id: UUID
    let name: String
    let milliseconds: Int

    var shortName: String {
        String(name.prefix(12))
    }
}
