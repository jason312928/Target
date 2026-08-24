<p align="center">
  <img src="Target/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="128" height="128" alt="Target app icon">
</p>

<h1 align="center">Target</h1>

<p align="center">
  一款原生、克制、以安全边界为先的 macOS sing-box 客户端。
</p>

<p align="center">
  <a href="README.md">简体中文</a> · <a href="README.en.md">English</a> · <a href="https://github.com/jason312928/Target/releases">下载</a>
</p>

<p align="center">
  <img alt="Platform" src="https://img.shields.io/badge/macOS-15%2B-111111?logo=apple">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-SwiftUI-F05138?logo=swift&logoColor=white">
  <img alt="Release" src="https://img.shields.io/badge/status-Development%20Preview-F59E0B">
  <img alt="License" src="https://img.shields.io/badge/license-GPL--3.0--or--later-2EA44F">
</p>

> [!IMPORTANT]
> Target 目前仍是 **Development Preview**，不是稳定版。最新预览版仅支持 Apple Silicon，使用 Apple Development 签名且尚未公证；macOS 可能要求你手动确认打开。

## 关于 Target

Target 是使用 Swift 与 SwiftUI 构建的原生 macOS 客户端，提供 Profile 管理、订阅导入、策略选择、运行状态观察和系统代理控制。sing-box 以内核进程的形式在当前用户下运行，Target 只在用户明确连接时修改 macOS 系统代理。

## 现在可以做什么

- **一键连接**：Connect 会启动 Target 管理的 sing-box 实例并建立系统代理；Disconnect 与 Restart 使用同一套安全生命周期。
- **完整的 Profile 工作区**：创建、导入、导出、复制、重命名和删除配置；内置 JSON 高亮、行号、格式化、诊断、版本历史与上一有效版本恢复。
- **本地订阅转换**：直接读取公共 HTTPS 订阅，在本机完成格式识别、节点转换、`sing-box check` 和脱敏预览，不依赖第三方转换站。
- **代理与策略选择**：浏览 sing-box selector，搜索和筛选节点，查看延迟与健康状态，并在运行中切换当前策略。
- **实时可观测性**：Dashboard 展示上下行速率、累计流量和活动连接数；Connections、Traffic、Logs 提供更完整的运行视图。
- **原生 macOS 集成**：菜单栏快速控制、首次使用引导、启动时运行、应用内更新，以及中英文界面。
- **可自动化**：随 App 提供 `targetctl`，通过本地控制平面管理 Profile、订阅、策略、引擎、系统代理和运行状态。

## 订阅兼容范围

Target 会先下载并验证候选内容，展示脱敏变化摘要，只有在你确认后才创建 Profile 或保存新版本。

| 类型 | 当前支持 |
| --- | --- |
| 订阅格式 | sing-box JSON、URI 列表、Base64 URI 列表、Clash / Mihomo YAML |
| 节点协议 | Shadowsocks、VMess、VLESS、Trojan、AnyTLS |
| 可识别但跳过 | SSR、Hysteria2 / Hy2、TUIC（订阅中仍有可用节点时） |

服务商特有的规则、代理组和 DNS 语义不会被完整照搬。Target 会生成自己的受限 sing-box Profile；它不是通用订阅转换器，也不会在后台自动刷新订阅。

## 快速开始

### 下载预览版

1. 从 [Development Preview 7](https://github.com/jason312928/Target/releases/tag/v1.0.0-dev.7) 下载 `Target-1.0.0-dev.7-macos-arm64.zip`。
2. 解压后将 `Target.app` 移到“应用程序”。
3. 首次运行时按住 Control 点按 App，选择“打开”。
4. 在 Dashboard 按提示安装 sing-box 内核与 TargetService。
5. 在 Profiles 导入 sing-box JSON，或添加受支持的订阅；选择 Profile 后回到 Dashboard 连接。

当前 Development Preview 7 的要求：

- macOS 15 或更高版本
- Apple Silicon（arm64）
- SHA-256：`c903291acd50d62bfc6d9d011e23ed70fdc101b9ec601e8112c9fe9f6217bf72`

你可以在下载目录验证文件：

```sh
shasum -a 256 Target-1.0.0-dev.7-macos-arm64.zip
```

> [!NOTE]
> 预览版尚未使用 Developer ID 公证。只有在你信任本仓库并核对校验值后才应继续打开。

## 安全设计

- Profile 长期存储经过认证加密，密钥由 macOS Keychain 管理。
- 订阅只接受通过安全策略检查的公共 HTTPS 地址；私网、本地地址和不安全重定向会被拒绝。
- 配置保存与启动前都会执行 `sing-box check`；无效修改不会覆盖上一有效版本。
- 订阅 URL、认证信息、私钥、本机路径和完整配置不会写入普通诊断或内核日志。
- 系统代理修改采用精确快照与所有权校验。恢复前若检测到其他程序改过设置，Target 会停止，而不是粗暴关闭全部代理。
- 本地运行时控制使用动态 loopback 端点和每次启动生成的认证信息，不向局域网暴露控制接口。

安全问题请通过 GitHub 的 [Private vulnerability reporting](SECURITY.md) 提交，不要在公开 Issue 中附上订阅、凭据或利用细节。

## 从源码构建

要求：

- macOS 15+
- Xcode 26.6+

```sh
git clone https://github.com/jason312928/Target.git
cd Target
xcodebuild -project Target.xcodeproj -scheme Target -configuration Debug build
```

安装唯一的本机 Debug 构建：

```sh
Scripts/install_local_app.sh
```

单独安装固定版本的 sing-box：

```sh
Target/Resources/Scripts/install_sing_box.sh
```

该脚本从 sing-box 官方 Release 下载固定版本、验证 SHA-256，并安装到用户的 Application Support 目录，全程不需要 `sudo`。

> [!TIP]
> 普通 Debug 构建默认处于 Host Safe Mode：可以构建和观察状态，但不会修改系统代理、DNS、路由、防火墙或 TUN。这是开发机保护机制，不是发布版行为。

## 当前边界

- **没有 TUN**：当前连接方式是本地 HTTP/SOCKS mixed listener + macOS 系统代理。
- **没有稳定发行版**：现有下载均用于开发测试，尚未完成 Developer ID 签名、公证与完整发布资格验证。
- **订阅兼容是有边界的**：复杂的服务商私有字段、路由和 DNS 行为可能需要手动调整。

## 项目结构

| 目录 | 作用 |
| --- | --- |
| `Target/` | SwiftUI App、Profile、运行时与系统集成 |
| `TargetCore/` | 本地自动化协议与传输 |
| `TargetCtl/` | `targetctl` 命令行客户端 |
| `TargetService/` | 权限受限的系统代理服务 |
| `TargetTests/` | 单元与集成测试 |
| `TargetPresentationUITests/` | 界面测试 |

## 许可证

Target 以 [GNU General Public License v3.0 or later](LICENSE) 发布。第三方声明见 [NOTICE](NOTICE) 与 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
