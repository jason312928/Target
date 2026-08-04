# Target

[简体中文](README.zh-CN.md) | [English](README.en.md)

Target 是原生 SwiftUI macOS 代理客户端。当前应用展示模拟后端状态，不会安装服务，也不会修改路由、DNS、系统代理设置或网络流量。

## 构建要求

- macOS 15 或更高版本
- Xcode 26.6 或更高版本

使用无签名方式构建 Debug App：

```sh
xcodebuild -project Target.xcodeproj -scheme Target -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

## 许可证

Target 以 [GNU General Public License v3.0 or later](LICENSE) 发布。第三方声明请参见 [NOTICE](NOTICE)。
