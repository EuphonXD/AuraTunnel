import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import UIKit

enum NodeActionSheet: Identifiable {
    case detail(TunnelProfile, String)
    case share(TunnelProfile, String)
    case url(TunnelProfile, String)
    case edit(TunnelProfile, String)
    case qr(TunnelProfile, String)

    var id: String {
        switch self {
        case .detail(let profile, _): "detail-\(profile.id.uuidString)"
        case .share(let profile, _): "share-\(profile.id.uuidString)"
        case .url(let profile, _): "url-\(profile.id.uuidString)"
        case .edit(let profile, _): "edit-\(profile.id.uuidString)"
        case .qr(let profile, _): "qr-\(profile.id.uuidString)"
        }
    }
}

struct NodeActionSheetView: View {
    let sheet: NodeActionSheet
    let onSave: (TunnelProfile, String, String) async throws -> Void
    let onDelete: (TunnelProfile) async -> Void

    var body: some View {
        switch sheet {
        case .detail(let profile, let rawURI):
            NodeDetailView(
                profile: profile,
                rawURI: rawURI,
                onSave: onSave,
                onDelete: onDelete
            )
        case .share(let profile, let rawURI):
            NodeShareView(profile: profile, rawURI: rawURI)
        case .url(let profile, let rawURI):
            NodeURLView(profile: profile, rawURI: rawURI)
        case .edit(let profile, let rawURI):
            NodeEditorView(profile: profile, originalURI: rawURI, onSave: onSave)
        case .qr(let profile, let rawURI):
            NodeQRCodeView(profile: profile, rawURI: rawURI)
        }
    }
}

private struct NodeDetailView: View {
    @Environment(\.dismiss) private var dismiss
    let profile: TunnelProfile
    let rawURI: String
    let onSave: (TunnelProfile, String, String) async throws -> Void
    let onDelete: (TunnelProfile) async -> Void

    @State private var revealsSecrets = false
    @State private var isEditing = false
    @State private var confirmsDeletion = false
    @State private var copiedItem: String?

    private var inspection: NodeInspection {
        NodeURIInspector.inspect(profile: profile, rawURI: rawURI)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    detailRow(label: "类型", value: profile.proxyProtocol.displayName)
                    detailRow(label: "地址", value: profile.serverHost)
                    detailRow(label: "端口", value: String(profile.serverPort))
                    ForEach(inspection.fields) { field in
                        detailRow(
                            label: field.label,
                            value: field.isSecret && !revealsSecrets ? "••••••••" : field.value
                        )
                    }
                } header: {
                    Text("连接参数")
                } footer: {
                    Text("UDP 是否可用还取决于节点服务端；AuraTunnel 会同时转发 TCP、UDP 与 IPv6。")
                }

                Section("备注") {
                    Text(profile.name)
                }

                Section {
                    ShareLink(item: rawURI) {
                        Label("分享节点", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        UIPasteboard.general.string = inspection.json
                        copiedItem = "JSON"
                    } label: {
                        Label(copiedItem == "JSON" ? "JSON 已复制" : "复制 JSON", systemImage: "curlybraces")
                    }
                    Button {
                        UIPasteboard.general.string = rawURI
                        copiedItem = "URL"
                    } label: {
                        Label(copiedItem == "URL" ? "URL 已复制" : "复制网址", systemImage: "doc.on.doc")
                    }
                }

                Section {
                    Button("删除节点", systemImage: "trash", role: .destructive) {
                        confirmsDeletion = true
                    }
                }
            }
            .navigationTitle("节点详情")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                }
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        revealsSecrets.toggle()
                    } label: {
                        Image(systemName: revealsSecrets ? "eye.slash" : "eye")
                    }
                    .accessibilityLabel(revealsSecrets ? "隐藏认证信息" : "显示认证信息")

                    Button("编辑") { isEditing = true }
                }
            }
            .sheet(isPresented: $isEditing) {
                NodeEditorView(
                    profile: profile,
                    originalURI: rawURI,
                    onSave: { profile, name, uri in
                        try await onSave(profile, name, uri)
                        dismiss()
                    }
                )
            }
            .confirmationDialog(
                "删除这个节点？",
                isPresented: $confirmsDeletion,
                titleVisibility: .visible
            ) {
                Button("删除节点", role: .destructive) {
                    Task {
                        await onDelete(profile)
                        dismiss()
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("节点认证信息也会从共享 Keychain 中删除。")
            }
        }
    }

    private func detailRow(label: String, value: String) -> some View {
        LabeledContent {
            Text(value)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        } label: {
            Text(LocalizedStringKey(label))
        }
    }
}

