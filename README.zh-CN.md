# Target

[简体中文](README.zh-CN.md) | [English](README.en.md)

Target 是原生 SwiftUI macOS 客户端。它可通过 macOS Service Management API 注册受限的特权服务；不会修改路由、DNS、系统代理设置或网络流量。

## 构建要求

- macOS 15 或更高版本
- Xcode 26.6 或更高版本

构建应用：

```sh
xcodebuild -project Target.xcodeproj -scheme Target -configuration Debug build
```

注册 LaunchDaemon 需要有效签名和已公证的应用。在“系统设置 > 通用 > 登录项与扩展”中，管理员必须批准已注册的服务。本版本中的内核控制功能尚未实现。

## 许可证

Target 以 [GNU General Public License v3.0 or later](LICENSE) 发布。第三方声明请参见 [NOTICE](NOTICE)。
