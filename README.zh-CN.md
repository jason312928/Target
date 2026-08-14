# Target

[简体中文](README.zh-CN.md) | [English](README.en.md)

Target 是原生 SwiftUI macOS 客户端。可选的 sing-box 引擎以当前用户身份运行，并在自动选择的高位 localhost 端口提供本地 HTTP/SOCKS mixed 监听。

## 宿主安全模式

Target 默认进入宿主安全模式：仅观测本地监听和服务健康状态，不修改系统代理、PAC、自动代理发现、DNS、路由、防火墙或 TUN。检测到现有系统代理或其他代理应用时，Target 会拒绝接管网络；安全模式下系统代理控件保持禁用。

仅在 Target 持有已验证且归属明确的快照时，才允许恢复操作。恢复前会比较当前设置与 Target 最后写入的设置；若发现外部修改便停止，且绝不会以“关闭全部代理”作为替代方案。

## Profile 与配置

Profile 仅存放在 Target 的 Application Support 容器中。Profile 可保存本地 JSON 和可选的远程配置地址。Target 仅在用户明确发起更新时下载该地址；不会自动、后台或定时更新。生产下载路径只接受符合 Target 安全策略的公共 HTTPS 地址，不依赖服务商或域名白名单，并具有超时和响应大小限制，拒绝不安全来源或重定向。可用时，条件请求会使用 `ETag`、`Last-Modified` 元数据及 HTTP 304 语义。

下载内容会在本地自动识别一个有限子集：sing-box JSON、URI 列表、Base64 URI 列表和 Clash YAML。通用节点订阅当前支持 Shadowsocks、VMess、VLESS 和 Trojan，并归一化为 sing-box 配置；所有候选配置仍必须通过本地格式检查和 `sing-box check`。Target 会先显示脱敏的结构变化预览；用户确认前，既不会替换当前有效配置，也不会创建新版本。确认后，配置会作为新的有效版本写入既有历史，并可使用原有恢复流程。用户可以取消正在进行的更新。Target 不是通用服务商转换器，服务商专用的高级语义和路由语义可能不会完整导入。

编辑器提供 JSON 语法高亮、行号、格式化、验证诊断及上一有效版本恢复。Target 将配置按原始 UTF-8 JSON 保存，因此不会丢失本 App 不认识的字段。每次保存都先在 Target 管理的临时文件上调用官方 `sing-box check`；JSON 语法或 sing-box 验证失败都不会覆盖上一份有效配置。诊断与内核日志会脱敏认证信息、URL、密码、UUID、私钥和本机路径。

新建 Profile 使用安全示例配置：动态 `127.0.0.1` mixed 监听和 `direct` outbound；不会启用系统代理、TUN、DNS 接管、路由或防火墙修改。

对于结构有效的 sing-box selector，Target 可将期望成员保存为加密的 Profile 元数据，不会改写源 Profile JSON，也不会仅因策略选择而创建新配置版本。可使用“恢复 Profile 默认策略”移除全部由 Target 保存的选择并恢复 Profile 自己的默认值。两种操作都不会热切换或自动重启正在运行的引擎；Target 会继续显示经验证的当前运行选择，并仅在用户明确重启引擎后应用期望选择。

## 使用 Profile 运行引擎

启动引擎时，Target 只会采用当前选中 Profile 的最近有效版本。启动前会再次用 `sing-box check` 验证，并为本次运行生成受限权限的临时配置副本；副本仅将显式的 `127.0.0.1` 入站监听端口替换为 Target 动态高位端口，绝不改写保存的原始 JSON。包含 TUN、透明代理、非 localhost 监听或绝对/越界文件路径的配置会被拒绝。

运行记录绑定 Profile ID、有效版本、Target 启动的 PID、可执行文件指纹、动态端口、启动时间和配置指纹。只有这些记录与进程及端口都匹配时才显示“运行中”。编辑、恢复版本或切换 Profile 不会改变已运行的引擎；界面会提示重启。正在使用的 Profile 必须先停止引擎才可删除。停止或启动失败后，Target 会清理其临时配置和运行记录；日志不会显示订阅 URL、认证信息、私钥、完整路径或完整配置。

## 构建要求

- macOS 15 或更高版本
- Xcode 26.6 或更高版本

构建应用：

```sh
xcodebuild -project Target.xcodeproj -scheme Target -configuration Debug build
```

### 唯一本机安装

从干净的仓库检出安装唯一的本机 unsigned Debug 构建到
`/Applications/Target.app`：

```sh
Scripts/install_local_app.sh
```

该脚本使用专用 `.noindex` DerivedData 目录，将源码提交写入 App 元数据，只替换
canonical App bundle，并归档或移除已验证的旧 Target 构建产物。它不会注册
TargetService，也不会修改系统网络设置。这是本机开发构建，不是正式签名发布版本。

如需在本机安装引擎，请从仓库根目录运行随附的安装脚本：

```sh
Target/Resources/Scripts/install_sing_box.sh
```

脚本仅从官方 sing-box GitHub Release 下载固定的 sing-box 1.13.16，校验 SHA-256，自动识别 Apple Silicon 或 Intel，并在无需 `sudo` 的情况下安装到 `~/Library/Application Support/Target/sing-box`。App 只会在该目录创建一次性运行配置，并以当前 Profile 在可用的高位 localhost 端口提供 SOCKS/HTTP 混合监听。

## 许可证

Target 以 [GNU General Public License v3.0 or later](LICENSE) 发布。第三方声明请参见 [NOTICE](NOTICE)。
