<p align="center">
  <img src="Target/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="128" height="128" alt="Target app icon">
</p>

<h1 align="center">Target</h1>

<p align="center">
  A native, focused, safety-minded sing-box client for macOS.
</p>

<p align="center">
  <a href="README.md">简体中文</a> · <a href="README.en.md">English</a> · <a href="https://github.com/jason312928/Target/releases">Download</a>
</p>

<p align="center">
  <img alt="Platform" src="https://img.shields.io/badge/macOS-15%2B-111111?logo=apple">
  <img alt="Swift" src="https://img.shields.io/badge/Swift-SwiftUI-F05138?logo=swift&logoColor=white">
  <img alt="Release" src="https://img.shields.io/badge/status-Development%20Preview-F59E0B">
  <img alt="License" src="https://img.shields.io/badge/license-GPL--3.0--or--later-2EA44F">
</p>

> [!IMPORTANT]
> Target is currently a **Development Preview**, not a stable release. The latest preview is Apple silicon only, Apple Development signed, and not notarized. macOS may require you to explicitly allow it to open.

## About Target

Target is a native Swift and SwiftUI macOS client for Profile management, subscription import, policy selection, runtime observability, and System Proxy control. sing-box runs as the signed-in user, and Target changes the macOS System Proxy only after an explicit Connect action.

## What works today

- **One-action connection** — Connect starts the Target-owned sing-box runtime and establishes the system-proxy session. Disconnect and Restart use the same safe lifecycle.
- **A complete Profile workspace** — Create, import, export, duplicate, rename, and delete configurations, with JSON highlighting, line numbers, formatting, diagnostics, version history, and previous-valid restore.
- **Local subscription intake** — Detect, convert, validate with `sing-box check`, and preview subscriptions locally without a third-party conversion service.
- **Proxy and policy controls** — Browse sing-box selectors, search and filter nodes, inspect latency and health, and switch the active runtime policy.
- **Live observability** — Dashboard shows rates, totals, and active connections; Connections, Traffic, and Logs provide focused runtime views.
- **Native macOS integration** — Menu bar controls, onboarding, Launch at Login, in-app updates, and English / Simplified Chinese localization.
- **Automation** — The bundled `targetctl` manages Profiles, subscriptions, policies, the engine, System Proxy, and runtime status through a local control plane.

## Subscription compatibility

Target validates downloaded content and presents a redacted change summary. It creates a Profile or saves a new version only after confirmation.

| Area | Current support |
| --- | --- |
| Formats | sing-box JSON, URI lists, Base64 URI lists, Clash / Mihomo YAML |
| Protocols | Shadowsocks, VMess, VLESS, Trojan, AnyTLS |
| Recognized but skipped | SSR, Hysteria2 / Hy2, TUIC, when usable nodes remain |

Provider-specific rules, groups, and DNS semantics are not imported wholesale. Target generates its own bounded sing-box Profile. It is not a universal subscription converter and does not refresh subscriptions automatically in the background.

## Quick start

### Download a preview

1. Download `Target-1.0.0-dev.10-macos-arm64.zip` from [Development Preview 10](https://github.com/jason312928/Target/releases/tag/v1.0.0-dev.10).
2. Extract it and move `Target.app` to Applications.
3. On first launch, Control-click the app and choose Open.
4. Follow the Dashboard prompts to install the sing-box engine and TargetService.
5. Import sing-box JSON or add a supported subscription in Profiles, select it, then return to Dashboard and connect.

Development Preview 10 requires:

- macOS 15 or later
- Apple silicon (arm64)
- SHA-256: `2461080ccc0bb2939369b1d9bee5c7de8c8482b08163fc9a53c8b10b1a054efb`

Verify the download from its directory:

```sh
shasum -a 256 Target-1.0.0-dev.10-macos-arm64.zip
```

> [!NOTE]
> The preview is not Developer ID notarized. Continue only if you trust this repository and have verified the checksum.

## Safety model

- Long-term Profile storage is authenticated and encrypted using a key managed by macOS Keychain.
- Subscription URLs must be public HTTPS endpoints that pass Target's safety policy; private or local origins and unsafe redirects are rejected.
- Target runs `sing-box check` before saving or launching a configuration. Invalid edits never replace the last valid version.
- Subscription URLs, credentials, private keys, full local paths, and complete configurations are redacted from ordinary diagnostics and engine logs.
- System Proxy changes use an exact snapshot and ownership checks. If another app changes the settings, Target stops recovery instead of indiscriminately disabling every proxy.
- Runtime control uses a dynamic loopback endpoint and fresh per-launch authentication; it is not exposed to the local network.

Report security issues through GitHub [Private vulnerability reporting](SECURITY.md). Do not put subscriptions, credentials, or exploit details in a public issue.

## Build from source

Requirements:

- macOS 15+
- Xcode 26.6+

```sh
git clone https://github.com/jason312928/Target.git
cd Target
xcodebuild -project Target.xcodeproj -scheme Target -configuration Debug build
```

Install a single canonical local Debug build:

```sh
Scripts/install_local_app.sh
```

Install the pinned sing-box version separately:

```sh
Target/Resources/Scripts/install_sing_box.sh
```

The script downloads the pinned binary from the official sing-box release, verifies its SHA-256, and installs it under the user's Application Support directory without `sudo`.

> [!TIP]
> Regular Debug builds default to Host Safe Mode. They can build and observe state but will not change System Proxy, DNS, routes, firewall, or TUN. This protects the development Mac and is not the behavior of a release build.

## Current limits

- **No TUN** — Target currently uses a local HTTP/SOCKS mixed listener plus the macOS System Proxy.
- **No stable distribution** — Current downloads are for development testing and have not completed Developer ID signing, notarization, or full release qualification.
- **Bounded subscription support** — Complex provider-specific fields, routing, and DNS behavior may need manual adjustment.

## Repository map

| Path | Purpose |
| --- | --- |
| `Target/` | SwiftUI app, Profiles, runtime, and system integration |
| `TargetCore/` | Local automation protocol and transport |
| `TargetCtl/` | `targetctl` command-line client |
| `TargetService/` | Narrow privileged System Proxy service |
| `TargetTests/` | Unit and integration tests |
| `TargetPresentationUITests/` | UI tests |

## License

Target is available under the [GNU General Public License v3.0 or later](LICENSE). See [NOTICE](NOTICE) and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for third-party notices.
