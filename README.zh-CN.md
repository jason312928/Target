# Target

[简体中文](README.zh-CN.md) | [English](README.en.md)

Target 是原生 SwiftUI macOS 客户端。可选的 sing-box 引擎以当前用户身份运行，并在自动选择的高位 localhost 端口提供本地 HTTP/SOCKS mixed 监听。

## 宿主安全模式

Target 默认进入宿主安全模式：仅观测本地监听和服务健康状态，不修改系统代理、PAC、自动代理发现、DNS、路由、防火墙或 TUN。检测到现有系统代理或其他代理应用时，Target 会拒绝接管网络；安全模式下系统代理控件保持禁用。

仅在 Target 持有已验证且归属明确的快照时，才允许恢复操作。恢复前会比较当前设置与 Target 最后写入的设置；若发现外部修改便停止，且绝不会以“关闭全部代理”作为替代方案。

## Profile 与配置

Profile 仅存放在 Target 的 Application Support 容器中。Profile 可保存本地 JSON 和可选的远程订阅元数据；本版本不会联网更新或解析订阅。本地会保留当前选中的 Profile、验证结果、更新时间和有效配置版本。

编辑器提供 JSON 语法高亮、行号、格式化、验证诊断及上一有效版本恢复。Target 将配置按原始 UTF-8 JSON 保存，因此不会丢失本 App 不认识的字段。每次保存都先在 Target 管理的临时文件上调用官方 `sing-box check`；JSON 语法或 sing-box 验证失败都不会覆盖上一份有效配置。诊断与内核日志会脱敏认证信息、URL、密码、UUID、私钥和本机路径。

新建 Profile 使用安全示例配置：动态 `127.0.0.1` mixed 监听和 `direct` outbound；不会启用系统代理、TUN、DNS 接管、路由或防火墙修改。

## 构建要求

- macOS 15 或更高版本
- Xcode 26.6 或更高版本

构建应用：

```sh
xcodebuild -project Target.xcodeproj -scheme Target -configuration Debug build
```

如需在本机安装引擎，请从仓库根目录运行随附的安装脚本：

```sh
Target/Resources/Scripts/install_sing_box.sh
```

脚本仅从官方 sing-box GitHub Release 下载固定的 sing-box 1.13.16，校验 SHA-256，自动识别 Apple Silicon 或 Intel，并在无需 `sudo` 的情况下安装到 `~/Library/Application Support/Target/sing-box`。App 只会在该目录生成最小配置，并以 direct outbound 在可用的高位 localhost 端口提供 SOCKS/HTTP 混合监听。

## 许可证

Target 以 [GNU General Public License v3.0 or later](LICENSE) 发布。第三方声明请参见 [NOTICE](NOTICE)。
