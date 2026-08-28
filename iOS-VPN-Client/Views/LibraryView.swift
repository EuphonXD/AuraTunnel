import SwiftUI
import UIKit

struct LibraryView: View {
    @EnvironmentObject private var vpnManager: VPNManager
    @EnvironmentObject private var importCoordinator: NodeImportCoordinator
    @EnvironmentObject private var connectivityTester: NodeConnectivityTester
    @State private var deletionSubscription: SubscriptionProfile?

    let onScan: () -> Void

    var body: some View {
        ZStack {
            AuraScreenBackground()

            ScrollView {
                VStack(spacing: 22) {
                    if let failure = importCoordinator.lastImportFailure {
                        importFailure(failure)
                    }
                    if let report = importCoordinator.lastImportReport {
                        importStatus(report)
                    }
                    importPanel
                    subscriptionSection
                    protocolSection
                    externalImportCard
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            }
        }
        .navigationTitle("节点库")
        .confirmationDialog(
            "删除订阅？",
            isPresented: Binding(
                get: { deletionSubscription != nil },
                set: { _ in }
            ),
            titleVisibility: .visible,
            presenting: deletionSubscription
        ) { subscription in
            Button("删除订阅及专属节点", role: .destructive) {
                deletionSubscription = nil
                let profileIDs = profileIDs(for: subscription)
                Task {
                    if await vpnManager.deleteSubscription(subscription) {
                        connectivityTester.forget(profileIDs: profileIDs)
                    }
                }
            }
            Button("取消", role: .cancel) {
                deletionSubscription = nil
            }
        } message: { subscription in
            Text("将删除“\(subscription.name)”及仅属于它的节点；共享节点会保留。")
        }
    }

    private var importPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            AuraSectionHeader(title: "导入入口", detail: "由你主动触发")

            HStack(spacing: 12) {
                importTile(
                    title: "扫码",
                    detail: "QR 节点或订阅",
                    symbol: "qrcode.viewfinder",
                    tint: AuraPalette.aqua,
                    action: onScan
                )

                pasteImportTile
            }
        }
        .padding(16)
        .auraCard()
    }

    private func importStatus(_ report: NodeImportReport) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            VStack(alignment: .leading, spacing: 2) {
                Text(report.isRefresh ? "最近刷新完成" : "最近导入完成")
                    .font(.subheadline.weight(.semibold))
                Text("\(report.title) · \(report.importedCount) 个节点已写入")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .auraCard(cornerRadius: 17)
    }

    private func importFailure(_ failure: NodeImportFailure) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text("最近一次导入失败")
                    .font(.subheadline.weight(.semibold))
                Text(failure.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
            Button {
                importCoordinator.clearImportFailure()
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭导入错误")
        }
        .padding(14)
        .auraCard(cornerRadius: 17)
    }

    @ViewBuilder
    private var subscriptionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            AuraSectionHeader(
                title: "订阅源",
                detail: vpnManager.subscriptions.isEmpty ? nil : "\(vpnManager.subscriptions.count) 个"
            )

            if vpnManager.subscriptions.isEmpty {
                AuraEmptyState(
                    symbol: "link.badge.plus",
                    title: "还没有订阅",
                    message: "sub:// 订阅导入后会保存在共享 Keychain，并在这里提供手动刷新。"
                )
                .auraCard()
            } else {
                VStack(spacing: 0) {
                    ForEach(vpnManager.subscriptions) { subscription in
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .fill(AuraPalette.ocean.opacity(0.12))
                                    .frame(width: 44, height: 44)
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                    .foregroundStyle(AuraPalette.ocean)
                            }

                            VStack(alignment: .leading, spacing: 4) {
                                Text(subscription.name)
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                                Text("\(subscription.nodeCount) 个节点 · \(subscription.sourceHost)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                Text("更新于 \(subscription.lastUpdatedAt.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }

                            Spacer(minLength: 0)

                            Button {
                                Task {
                                    await importCoordinator.refresh(subscription, using: vpnManager)
                                }
                            } label: {
                                Image(systemName: "arrow.clockwise")
                                    .frame(width: 38, height: 38)
                            }
                            .buttonStyle(.bordered)
                            .tint(AuraPalette.ocean)
                            .disabled(importCoordinator.isImporting)
                            .accessibilityLabel("刷新订阅 \(subscription.name)")

                            Menu {
                                Button("删除订阅及专属节点", systemImage: "trash", role: .destructive) {
                                    deletionSubscription = subscription
                                }
                            } label: {
                                Image(systemName: "ellipsis")
                                    .frame(width: 34, height: 38)
                                    .contentShape(Rectangle())
                            }
                            .foregroundStyle(.secondary)
                            .accessibilityLabel("管理订阅 \(subscription.name)")
                        }
                        .padding(14)

                        if subscription.id != vpnManager.subscriptions.last?.id {
                            Divider().padding(.leading, 70)
                        }
                    }
                }
                .auraCard()
            }
        }
    }

    private var protocolSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            AuraSectionHeader(title: "协议概览", detail: "共 \(vpnManager.profiles.count) 个节点")

            if vpnManager.profiles.isEmpty {
                Text("导入后会按协议自动归类，不会复制或修改原始节点 URI。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .auraCard()
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    ForEach(protocolCounts, id: \.protocolKind) { item in
                        HStack(spacing: 10) {
                            Image(systemName: "seal.fill")
                                .foregroundStyle(AuraPalette.aqua)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.protocolKind.displayName)
                                    .font(.caption.weight(.semibold))
                                Text("\(item.count) 个")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .padding(13)
                        .auraCard(cornerRadius: 16)
                    }
                }
            }
        }
    }

    private var externalImportCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            AuraSectionHeader(title: "外部调用")
            Text("其他 App 或网页可以唤起 AuraTunnel，再由你确认后导入。")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Text("auratunnel://import?url=…")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(AuraPalette.ocean)
                    .lineLimit(1)
                Spacer()
                Button {
                    UIPasteboard.general.string = "auratunnel://import?url="
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .accessibilityLabel("复制外部导入格式")
            }
            .padding(12)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))

            Text("支持 ss、socks5、vmess、vless、trojan、hysteria2 及 sub 订阅。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .auraCard()
    }

    private func importTile(
        title: String,
        detail: String,
        symbol: String,
        tint: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: symbol)
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(tint)
                Text(LocalizedStringKey(title))
                    .font(.headline)
                    .foregroundStyle(.primary)
                Text(LocalizedStringKey(detail))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(15)
            .background(tint.opacity(0.09), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(importCoordinator.isImporting)
    }

    private var pasteImportTile: some View {
        VStack(alignment: .leading, spacing: 10) {
            PasteButton(payloadType: String.self) { values in
                importCoordinator.receive(payload: values.first)
            }
            .labelStyle(.titleAndIcon)
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(.indigo)
            .disabled(importCoordinator.isImporting)

            Text("从剪贴板导入")
                .font(.headline)
            Text("由 iOS 安全粘贴")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(15)
        .background(Color.indigo.opacity(0.09), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    private var protocolCounts: [(protocolKind: ProxyProtocolKind, count: Int)] {
        ProxyProtocolKind.allCases.compactMap { protocolKind in
            let count = vpnManager.profiles.lazy.filter { $0.proxyProtocol == protocolKind }.count
            return count == 0 ? nil : (protocolKind, count)
        }
    }

    private func profileIDs(for subscription: SubscriptionProfile) -> Set<UUID> {
        if let nodeIDs = subscription.nodeIDs {
            return Set(nodeIDs)
        }
        return vpnManager.subscriptions.count == 1
            ? Set(vpnManager.profiles.map(\.id))
            : []
    }
}
