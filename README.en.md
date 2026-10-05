<p align="center">
  <img src="Target/Assets.xcassets/AppIcon.appiconset/icon_256x256.png" width="128" height="128" alt="Target app icon">
</p>

<h1 align="center">Target</h1>

<p align="center">
  A quiet, explainable macOS workspace for your proxy.
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

Target is a native Swift and SwiftUI sing-box client for macOS. It brings Profiles, nodes, policies, and runtime state into one workspace: you can see where traffic is going, understand why a switch happened, and keep control when you need it. sing-box runs as the signed-in user, and Target changes the macOS System Proxy only after an explicit Connect action.

## What works today

- **One action into a connected state** — Connect starts the Target-owned sing-box runtime and establishes the system-proxy session. Disconnect and Restart share the same safe lifecycle.
- **A Profile workspace, not a file cabinet** — Create, import, export, duplicate, rename, and delete configurations, with JSON highlighting, formatting, diagnostics, version history, and previous-valid restore.
- **A map for your nodes** — Browse nodes and routes by country, test latency, choose the lowest-latency available node, and drag a website onto a country node to save a site route.
- **Smart Routing with a reason for every switch** — Smart Switch converges the selector for new connections using recent health, destination, and network evidence while preserving existing connections. Smart Apply confirms the selection first, then touches only connections with enough evidence to be safely replaceable; protected or uncertain connections stay intact.
- **Subscriptions made legible on your Mac** — Detect, convert, validate with `sing-box check`, and preview public HTTPS subscriptions locally without a third-party conversion service.
- **A small control room for runtime state** — The workspace sidebar shows active connections. A separate Diagnostics window provides Connections, Traffic, and Logs, with connection search/sorting/pause, traffic history, and log search. Open it from the toolbar or with `⌘⇧D`.
- **The macOS entry points you already use** — Menu bar controls, onboarding, Launch at Login, in-app updates, and English / Simplified Chinese localization.
- **One control plane for scripts too** — The bundled `targetctl` manages Profiles, subscriptions, policies, Smart actions, the engine, System Proxy, and runtime status through a local control plane.

Smart actions are explicit, one-shot controls. Target does not silently rewrite the selector in the background; when runtime evidence is unclear, it preserves the connection and tells you why.

## See the interface

The following image comes from Target's SwiftUI interface. To make it safe for public documentation, the Proxies image removes the local Profile label and adds a `DEMO DATA` caption. It contains no real subscription URL, node credential, or local path.

![Target Proxies: country map, node groups, and site routes](docs/screenshots/target-proxies-demo.png)

*Proxies turns nodes into a country map and a searchable list. The site-route area accepts a website URL dropped onto a country node.*

## A typical Target workflow

### 1. Turn a Profile into a runnable configuration

The Profiles workspace covers the path from “I have a JSON file” to “I am connected”:

1. Create a Profile, import JSON, or add a supported HTTPS subscription.
2. Edit JSON in Configuration with syntax highlighting, formatting, and error locations.
3. Run `sing-box check` before saving and before launch. If validation fails, the previous valid version stays in place.
4. Review the version history, restore the previous valid version when needed, then return to Overview or Proxies.
5. Start the engine from Dashboard or the Profile workspace; System Proxy can be enabled or disabled independently.

Long-term Profile storage uses authenticated encryption with a key managed by macOS Keychain. Import, export, duplicate, rename, and delete are all available from the same Profile action menu.

### 2. Choose nodes in Proxies instead of scanning a wall of labels

Proxies turns selectors into a readable choice surface. The map shows countries participating in the Profile aggregation, the country list shows node counts, and one search field filters countries and nodes together. Choosing a country prefers an available node with a measured lowest latency; you can also expand a country card and choose a specific node.

Each selector exposes its runtime state. If a saved selection has not been applied yet, the UI says that Apply or Restart is required; if runtime evidence is unavailable, the reason appears next to the selector. Use `Automatic` to restore the Profile's configured default.

Site routes persist a second layer of intent: drag a website URL onto a country node and Target stores the domain-to-country/node binding. If the bound node disappears, the route is marked unavailable instead of silently pointing somewhere else.

### 3. Smart Routing has two explicit actions

Smart is a visible menu in Proxies, not a background loop. The two actions separate “where should new connections go?” from “which existing connections are safe to touch?”

| Action | What it does | Connection behavior |
| --- | --- | --- |
| **Smart Switch** | Uses recent health, destination, network state, and failure penalties to produce and apply an explainable selector recommendation | Applies to new connections; existing connections stay alive |
| **Smart Apply** | Converges the selector first, then checks runtime evidence and continuity | Closes only individually verified, low-risk replaceable connections; protected or uncertain connections remain |

When evidence is unclear, the UI reports that it needs clearer runtime evidence or preserved the existing connection. It does not restart the whole engine just to make a switch look complete. The result also reports whether the selector changed, how many connections closed, and how many were preserved.

The CLI uses the same application operations:

```sh
targetctl smart shadow --json       # observe only; no selector mutation
targetctl smart apply --json        # apply one Smart Switch
targetctl smart continuity --json   # read continuity classifications
targetctl smart continuity apply --json
```

### 4. Preview a subscription before saving it

Subscription intake is a six-step flow: download, detect, convert, validate, preview, and confirm. Target generates a bounded sing-box configuration locally and shows node counts, supported protocols, skipped protocols, and compatibility warnings before changing a Profile.

Current support includes sing-box JSON, URI lists, Base64 URI lists, and Clash/Mihomo YAML. Node conversion covers Shadowsocks, VMess, VLESS, Trojan, and AnyTLS. SSR, Hysteria2/Hy2, and TUIC can be recognized and skipped when usable nodes remain. Provider-private rules, proxy groups, and DNS semantics are not presented as fully compatible when they are not.

### 5. See runtime behavior in Diagnostics

Diagnostics is a separate window, so runtime evidence does not get mixed into the Profile editor:

- **Connections** searches destinations, sorts by newest/destination/traffic, and pauses or resumes live refresh. Rows expose destination, network, outbound chain, and traffic counters.
- **Traffic** shows upload, download, and connection-count changes over time, helping distinguish one slow node from broad degradation.
- **Logs** filters runtime logs to locate startup, policy application, and System Proxy state changes.

The workspace sidebar keeps a compact active-connection summary; the full Diagnostics window opens from the toolbar or with `⌘⇧D`. Detail counts are bounded so diagnostics do not become a new runtime burden.

### 6. Native macOS entry points and automation

Target includes menu-bar controls, onboarding, Launch at Login, and Sparkle 2 in-app updates. The updater uses a fixed HTTPS appcast, EdDSA signatures, and preserves Profiles, selection state, ordinary preferences, and the Keychain encryption identity.

`targetctl` talks to the same local control plane as the app instead of maintaining a second CLI business layer. In addition to Smart actions, it can query status, manage Profiles, list/select policies, bind site routes, start/stop the engine, control System Proxy, and recover it:

```sh
targetctl status --json
targetctl profile list --json
targetctl policy list --json
targetctl route list --json
targetctl connect --json
targetctl proxy status --json
```

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
- **Smart is explicit for now** — Smart Switch and Smart Apply are user-triggered one-shot actions, not background automatic routing or adaptive retry.

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

## Fast regression tests

Run the same production domain sources without launching the app:

```bash
swift test --jobs 4 --scratch-path "${TMPDIR%/}/target-domain-build"
```

This lane covers persistence, subscriptions, automation, runtime, and interaction state. Smart, Sparkle updater, and foreground XCUI tests remain outside this lane; Xcode and the relevant isolated qualification remain authoritative for the application and OS integration.
