# Target

[简体中文](README.zh-CN.md) | [English](README.en.md)

Target 是一款原生 macOS 代理客户端。当前源代码提供 SwiftUI macOS 应用以及最小化的 Packet Tunnel Provider 扩展生命周期界面。

## 当前可用能力

应用提供已配置 Packet Tunnel Provider 的启动与停止控件。Provider 实现刻意保持最小化：不代理流量、不配置 DNS、不应用规则，也不管理节点。

## 构建要求

- macOS 15 或更高版本
- Xcode 26.6 或更高版本
- 具有 Network Extension capability 的 Apple 开发团队，用于签名并在设备上运行 Packet Tunnel Provider

在 Xcode 中打开 `Target.xcodeproj`，为两个 target 选择开发团队，然后构建 `Target` scheme。

## 许可证

Target 以 [GNU General Public License v3.0 or later](LICENSE) 发布。第三方声明请参见 [NOTICE](NOTICE)。
