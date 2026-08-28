# AuraTunnel App Store 合规审计与修复结果

审计日期：2026-08-29  
审计范围：App target、PacketTunnel target、权限、剪贴板、网络、App 隐私、付费模型、连接失败状态、上架文档。

## 风险等级｜问题说明｜修复内容

| 风险等级 | 问题说明 | 修复内容（成品） |
|---|---|---|
| 高 | 主 App 与 PacketTunnel 均缺少 `PrivacyInfo.xcprivacy`。App 使用标准 UserDefaults，App 与扩展还通过 App Group UserDefaults 共享低频配置；Release 扩展二进制中的 Leaf 静态核心还链接了 `fstat`。 | 已分别新增 `iOS-VPN-Client/PrivacyInfo.xcprivacy` 和 `PacketTunnel/PrivacyInfo.xcprivacy`。主 App 声明 UserDefaults `CA92.1`、`1C8F.1`；扩展声明 UserDefaults `1C8F.1` 及容器文件元数据 `C617.1`；Tracking=false，CollectedDataTypes 为空。 |
| 高 | VPN App 首次使用前没有完整的数据路径披露，存在 Guideline 5.4 风险。 | 已新增首次启动的“隐私政策与 VPN 数据说明”，在任何 VPN 使用动作前说明不收集 VPN 流量、用户节点边界、本地存储、相机/剪贴板和备份，并提供中英文切换。设置页可随时重新打开。 |
| 中 | 相机系统授权在扫码控制器出现后立即请求，虽由扫码动作触发，但缺少中性前置说明。 | 已新增可取消的相机用途页。“继续”后才调用 `AVCaptureDevice.requestAccess`；“暂不使用”返回 App，不限制剪贴板和手动导入。拒绝后提供“打开系统设置”。 |
| 中 | Camera UsageDescription 未完整说明画面是否保存或上传。 | 已更新中英文 `NSCameraUsageDescription`：仅实时识别用户主动扫描的节点/订阅二维码，不拍照、不保存、不上传。 |
| 中 | 用户可能选择/测试局域网代理节点，但缺少本地网络目的字符串。 | 已新增中英文 `NSLocalNetworkUsageDescription`，用途限定为用户选择或测试 LAN 节点；App 不使用 Bonjour 扫描设备。 |
| 中 | 连接只有固定 15 秒内部超时，没有用户开关，也没有连接成功后的意外断开提醒。 | 已增加 10/15/20/30 秒等待上限、连接失败提醒、意外断开提醒；默认开启提醒。状态只由 NetworkExtension 通知与一次性 deadline 触发，没有循环轮询。提醒可打开“活动”页查看诊断。 |
| 低 | 剪贴板代码需要核对 Privacy Manifest。 | 已确认读取仅使用系统 `PasteButton`，写入仅发生在用户选择复制操作后。Apple Required Reason API 列表没有 Clipboard 类别，因此没有添加无效的 `NSPrivacyAccessedAPIType`。已在 App 内披露和隐私政策说明。 |
| 低 | 用户只要求付费下载，但需确认是否误接入 IAP。 | 全项目未发现 StoreKit 商品、订阅、消耗型或非消耗型购买代码。保持付费 App，价格在 App Store Connect 设置；无需新增 IAP，2.1(b) 不适用。 |
| 已修复 | App Store 产品页必须提供公开隐私政策 URL 和技术支持 URL；本地 Markdown 不是公开页面。 | 中英文隐私政策与支持页面已发布到 `silas0729.github.io/dev-legal-pages/AuraTunnel/`，并于 2026-08-29 通过未登录 HTTPS 请求验证均返回 HTTP 200。提交当天仍应复查一次。 |
| 高（外部） | VPN App 只能由组织开发者账号提供，代码无法验证 Team ID 所属主体。 | Xcode targets 已统一 Team ID 和 Network Extension entitlement，但提交前必须在 Apple Developer 账户确认主体类型为 Organization。个人账号不能通过代码规避。 |
| 高（外部） | Guideline 2.1(a) 要求 App Review 能完整测试核心功能；当前 App 不内置节点。 | 已生成详细 Review Notes。提交前必须填入专用、非个人、审核期间持续有效的测试节点/订阅。不能伪造节点，也不要提交个人生产订阅。 |
| 高（外部） | VPN 在部分上架地区可能要求许可。 | Review Notes 模板已包含合规声明位置。只选择已有合法分发资格的地区；要求许可的地区必须提供真实材料。代码或隐私政策不能替代许可。 |

