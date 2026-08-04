# Target

[简体中文](README.zh-CN.md) | [English](README.en.md)

Target is a native SwiftUI macOS client. It can register its narrow privileged service using the macOS Service Management API. It does not change routes, DNS, system proxy settings, or network traffic.

## Build requirements

- macOS 15 or later
- Xcode 26.6 or later

Build the app:

```sh
xcodebuild -project Target.xcodeproj -scheme Target -configuration Debug build
```

LaunchDaemon registration requires a valid signing identity and a notarized app. In System Settings, an administrator must approve a registered service under General > Login Items & Extensions. The engine controls are intentionally not implemented in this release.

## License

Target is licensed under the [GNU General Public License v3.0 or later](LICENSE). See [NOTICE](NOTICE) for third-party notices.
