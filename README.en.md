# Target

[简体中文](README.zh-CN.md) | [English](README.en.md)

Target is a native SwiftUI macOS client. Its optional sing-box engine runs as the signed-in user and exposes a local mixed HTTP/SOCKS listener at `127.0.0.1:2080`.

## Host Safe Mode

Target starts in Host Safe Mode. It observes the local listener and service health but does not change system proxy, PAC, proxy discovery, DNS, routes, firewall, or TUN settings. If an existing system proxy or another proxy application is detected, Target refuses to take over the network. System-proxy controls remain disabled in Safe Mode.

Recovery is disabled unless Target has a validated, Target-owned snapshot. A recovery operation compares the current settings with Target's last written settings and stops on an external-change conflict; it never clears all proxies as a fallback.

## Build requirements

- macOS 15 or later
- Xcode 26.6 or later

Build the app:

```sh
xcodebuild -project Target.xcodeproj -scheme Target -configuration Debug build
```

For a local engine installation, run the bundled installer from the repository root:

```sh
Target/Resources/Scripts/install_sing_box.sh
```

It downloads the pinned sing-box 1.13.16 archive from the official sing-box GitHub release, verifies its SHA-256, selects Apple Silicon or Intel automatically, and installs it without `sudo` to `~/Library/Application Support/Target/sing-box`. The app generates its own minimal configuration there and binds its mixed SOCKS/HTTP listener to `127.0.0.1:2080` with a direct outbound.

## License

Target is licensed under the [GNU General Public License v3.0 or later](LICENSE). See [NOTICE](NOTICE) for third-party notices.