private struct NodeInspectionField: Identifiable {
    let id = UUID()
    let label: String
    let value: String
    let isSecret: Bool
}

private struct NodeInspection {
    let fields: [NodeInspectionField]
    let json: String
}

private enum NodeURIInspector {
    static func inspect(profile: TunnelProfile, rawURI: String) -> NodeInspection {
        switch profile.proxyProtocol {
        case .vmess:
            return inspectVMess(profile: profile, rawURI: rawURI)
        case .vless, .trojan, .socks5, .hysteria2:
            return inspectURL(profile: profile, rawURI: rawURI)
        case .shadowsocks:
            return inspectShadowsocks(profile: profile, rawURI: rawURI)
        }
    }

    private static func inspectVMess(profile: TunnelProfile, rawURI: String) -> NodeInspection {
        let payload = String(rawURI.dropFirst("vmess://".count))
        guard let data = decodeBase64(payload),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return fallback(profile: profile, rawURI: rawURI)
        }

        let fields = [
            field("UUID", object["id"], secret: true),
            field("额外 ID", object["aid"] ?? "0"),
            field("算法", object["scy"] ?? "auto"),
            field("传输方式", object["net"] ?? "tcp"),
            field("TLS", object["tls"] ?? "关闭"),
            field("SNI", object["sni"]),
            field("Host", object["host"]),
            field("路径", object["path"]),
            NodeInspectionField(label: "UDP 转发", value: "开启", isSecret: false),
        ].compactMap { $0 }
        return NodeInspection(fields: fields, json: prettyJSON(object) ?? rawURI)
    }

    private static func inspectURL(profile: TunnelProfile, rawURI: String) -> NodeInspection {
        guard let components = URLComponents(string: rawURI) else {
            return fallback(profile: profile, rawURI: rawURI)
        }
        var fields: [NodeInspectionField] = []
        if let user = components.user, !user.isEmpty {
            fields.append(
                NodeInspectionField(
                    label: profile.proxyProtocol == .trojan ? "密码" : "用户 / UUID",
                    value: user.removingPercentEncoding ?? user,
                    isSecret: true
                )
            )
        }
        if let password = components.password, !password.isEmpty {
            fields.append(NodeInspectionField(label: "密码", value: password, isSecret: true))
        }
        let query = Dictionary(
            components.queryItems?.map { ($0.name.lowercased(), $0.value ?? "") } ?? [],
            uniquingKeysWith: { first, _ in first }
        )
        append("加密 / 安全", query["security"] ?? query["encryption"], to: &fields)
        append("传输方式", query["type"] ?? query["network"], to: &fields)
        append("SNI", query["sni"], to: &fields)
        append("Host", query["host"], to: &fields)
        append("路径", query["path"]?.removingPercentEncoding, to: &fields)
        fields.append(NodeInspectionField(label: "UDP 转发", value: "开启", isSecret: false))
        return NodeInspection(fields: fields, json: summaryJSON(profile: profile, rawURI: rawURI, fields: fields))
    }

    private static func inspectShadowsocks(profile: TunnelProfile, rawURI: String) -> NodeInspection {
        var fields: [NodeInspectionField] = []
        let value = String(rawURI.dropFirst("ss://".count))
        let userInfo = value.split(separator: "@", maxSplits: 1).first.map(String.init) ?? ""
        if let decoded = decodeBase64(userInfo),
           let authentication = String(data: decoded, encoding: .utf8),
           let separator = authentication.firstIndex(of: ":") {
            fields.append(
                NodeInspectionField(
                    label: "算法",
                    value: String(authentication[..<separator]),
                    isSecret: false
                )
            )
            fields.append(
                NodeInspectionField(
                    label: "密码",
                    value: String(authentication[authentication.index(after: separator)...]),
                    isSecret: true
                )
            )
        }
        fields.append(NodeInspectionField(label: "UDP 转发", value: "开启", isSecret: false))
        return NodeInspection(fields: fields, json: summaryJSON(profile: profile, rawURI: rawURI, fields: fields))
    }

    private static func fallback(profile: TunnelProfile, rawURI: String) -> NodeInspection {
        let fields = [NodeInspectionField(label: "UDP 转发", value: "开启", isSecret: false)]
        return NodeInspection(fields: fields, json: summaryJSON(profile: profile, rawURI: rawURI, fields: fields))
    }

    private static func field(
        _ label: String,
        _ value: Any?,
        secret: Bool = false
    ) -> NodeInspectionField? {
        guard let value else { return nil }
        let string = String(describing: value)
        guard !string.isEmpty else { return nil }
        return NodeInspectionField(label: label, value: string, isSecret: secret)
    }

    private static func append(
        _ label: String,
        _ value: String?,
        secret: Bool = false,
        to fields: inout [NodeInspectionField]
    ) {
        guard let value, !value.isEmpty else { return }
        fields.append(NodeInspectionField(label: label, value: value, isSecret: secret))
    }

    private static func summaryJSON(
        profile: TunnelProfile,
        rawURI: String,
        fields: [NodeInspectionField]
    ) -> String {
        var object: [String: Any] = [
            "name": profile.name,
            "type": profile.proxyProtocol.rawValue,
            "address": profile.serverHost,
            "port": Int(profile.serverPort),
            "url": rawURI,
        ]
        for field in fields { object[field.label] = field.value }
        return prettyJSON(object) ?? rawURI
    }

    private static func prettyJSON(_ object: Any) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decodeBase64(_ value: String) -> Data? {
        var normalized = value
            .split(separator: "#", maxSplits: 1)
            .first
            .map(String.init) ?? value
        normalized = normalized.replacingOccurrences(of: "-", with: "+")
        normalized = normalized.replacingOccurrences(of: "_", with: "/")
        let remainder = normalized.count % 4
        if remainder != 0 {
            normalized.append(String(repeating: "=", count: 4 - remainder))
        }
        return Data(base64Encoded: normalized, options: .ignoreUnknownCharacters)
    }
}

