# Target

[简体中文](README.zh-CN.md) | [English](README.en.md)

Target is a native SwiftUI macOS proxy client. The app currently presents a mock backend state and does not install a service or change routes, DNS, system proxy settings, or network traffic.

## Build requirements

- macOS 15 or later
- Xcode 26.6 or later

Build the Debug app without code signing:

```sh
xcodebuild -project Target.xcodeproj -scheme Target -configuration Debug CODE_SIGNING_ALLOWED=NO build
```

## License

Target is licensed under the [GNU General Public License v3.0 or later](LICENSE). See [NOTICE](NOTICE) for third-party notices.
