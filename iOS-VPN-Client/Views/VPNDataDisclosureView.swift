import SwiftUI

/// Guideline 5.4 disclosure shown before the first use of the VPN feature.
/// It describes the actual data path without requesting any system permission.
struct VPNDataDisclosureView: View {
    @EnvironmentObject private var preferences: AppPreferences
    let onAccept: (() -> Void)?

    var body: some View {
        ZStack {
            AuraScreenBackground()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if onAccept != nil {
                        Picker("语言 / Language", selection: $preferences.language) {
                            ForEach(AppLanguage.allCases) { language in
                                Text(language.title).tag(language)
                            }
                        }
                        .pickerStyle(.segmented)
                        .accessibilityHint("立即切换本页和 App 的显示语言")
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Image(systemName: "network.badge.shield.half.filled")
                            .font(.system(size: 42, weight: .medium))
                            .foregroundStyle(AuraPalette.aqua)
                        Text("隐私政策与 VPN 数据说明")
                            .font(.largeTitle.bold())
                        Text("请在首次使用隧道前了解 AuraTunnel 如何处理网络数据。")
                            .foregroundStyle(.secondary)
                    }

                    disclosureRow(
                        symbol: "eye.slash.fill",
                        title: "开发者不收集 VPN 流量",
                        detail: "AuraTunnel 的开发者不收集、记录、出售或用于分析你的浏览历史、DNS 查询、流量内容、源 IP、目的地址或连接日志。App 不包含账号、广告、埋点或第三方分析 SDK。"
                    )
                    disclosureRow(
                        symbol: "arrow.triangle.branch",
                        title: "流量只为完成你选择的连接而转发",
                        detail: "Packet Tunnel 会在设备上实时处理流量，并将需要代理的流量发往你导入并选择的节点；直连流量发往目标网站或服务。开发者不提供、控制或接收你导入的第三方节点数据。节点运营方和目标服务可能按各自政策处理网络数据，请只使用你信任的节点。"
                    )
                    disclosureRow(
                        symbol: "key.fill",
                        title: "配置保存在你的设备上",
                        detail: "节点和订阅认证信息保存在共享 Keychain，规则与运行状态保存在 App Group。你主动导出的备份会包含节点认证信息，并由你选择保存位置；AuraTunnel 不会自动上传备份。"
                    )
                    disclosureRow(
                        symbol: "hand.tap.fill",
                        title: "相机和剪贴板仅由你触发",
                        detail: "只有点击扫码后才会请求相机权限，画面仅用于实时二维码识别，不保存或上传。剪贴板只在你点击系统“粘贴”按钮后读取；复制节点时只执行你选择的写入操作。"
                    )

                    Text("继续即表示你已阅读这份数据处理说明。它不是系统权限授权；相机和 VPN 配置仍会在你实际使用对应功能时由 iOS 单独询问。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 8) {
                        Text("购买、删除与联系")
                            .font(.headline)
                        Text("AuraTunnel 仅为 App Store 付费下载，不含 App 内购买。你可以在节点库删除节点或订阅、删除导出的备份，并通过删除 App 清除容器数据。开发者没有用户账号或服务器端用户数据库。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Link("隐私与支持邮箱：silas980729@gmail.com", destination: URL(string: "mailto:silas980729@gmail.com")!)
                            .font(.subheadline)
                        Text("生效日期：2026-08-29")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(16)
                    .auraCard(cornerRadius: 18)

                    if let onAccept {
                        Button("我已了解并继续", action: onAccept)
                            .buttonStyle(.borderedProminent)
                            .tint(AuraPalette.aqua)
                            .controlSize(.large)
                            .frame(maxWidth: .infinity)
                            .accessibilityHint("进入 AuraTunnel，不会在此处请求系统权限")
                    }
                }
                .padding(20)
                .frame(maxWidth: 720)
                .frame(maxWidth: .infinity)
            }
        }
        .navigationTitle("隐私政策")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func disclosureRow(symbol: String, title: LocalizedStringKey, detail: LocalizedStringKey) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(AuraPalette.aqua)
                .frame(width: 36, height: 36)
                .background(AuraPalette.aqua.opacity(0.10), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(16)
        .auraCard(cornerRadius: 18)
    }
}