private struct NodeShareView: View {
    @Environment(\.dismiss) private var dismiss
    let profile: TunnelProfile
    let rawURI: String

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "square.and.arrow.up.circle.fill")
                    .font(.system(size: 58))
                    .foregroundStyle(AuraPalette.aqua)
                Text(profile.name)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                Text("分享内容包含节点服务器与认证信息，只发送给你信任的人。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                ShareLink(item: rawURI) {
                    Label("打开系统分享", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(AuraPalette.ocean)
            }
            .padding(24)
            .navigationTitle("分享节点")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct NodeURLView: View {
    @Environment(\.dismiss) private var dismiss
    let profile: TunnelProfile
    let rawURI: String
    @State private var copied = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Label("该 URL 包含节点认证信息", systemImage: "exclamationmark.shield.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.orange)

                    Text(rawURI)
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(
                            Color(uiColor: .secondarySystemGroupedBackground),
                            in: RoundedRectangle(cornerRadius: 16)
                        )

                    Button {
                        UIPasteboard.general.string = rawURI
                        copied = true
                    } label: {
                        Label(copied ? "已复制" : "复制节点 URL", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AuraPalette.ocean)
                }
                .padding(18)
            }
            .background(Color(uiColor: .systemGroupedBackground))
            .navigationTitle(profile.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

private struct NodeEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let profile: TunnelProfile
    let originalURI: String
    let onSave: (TunnelProfile, String, String) async throws -> Void

    @State private var displayName: String
    @State private var rawURI: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(
        profile: TunnelProfile,
        originalURI: String,
        onSave: @escaping (TunnelProfile, String, String) async throws -> Void
    ) {
        self.profile = profile
        self.originalURI = originalURI
        self.onSave = onSave
        _displayName = State(initialValue: profile.name)
        _rawURI = State(initialValue: originalURI)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("显示") {
                    TextField("节点名称", text: $displayName)
                        .textInputAutocapitalization(.never)
                }

                Section {
                    TextEditor(text: $rawURI)
                        .font(.system(.footnote, design: .monospaced))
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .frame(minHeight: 180)
                } header: {
                    Text("完整节点 URL")
                } footer: {
                    Text("修改 URL 后会重新解析协议、服务器和认证字段，并安全替换 Keychain 内容。")
                }

                Section("当前摘要") {
                    LabeledContent("协议", value: profile.proxyProtocol.displayName)
                    LabeledContent("服务器", value: "\(profile.serverHost):\(profile.serverPort)")
                }
            }
            .navigationTitle("编辑节点")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isSaving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        Task { await save() }
                    }
                    .disabled(
                        isSaving ||
                        displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                        rawURI.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }
            }
            .overlay {
                if isSaving {
                    ProgressView("正在安全保存…")
                        .padding(18)
                        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 18))
                }
            }
            .alert(
                "无法保存节点",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("好", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "未知错误")
            }
        }
    }

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await onSave(profile, displayName, rawURI)
            dismiss()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

