import AVFoundation
import SwiftUI
import UIKit

struct QRCodeScannerView: View {
    let onResult: (String) -> Void
    let onCancel: () -> Void

    @State private var hasAcknowledgedPrimer = false

    var body: some View {
        Group {
            switch AVCaptureDevice.authorizationStatus(for: .video) {
            case .notDetermined where !hasAcknowledgedPrimer:
                cameraPrimer
            case .denied, .restricted:
                cameraUnavailable
            default:
                QRCodeScannerControllerRepresentable(
                    onResult: onResult,
                    onCancel: onCancel
                )
            }
        }
    }

    private var cameraPrimer: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.02, green: 0.15, blue: 0.25), Color(red: 0.02, green: 0.50, blue: 0.52)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            VStack(spacing: 18) {
                Image(systemName: "qrcode.viewfinder")
                    .font(.system(size: 54, weight: .medium))
                    .foregroundStyle(.white)
                    .accessibilityHidden(true)
                Text("允许扫码导入")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                Text("下一步，iOS 会询问是否允许使用相机。AuraTunnel 只识别你放入取景框的节点或订阅二维码，不会拍照、保存视频或上传画面。")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.88))
                    .multilineTextAlignment(.center)
                Text("你也可以选择“暂不使用”，继续通过剪贴板或手动方式导入。")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.72))
                    .multilineTextAlignment(.center)

                Button("继续") {
                    hasAcknowledgedPrimer = true
                }
                .buttonStyle(.borderedProminent)
                .tint(.white)
                .foregroundStyle(Color(red: 0.02, green: 0.28, blue: 0.36))

                Button("暂不使用", action: onCancel)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.white)
            }
            .padding(30)
            .frame(maxWidth: 460)
        }
    }

    private var cameraUnavailable: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 18) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.secondary)
                Text("相机权限未开启")
                    .font(.title2.bold())
                    .foregroundStyle(.white)
                Text("你仍可返回节点库，通过剪贴板或手动方式导入。若要扫码，可在系统设置中允许 AuraTunnel 使用相机。")
                    .foregroundStyle(.white.opacity(0.78))
                    .multilineTextAlignment(.center)
                Button("打开系统设置") {
                    guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                    UIApplication.shared.open(url)
                }
                .buttonStyle(.borderedProminent)
                Button("返回", action: onCancel)
                    .foregroundStyle(.white)
            }
            .padding(30)
        }
    }
}

private struct QRCodeScannerControllerRepresentable: UIViewControllerRepresentable {
    let onResult: (String) -> Void
    let onCancel: () -> Void

    func makeUIViewController(context: Context) -> QRCodeScannerViewController {
        let controller = QRCodeScannerViewController()
        controller.onResult = onResult
        controller.onCancel = onCancel
        return controller
    }

    func updateUIViewController(_ uiViewController: QRCodeScannerViewController, context: Context) {}

    static func dismantleUIViewController(_ uiViewController: QRCodeScannerViewController, coordinator: ()) {
        uiViewController.stopScanning()
    }
}

@MainActor
final class QRCodeScannerViewController: UIViewController {
    var onResult: ((String) -> Void)?
    var onCancel: (() -> Void)?