## 修复后的 PrivacyInfo.xcprivacy（主 App）

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>NSPrivacyTracking</key>
    <false/>
    <key>NSPrivacyTrackingDomains</key>
    <array/>
    <key>NSPrivacyCollectedDataTypes</key>
    <array/>
    <key>NSPrivacyAccessedAPITypes</key>
    <array>
        <dict>
            <key>NSPrivacyAccessedAPIType</key>
            <string>NSPrivacyAccessedAPICategoryUserDefaults</string>
            <key>NSPrivacyAccessedAPITypeReasons</key>
            <array>
                <string>CA92.1</string>
                <string>1C8F.1</string>
            </array>
        </dict>
    </array>
</dict>
</plist>
```

PacketTunnel 成品的 UserDefaults reasons 仅保留 `1C8F.1`，并额外声明：

```xml
<dict>
    <key>NSPrivacyAccessedAPIType</key>
    <string>NSPrivacyAccessedAPICategoryFileTimestamp</string>
    <key>NSPrivacyAccessedAPITypeReasons</key>
    <array>
        <string>C617.1</string>
    </array>
</dict>
```

## 修复后的 Info.plist 权限片段

```xml
<key>NSCameraUsageDescription</key>
<string>AuraTunnel 使用相机识别你主动扫描的 VPN 节点或订阅二维码。视频仅用于实时识别，不会拍照、保存或上传。</string>
<key>NSLocalNetworkUsageDescription</key>
<string>仅当你选择或测试位于局域网内的代理节点时，AuraTunnel 才会访问本地网络。</string>
```

无需添加位置、照片、麦克风、通知、通讯录、蓝牙或 Tracking UsageDescription，因为当前源码不请求这些权限。

## App Store 隐私标签成品

当前版本选择：

```text
No, we do not collect data from this app.
Tracking: No
```

该结论以“没有默认节点、开发者节点、账号、后端、广告、分析、崩溃上报或遥测”为前提。任何一项上线前变化都必须重新审计。

## 5.1.1 与 2.1(b) 结论

- 5.1.1：权限用途已具体化；相机由用户主动扫码后、前置说明并继续才请求；拒绝不锁死 App；剪贴板仅读取系统 PasteButton 交付的内容；本地网络仅在用户选择 LAN 节点时触发；不请求无关权限。
- 2.1(b)：当前没有 App 内购买，条款不适用。付费下载由 App Store 价格设置完成，不应为“已付费下载”再创建一个非消耗型解锁商品。
- 2.1(a)：二进制完整性仍需 Release Archive 和真机测试；审核访问还需要开发者提供真实可用的专用测试节点，这是外部提交材料，不可由代码伪造。

## 官方校准依据

- Apple App Review Guidelines: https://developer.apple.com/app-store/review/guidelines/
- App privacy details: https://developer.apple.com/app-store/app-privacy-details/
- Required Reason API values: https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype
- Privacy manifest files: https://developer.apple.com/documentation/bundleresources/privacy-manifest-files
- Protected resource purpose strings: https://developer.apple.com/documentation/bundleresources/information_property_list/protected_resources

## 本地验证边界

- `plutil -lint`：主 App/扩展 Info.plist、两份隐私清单、中英文 InfoPlist.strings 全部通过；
- Swift 6 Debug Simulator Build：通过；
- Release iPhoneOS Build：通过；
- Release Analyze：通过；
- 签名 Archive：通过，主 App 与 PacketTunnel 的签名一致，两个隐私清单均位于归档内正确 bundle 根目录；
- 当前归档使用本机 Apple Development 证书和开发描述文件，不等于 App Store Distribution 导出、上传、TestFlight 处理或 App Review 通过；
- 未在本次审计中完成真机相机、系统权限、VPN 连接和意外断开实测，这些仍需真机验证。