private struct NodeQRCodeView: View {
    @Environment(\.dismiss) private var dismiss
    let profile: TunnelProfile
    let rawURI: String

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                if let image = SecureQRCodeGenerator.image(for: rawURI) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .padding(14)
                        .background(.white, in: RoundedRectangle(cornerRadius: 20))
                        .accessibilityLabel("\(profile.name) 节点二维码")
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "qrcode")
                            .font(.system(size: 44))
                            .foregroundStyle(.secondary)
                        Text("无法生成二维码")
                            .font(.headline)
                        Text("节点 URL 过长，请改用系统分享。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 240)
                }

                Text("二维码包含完整认证信息，请勿公开展示。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .navigationTitle(profile.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

enum SecureQRCodeGenerator {
    static func image(for value: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }

        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

enum SubscriptionActionSheet: Identifiable {
    case share(SubscriptionProfile, String)
    case url(SubscriptionProfile, String)
    case edit(SubscriptionProfile)
    case qr(SubscriptionProfile, String)

    var id: String {
        switch self {
        case .share(let subscription, _): "subscription-share-\(subscription.id)"
        case .url(let subscription, _): "subscription-url-\(subscription.id)"
        case .edit(let subscription): "subscription-edit-\(subscription.id)"
        case .qr(let subscription, _): "subscription-qr-\(subscription.id)"
        }
    }
}

struct SubscriptionActionSheetView: View {
    let sheet: SubscriptionActionSheet
    let onRename: (SubscriptionProfile, String) async throws -> Void
    let onDelete: (SubscriptionProfile) async -> Void

    var body: some View {
        switch sheet {
        case .share(let subscription, let importURI):
            SubscriptionShareView(subscription: subscription, importURI: importURI)
        case .url(let subscription, let rawURL):
            SubscriptionURLView(
                subscription: subscription,
                rawURL: rawURL,
                onDelete: onDelete
            )
        case .edit(let subscription):
            SubscriptionEditorView(subscription: subscription, onRename: onRename)
        case .qr(let subscription, let importURI):
            SubscriptionQRCodeView(subscription: subscription, importURI: importURI)
        }
    }
}

private struct SubscriptionShareView: View {
    @Environment(\.dismiss) private var dismiss
    let subscription: SubscriptionProfile
    let importURI: String

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Image(systemName: "square.and.arrow.up.circle.fill")
                    .font(.system(size: 58))
                    .foregroundStyle(AuraPalette.aqua)
                Text(subscription.name)
                    .font(.title2.weight(.bold))
                Text("分享内容包含订阅凭据，获得链接的人可能访问你的节点，请只发送给信任的人。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                ShareLink(item: importURI) {
                    Label("打开系统分享", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(AuraPalette.ocean)
            }
            .padding(24)
            .navigationTitle("分享订阅")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

private struct SubscriptionURLView: View {
    @Environment(\.dismiss) private var dismiss
    let subscription: SubscriptionProfile
    let rawURL: String
    let onDelete: (SubscriptionProfile) async -> Void
    @State private var copied = false
    @State private var isConfirmingDelete = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("类型", value: "Subscribe")
                    VStack(alignment: .leading, spacing: 6) {
                        Text("URL")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(rawURL)
                            .font(.system(.footnote, design: .monospaced))
                            .textSelection(.enabled)
                    }
                    LabeledContent("UDP 转发", value: "默认")
                    LabeledContent("允许不安全", value: "默认")
                    LabeledContent("TCP 快速打开", value: "默认")
                    LabeledContent("最大节点数", value: "不限制")
                    LabeledContent("用户代理", value: "AuraTunnel/1.0")
                    LabeledContent("密码", value: "未设置")
                    LabeledContent("过滤", value: "未设置")
                    LabeledContent("备注", value: subscription.name)
                } footer: {
                    Text("订阅 URL 可能包含访问凭据。刷新会按节点身份覆盖重复项，不会无限累计。")
                }

                Section {
                    ShareLink(item: rawURL) {
                        Label("分享订阅", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        UIPasteboard.general.string = subscriptionJSON
                        copied = true
                    } label: {
                        Label(copied ? "已复制 JSON" : "复制 JSON", systemImage: copied ? "checkmark" : "curlybraces")
                    }
                    Button {
                        UIPasteboard.general.string = rawURL
                        copied = true
                    } label: {
                        Label("复制网址", systemImage: "doc.on.doc")
                    }
                }

                Section {
                    Button("删除订阅", role: .destructive) {
                        isConfirmingDelete = true
                    }
                }
            }
            .navigationTitle(subscription.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .confirmationDialog(
                "删除订阅？",
                isPresented: $isConfirmingDelete,
                titleVisibility: .visible
            ) {
                Button("删除订阅及专属节点", role: .destructive) {
                    Task {
                        await onDelete(subscription)
                        dismiss()
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("共享节点会保留；只属于该订阅的节点会一起删除。")
            }
        }
    }

    private var subscriptionJSON: String {
        let object: [String: Any] = [
            "type": "Subscribe",
            "name": subscription.name,
            "url": rawURL,
            "udpRelay": "default",
            "allowInsecure": "default",
            "tcpFastOpen": "default",
            "nodeCount": subscription.nodeCount,
        ]
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        ) else {
            return rawURL
        }
        return String(data: data, encoding: .utf8) ?? rawURL
    }
}

private struct SubscriptionEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let subscription: SubscriptionProfile
    let onRename: (SubscriptionProfile, String) async throws -> Void
    @State private var name: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(
        subscription: SubscriptionProfile,
        onRename: @escaping (SubscriptionProfile, String) async throws -> Void
    ) {
        self.subscription = subscription
        self.onRename = onRename
        _name = State(initialValue: subscription.name)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("显示") {
                    TextField("订阅名称", text: $name)
                }
                Section("来源") {
                    LabeledContent("服务器", value: subscription.sourceHost)
                    LabeledContent("节点数", value: "\(subscription.nodeCount)")
                }
            }
            .navigationTitle("编辑订阅")
            .navigationBarTitleDisplayMode(.inline)
            .interactiveDismissDisabled(isSaving)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }.disabled(isSaving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { Task { await save() } }
                        .disabled(isSaving || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .alert(
                "无法保存订阅",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("好", role: .cancel) { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "未知错误")
            }
        }
    }

    private func save() async {
        guard !isSaving else { return }
        isSaving = true
        defer { isSaving = false }
        do {
            try await onRename(subscription, name)
            dismiss()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

private struct SubscriptionQRCodeView: View {
    @Environment(\.dismiss) private var dismiss
    let subscription: SubscriptionProfile
    let importURI: String

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                if let image = SecureQRCodeGenerator.image(for: importURI) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .padding(14)
                        .background(.white, in: RoundedRectangle(cornerRadius: 20))
                        .accessibilityLabel("\(subscription.name) 订阅二维码")
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "qrcode")
                            .font(.system(size: 44))
                            .foregroundStyle(.secondary)
                        Text("无法生成二维码")
                            .font(.headline)
                        Text("订阅 URL 过长，请改用系统分享。")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 240)
                }
                Text("二维码包含完整订阅凭据，请勿公开展示。")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(20)
            .navigationTitle(subscription.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

struct NodeActionError: Identifiable {
    let id = UUID()
    let message: String
}