    private lazy var driver = QRCodeCaptureDriver { [weak self] event in
        Task { @MainActor [weak self] in
            self?.handle(event)
        }
    }
    private lazy var previewLayer = AVCaptureVideoPreviewLayer(session: driver.session)
    private let overlayLayer = CAShapeLayer()
    private let scanBorderLayer = CAShapeLayer()
    private let instructionLabel = UILabel()
    private let closeButton = UIButton(type: .system)
    private var hasDeliveredResult = false

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black

        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)

        overlayLayer.fillColor = UIColor.black.withAlphaComponent(0.48).cgColor
        overlayLayer.fillRule = .evenOdd
        view.layer.addSublayer(overlayLayer)

        scanBorderLayer.strokeColor = UIColor.systemCyan.cgColor
        scanBorderLayer.fillColor = UIColor.clear.cgColor
        scanBorderLayer.lineWidth = 3
        view.layer.addSublayer(scanBorderLayer)

        instructionLabel.text = "将 VPN 节点二维码放入框内"
        instructionLabel.textColor = .white
        instructionLabel.font = .preferredFont(forTextStyle: .headline)
        instructionLabel.textAlignment = .center
        instructionLabel.numberOfLines = 2
        view.addSubview(instructionLabel)

        var closeConfiguration = UIButton.Configuration.filled()
        closeConfiguration.image = UIImage(systemName: "xmark")
        closeConfiguration.baseBackgroundColor = UIColor.black.withAlphaComponent(0.55)
        closeConfiguration.baseForegroundColor = .white
        closeConfiguration.cornerStyle = .capsule
        closeButton.configuration = closeConfiguration
        closeButton.accessibilityLabel = "关闭扫码"
        closeButton.addTarget(self, action: #selector(closeTapped), for: .touchUpInside)
        view.addSubview(closeButton)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        requestCameraAndStart()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopScanning()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer.frame = view.bounds

        let side = min(view.bounds.width - 64, 300)
        let scanRect = CGRect(
            x: (view.bounds.width - side) / 2,
            y: (view.bounds.height - side) / 2 - 24,
            width: side,
            height: side
        )

        let overlayPath = UIBezierPath(rect: view.bounds)
        overlayPath.append(UIBezierPath(roundedRect: scanRect, cornerRadius: 22))
        overlayLayer.frame = view.bounds
        overlayLayer.path = overlayPath.cgPath

        scanBorderLayer.frame = view.bounds
        scanBorderLayer.path = UIBezierPath(roundedRect: scanRect, cornerRadius: 22).cgPath

        instructionLabel.frame = CGRect(
            x: 28,
            y: scanRect.maxY + 24,
            width: view.bounds.width - 56,
            height: 56
        )
        closeButton.frame = CGRect(x: 20, y: view.safeAreaInsets.top + 12, width: 44, height: 44)

        // Limiting the scan region reduces metadata work outside the visible guide.
        let metadataRect = previewLayer.metadataOutputRectConverted(fromLayerRect: scanRect)
        driver.setRectOfInterest(metadataRect)
    }

    func stopScanning() {
        driver.stop()
    }

    @objc private func closeTapped() {
        stopScanning()
        onCancel?()
    }

    private func requestCameraAndStart() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            driver.configureAndStart()
        case .notDetermined:
            Task { [weak self] in
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                guard let self else { return }
                if granted {
                    self.driver.configureAndStart()
                } else {
                    self.showFailure("未获得相机权限，请在系统设置中允许 AuraTunnel 使用相机。")
                }
            }
        case .denied, .restricted:
            showFailure("相机权限已关闭，请在系统设置中允许 AuraTunnel 使用相机。")
        @unknown default:
            showFailure("当前设备无法使用相机扫码。")
        }
    }

    private func handle(_ event: QRScannerEvent) {
        switch event {
        case .ready:
            instructionLabel.text = "将 VPN 节点二维码放入框内"
            view.setNeedsLayout()
        case .code(let value):
            guard !hasDeliveredResult else { return }
            hasDeliveredResult = true
            onResult?(value)
        case .failure(let message):
            showFailure(message)
        }
    }

    private func showFailure(_ message: String) {
        instructionLabel.text = message
        instructionLabel.textColor = .systemRed
        stopScanning()
    }
}

private enum QRScannerEvent: Sendable {
    case ready
    case code(String)
    case failure(String)
}

/// Camera work is isolated to one serial queue. Only QR metadata is emitted;
/// the app never receives or copies video sample buffers.
private final class QRCodeCaptureDriver: NSObject, AVCaptureMetadataOutputObjectsDelegate, @unchecked Sendable {
    let session = AVCaptureSession()

    private let queue = DispatchQueue(label: "com.shaolihuang.auratunnel.qr", qos: .userInitiated)
    private let output = AVCaptureMetadataOutput()
    private let eventHandler: (QRScannerEvent) -> Void
    private var configured = false
    private var wantsToRun = false
    private var deliveredCode = false

    init(eventHandler: @escaping (QRScannerEvent) -> Void) {
        self.eventHandler = eventHandler
        super.init()
    }

    func configureAndStart() {
        queue.async { [self] in
            wantsToRun = true
            do {
                if !configured {
                    try configureSession()
                    configured = true
                }
                guard wantsToRun, !session.isRunning else { return }
                deliveredCode = false
                session.startRunning()
                eventHandler(.ready)
            } catch {
                wantsToRun = false
                eventHandler(.failure(error.localizedDescription))
            }
        }
    }

    func setRectOfInterest(_ rect: CGRect) {
        queue.async { [self] in
            output.rectOfInterest = rect
        }
    }

    func stop() {
        queue.async { [self] in
            wantsToRun = false
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    private func configureSession() throws {
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            throw QRScannerSetupError.cameraUnavailable
        }

        let input = try AVCaptureDeviceInput(device: camera)
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        if session.canSetSessionPreset(.vga640x480) {
            // 640x480 is sufficient for QR metadata and avoids high-resolution capture cost.
            session.sessionPreset = .vga640x480
        } else {
            session.sessionPreset = .medium
        }

        guard session.canAddInput(input), session.canAddOutput(output) else {
            throw QRScannerSetupError.configurationFailed
        }
        session.addInput(input)
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: queue)

        guard output.availableMetadataObjectTypes.contains(.qr) else {
            throw QRScannerSetupError.qrUnavailable
        }
        output.metadataObjectTypes = [.qr]
    }

    func metadataOutput(
        _ output: AVCaptureMetadataOutput,
        didOutput metadataObjects: [AVMetadataObject],
        from connection: AVCaptureConnection
    ) {
        guard
            wantsToRun,
            !deliveredCode,
            let code = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
            code.type == .qr,
            let value = code.stringValue,
            !value.isEmpty
        else {
            return
        }

        deliveredCode = true
        wantsToRun = false
        if session.isRunning {
            session.stopRunning()
        }
        eventHandler(.code(value))
    }
}

private enum QRScannerSetupError: LocalizedError {
    case cameraUnavailable
    case configurationFailed
    case qrUnavailable

    var errorDescription: String? {
        switch self {
        case .cameraUnavailable:
            "未找到可用的后置相机。"
        case .configurationFailed:
            "无法初始化二维码扫描器。"
        case .qrUnavailable:
            "当前设备不支持 QR 码识别。"
        }
    }
}
