# Target

[简体中文](README.zh-CN.md) | [English](README.en.md)

Target is a native macOS proxy client. This source tree currently provides a SwiftUI macOS application and a minimal Packet Tunnel Provider extension lifecycle surface.

## Available capabilities

The application presents start and stop controls for a configured Packet Tunnel Provider. The provider implementation is intentionally minimal and does not proxy traffic, configure DNS, apply rules, or manage nodes.

## Build requirements

- macOS 15 or later
- Xcode 26.6 or later
- An Apple development team with the Network Extension capability to sign and run the Packet Tunnel Provider on a device

Open `Target.xcodeproj` in Xcode, choose your development team for both targets, then build the `Target` scheme.

## License

Target is licensed under the [GNU General Public License v3.0 or later](LICENSE). See [NOTICE](NOTICE) for third-party notices.
