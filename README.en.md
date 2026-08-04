# Target

[简体中文](README.zh-CN.md) | [English](README.en.md)

## Running with a Profile

The engine starts only from the selected Profile's latest valid version. Before launch, Target runs `sing-box check` again and creates a permission-restricted, one-run configuration copy. It changes only explicit `127.0.0.1` inbound listener ports to dynamic high ports; saved JSON is never rewritten. TUN, transparent proxying, non-localhost listeners, and absolute or traversing file paths are rejected.

The runtime record binds the Profile ID and revision to Target's PID, executable fingerprint, dynamic port, launch time, and configuration fingerprint. Target reports running only when every record matches. Editing, restoring, or switching Profiles leaves the live engine unchanged and requires an explicit restart. A running Profile cannot be deleted until the engine stops. Temporary configurations and records are removed after normal stop or failed launch, and logs redact URLs, credentials, keys, full paths, and full configuration content.

Target is a native SwiftUI macOS client. Its optional sing-box engine runs as the signed-in user and exposes a local mixed HTTP/SOCKS listener on an automatically selected high localhost port.

## Host Safe Mode

Target starts in Host Safe Mode. It observes the local listener and service health but does not change system proxy, PAC, proxy discovery, DNS, routes, firewall, or TUN settings. If an existing system proxy or another proxy application is detected, Target refuses to take over the network. System-proxy controls remain disabled in Safe Mode.

Recovery is disabled unless Target has a validated, Target-owned snapshot. A recovery operation compares the current settings with Target's last written settings and stops on an external-change conflict; it never clears all proxies as a fallback.

## Profiles and configuration

Profiles are stored only in Target's Application Support container. A Profile can hold local JSON and optional remote subscription metadata; this release never fetches or parses subscriptions. The selected Profile, validation result, update timestamp, and valid configuration revisions are retained locally.

The editor provides JSON syntax highlighting, line numbers, formatting, validation diagnostics, and previous-valid-version restore. Target stores configuration text as raw UTF-8 JSON, so fields unknown to this app remain intact. Each save first runs the official `sing-box check` command against a Target-managed staging file. A failed syntax or sing-box check never replaces the last valid JSON. Diagnostic and engine log handling redacts credentials, URLs, passwords, UUIDs, private keys, and local paths.

New Profiles begin with a safe example: a dynamic `127.0.0.1` mixed listener and a `direct` outbound. It does not enable a system proxy, TUN, DNS takeover, route changes, or firewall changes.

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

It downloads the pinned sing-box 1.13.16 archive from the official sing-box GitHub release, verifies its SHA-256, selects Apple Silicon or Intel automatically, and installs it without `sudo` to `~/Library/Application Support/Target/sing-box`. The app generates its own minimal configuration there and binds its mixed SOCKS/HTTP listener to an available high localhost port with a direct outbound.

## License

Target is licensed under the [GNU General Public License v3.0 or later](LICENSE). See [NOTICE](NOTICE) for third-party notices.
