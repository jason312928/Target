# Target

[简体中文](README.zh-CN.md) | [English](README.en.md)

## Running with a Profile

The engine starts only from the selected Profile's latest valid version. Before launch, Target runs `sing-box check` again and creates a permission-restricted, one-run configuration copy. It changes only explicit `127.0.0.1` inbound listener ports to dynamic high ports; saved JSON is never rewritten. TUN, transparent proxying, non-localhost listeners, and absolute or traversing file paths are rejected.

The runtime record binds the Profile ID and revision to Target's PID, executable fingerprint, dynamic port, launch time, and configuration fingerprint. Target reports running only when every record matches. Editing, restoring, or switching Profiles leaves the live engine unchanged and requires an explicit restart. A running Profile cannot be deleted until the engine stops. Temporary configurations and records are removed after normal stop or failed launch, and logs redact URLs, credentials, keys, full paths, and full configuration content.

Target is a native SwiftUI macOS client. Its optional sing-box engine runs as the signed-in user and exposes a local mixed HTTP/SOCKS listener on an automatically selected high localhost port.

## Host Safe Mode and Normal User Mode

Development Debug builds without the UTM validation flag start in Host Safe Mode. They observe the local listener and service health but do not change system proxy, PAC, proxy discovery, DNS, routes, firewall, or TUN settings.

Release and Development Preview builds use Normal User Mode. When the user explicitly runs the main Start / Connect action, Target starts its owned engine and establishes the authoritative system-proxy connection for a normal connected session. Disconnect and Restart retain the safe system-proxy lifecycle: Target changes the macOS system proxy only while the Target-owned local proxy is reachable and no existing controller is detected, records the exact prior settings, and restores them only when ownership still matches. App launch, refresh, and background observation never take over the system network automatically.

Recovery is disabled unless Target has a validated, Target-owned snapshot. A recovery operation compares the current settings with Target's last written settings and stops on an external-change conflict; it never clears all proxies as a fallback.

## Profiles and configuration

Profiles are stored only in Target's Application Support container. A Profile can hold local JSON and an optional remote configuration URL. Target fetches that URL only when you explicitly start an update; it has no automatic, background, or scheduled updates. The production download path allows only public HTTPS addresses that meet Target's safety policy, uses no provider or domain whitelist, enforces time and size limits, and rejects unsafe sources and redirects. When available, conditional requests use `ETag` and `Last-Modified` metadata, including HTTP 304 semantics.

Downloaded content is locally detected within a bounded subset: sing-box JSON, URI lists, Base64 URI lists, and Clash YAML. Generic node subscriptions support Shadowsocks, VMess, VLESS, Trojan, and AnyTLS and are normalized into sing-box configuration. SSR, Hysteria2/Hy2, and TUIC nodes are explicitly reported as skipped when supported nodes remain; they are never silently converted into another protocol. Every candidate must still pass local format checks and `sing-box check`. Target first shows a redacted structural preview; until you confirm, it neither replaces the current valid configuration nor creates a new revision. After confirmation, the configuration is saved as a new valid version in the existing history and can use the usual restore flow. You can cancel an update in progress. Target is not a universal provider converter, and provider-specific advanced or routing semantics may not be fully imported.

The editor provides JSON syntax highlighting, line numbers, formatting, validation diagnostics, and previous-valid-version restore. Target stores configuration text as raw UTF-8 JSON, so fields unknown to this app remain intact. Each save first runs the official `sing-box check` command against a Target-managed staging file. A failed syntax or sing-box check never replaces the last valid JSON. Diagnostic and engine log handling redacts credentials, URLs, passwords, UUIDs, private keys, and local paths.

New Profiles begin with a safe example: a dynamic `127.0.0.1` mixed listener and a `direct` outbound. It does not enable a system proxy, TUN, DNS takeover, route changes, or firewall changes.

For a valid sing-box selector, Target can save the desired member as encrypted Profile metadata without rewriting the source Profile JSON or creating a new configuration revision. You can use Profile Defaults to remove all Target-owned selector choices and return to the Profile's own defaults. Neither action hot-switches or restarts a running engine; Target continues to show the authoritative running choice and applies the desired choice only after an explicit engine restart.

## Build requirements

- macOS 15 or later
- Xcode 26.6 or later

Build the app:

```sh
xcodebuild -project Target.xcodeproj -scheme Target -configuration Debug build
```

### Canonical local installation

Install one local, unsigned Debug build at `/Applications/Target.app` from a clean
checkout:

```sh
Scripts/install_local_app.sh
```

The installer uses a dedicated `.noindex` DerivedData directory, records the source
commit in the app metadata, replaces only the canonical app bundle, and archives or
removes validated old Target build products. It does not register TargetService or
change system-network settings. This is a local development build, not a signed
release distribution.

For a local engine installation, run the bundled installer from the repository root:

```sh
Target/Resources/Scripts/install_sing_box.sh
```

It downloads the pinned sing-box 1.13.16 archive from the official sing-box GitHub release, verifies its SHA-256, selects Apple Silicon or Intel automatically, and installs it without `sudo` to `~/Library/Application Support/Target/sing-box`. The app generates its own minimal configuration there and binds its mixed SOCKS/HTTP listener to an available high localhost port with a direct outbound.

## License

Target is licensed under the [GNU General Public License v3.0 or later](LICENSE). See [NOTICE](NOTICE) for third-party notices.
