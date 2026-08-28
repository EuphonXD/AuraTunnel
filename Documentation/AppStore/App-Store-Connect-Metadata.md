# AuraTunnel — App Store Connect 可粘贴内容

> 状态说明：正文已经完成。以下隐私政策与技术支持页面已于 2026-08-29 通过未登录 HTTPS 请求验证，均返回 HTTP 200。

## 1. 隐私政策 URL

填写：

```text
https://silas0729.github.io/dev-legal-pages/AuraTunnel/privacy
```

页面已公开，并包含中英文隐私政策、VPN 流量处理承诺和联系邮箱。提交当天仍建议用无痕浏览器复查一次。

## 2. 技术支持 URL

填写：

```text
https://silas0729.github.io/dev-legal-pages/AuraTunnel/support
```

页面已公开，并包含产品说明、权限说明、故障排查及支持邮箱。提交当天仍建议用无痕浏览器复查一次。

## 3. App 隐私标签

根据当前源码和二进制行为，在 App Store Connect > App Privacy 选择：

```text
Do you or your third-party partners collect data from this app?
No, we do not collect data from this app.

Tracking:
No
```

不要勾选“浏览历史”“诊断”“标识符”“位置”“用户内容”“购买记录”或其他数据类型。原因：当前版本没有开发者后端、账号、广告、分析、崩溃上报或遥测；本机数据不上传；Apple 处理的付费下载付款信息不由开发者取得；代理流量仅实时转发到用户自行选择的节点，开发者不接收或保留。

如果上线前加入开发者运营的节点、默认订阅、账号服务器、日志上传、崩溃上报、分析 SDK 或客服表单，以上答案必须重新审计，不能继续选择“No data collected”。

## 4. 价格与 App 内购买

```text
Business model: Paid App
In-App Purchases: None
Subscriptions: None
```

在 Pricing and Availability 中设置一次性下载价格。不要在 In-App Purchases 创建订阅、消耗型或非消耗型商品。当前二进制没有 StoreKit 商品代码，因此 Guideline 2.1(b) 的 IAP 完整性要求不适用。

## 5. App Review Notes（可直接粘贴，提交前替换一处测试节点）

```text
AuraTunnel is a paid-download Packet Tunnel client. It has no account, login, subscription, in-app purchase, advertising, analytics, or developer backend.

On first launch, the app displays the VPN data and privacy disclosure required for a VPN utility. The language can be changed on that screen. Camera permission is requested only after the reviewer taps Scan, reads the in-app explanation, and chooses Continue. Clipboard access occurs only through Apple's system Paste button. The system VPN configuration is saved only after an explicit Connect or Prepare System VPN action.

Review steps:
1. Read the first-launch disclosure and tap “I Understand and Continue.”
2. Open Nodes and tap the system Paste button.
3. Paste this dedicated review node or subscription: [REQUIRED: INSERT A WORKING, NON-PERSONAL, REVIEW-ONLY NODE OR HTTPS SUBSCRIPTION HERE]
4. Confirm import, select one node, return to Connect, and tap Connect Secure Tunnel.
5. Approve the iOS VPN configuration sheet.
6. Verify Connected status, then open Activity to view the low-frequency runtime snapshot.
7. Settings > Connection Alerts contains 10/15/20/30-second timeout selection plus independent failure and unexpected-disconnect alerts.

AuraTunnel does not provide or operate public VPN nodes. The review credential above must remain active throughout review and must not contain a personal production subscription. No special hardware is required.

VPN data commitment: the developer does not collect, log, sell, use, or disclose VPN traffic data. Proxied traffic is forwarded only to the node explicitly imported and selected by the user; direct traffic goes to the requested destination. The extension has no per-packet logs or telemetry.

Network Extension bundle identifier: com.shaolihuang.auratunnel.PacketTunnel
App Group: group.com.shaolihuang.auratunnel
```

## 6. Review 联系信息

```text
Contact first name: Silas
Contact last name: Huang
Contact email: silas980729@gmail.com
Contact phone: [REQUIRED: ENTER A PHONE NUMBER THAT APP REVIEW CAN REACH]
Sign-in required: No
```

## 7. 分类与地区合规提醒

建议主分类使用 Utilities。VPN App 只能由 Apple Developer Program 的组织账号提供。若选择需要 VPN 许可或备案的地区，必须在 Review Notes 上传真实有效的许可信息。不要填写“无需许可”、虚构编号或将未获许可的地区保持勾选。

## 8. Support 页面简短介绍（如托管平台需要摘要）

```text
AuraTunnel is a paid iOS Packet Tunnel client for user-provided proxy nodes and HTTPS subscriptions. It has no account, in-app purchase, advertising, analytics, or developer-operated VPN service. This page provides setup, permission, routing, backup, privacy, deletion, and troubleshooting instructions. Support: silas980729@gmail.com.
```

## 9. Privacy 页面简短介绍（如托管平台需要摘要）

```text
AuraTunnel does not collect, log, sell, use, or disclose VPN traffic data. Configuration remains on the user's device, camera and clipboard access are user-initiated, and backups are exported only to a location chosen by the user. The developer has no account system, advertising, analytics, telemetry, or VPN backend.
```
