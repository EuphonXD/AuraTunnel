# AuraTunnel

AuraTunnel 是一个面向 iOS 16 及更高版本的 Packet Tunnel 客户端。用户导入并管理自己有权使用的代理节点、HTTPS 订阅和路由规则；本项目不提供、销售或运营 VPN 节点。

AuraTunnel is an iOS 16+ Packet Tunnel client for user-provided proxy nodes, HTTPS subscriptions, and routing rules. This project does not provide, sell, or operate VPN nodes.

## 功能概览

- SwiftUI 主 App 与 `NEPacketTunnelProvider` 网络扩展；
- VMess、VLESS、Shadowsocks、Trojan、SOCKS5 等配置解析；
- 智能分流、规则配置、全局代理、全部直连与场景路由；
- 二维码、系统粘贴按钮和 HTTPS 订阅导入；
- 节点测试、编辑、分享、去重和配置备份；
- 中英文界面、VPN 数据披露、超时与意外断开提醒；
- 基于 App Group 的低频状态共享及批量 Packet Tunnel 处理。

## 构建要求

- macOS 与 Xcode；
- iOS 16.0 或更高版本；
- Apple Developer Program 账号；
- Network Extension 与 App Groups capability；
- 与 App 和 PacketTunnel bundle identifier 匹配的签名配置。

打开 `EasyVPN-App.xcodeproj`，为 `AuraTunnel` 和 `PacketTunnel` targets 设置你自己的 Team、Bundle Identifier 与 App Group 后再构建。系统 VPN 和 Packet Tunnel 必须在正确签名的真机版本中验证。

## 许可证

**本仓库是 source-available，不是 OSI 定义下的开源软件。** OSI 开源许可证必须允许商业用途，而 AuraTunnel 的原创代码限制为非商业使用。

- 非商业使用：[PolyForm Noncommercial License 1.0.0](LICENSE)
- 商业授权：[COMMERCIAL-LICENSE.md](COMMERCIAL-LICENSE.md)
- 第三方许可：[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)
- 贡献规则：[CONTRIBUTING.md](CONTRIBUTING.md)

任何商业使用必须事先获得 SHAOLI HUANG 的单独书面授权。商业授权联系邮箱：**silas980729@gmail.com**。

`ThirdParty/Leaf` 及其他第三方内容继续适用各自许可证，根目录的非商业限制不会撤销第三方许可方已经直接授予的权利。

## 安全与隐私

请勿把真实节点、订阅地址、UUID、密码、证书、描述文件、签名密钥或流量日志提交到公开仓库。公开 fork 时必须更换 Bundle Identifier、App Group 和签名 Team，并自行遵守 Network Extension、App Store Review Guidelines 及上架地区法律。

## 免责声明

本项目仅提供网络客户端源码，不提供网络接入、代理节点或规避任何地区法律的服务。用户和再分发者须确保自己有权使用相关节点、协议、网络和加密功能，并承担配置、分发及使用产生的责任。
