<img src="assets/icon.svg" width="64" height="64" alt="">

# Locally Remote

A headless macOS CLI and LaunchAgent that bridges Apple's CoreDevice wireless debugging stack over Tailscale. Once you pair an iPhone with a Mac locally, you can build, install, and run apps on that phone from Xcode, `xcrun devicectl`, `xcodebuild`, or `sweetpad --remote` while the phone sits on another Wi-Fi network.

It runs as an unprivileged user process without `sudo`, kernel extensions, or a companion iOS app.

## Why CoreDevice Breaks Over Tailscale

Xcode 15+ and iOS 17+ communicate over `remotepairingd` and CoreDevice tunnels instead of direct IP lockdown connections. Two behaviors break over a Layer 3 mesh VPN:

1. `remotepairingd` discovers devices through `_remotepairing._tcp` mDNS broadcasts, and Tailscale does not forward link-local multicast.
2. When `remotepairingd` resolves a Bonjour service on a local interface such as `en1`, Apple's Network framework scopes the outgoing TCP socket to that interface. Advertising a `100.x.y.z` Tailscale IP in Bonjour sends SYN packets out the Wi-Fi gateway instead of the Tailscale `utun` interface.

## How Locally Remote Works

You capture the phone's `_remotepairing._tcp` Bonjour record once while the Mac and iPhone share a local Wi-Fi network. `locally-remote` stores the service `identifier`, `authTag`, protocol version fields, paired UDID from `xcrun devicectl`, and Tailscale peer identity in `~/.config/locally-remote/config.json`.

When the background daemon runs:

- While the phone is visible on a physical LAN interface (`en0`, `en1`, etc.), the daemon stays in standby and updates the saved Bonjour record whenever the phone rotates its `authTag`. Local builds stay on native Wi-Fi.
- After the phone leaves the local LAN and becomes reachable on Tailscale, the daemon raises its file-descriptor limit, binds a `kqueue` TCP relay across ports `49152-65499` on `fe80::1%lo0`, and registers the saved `_remotepairing._tcp` service plus an `AAAA` record scoped to `lo0` through Apple's `dnssd` C API.
- `remotepairingd` discovers the `lo0` advertisement, verifies the replayed `authTag` against its stored `CUPairedPeer` key, connects to `[fe80::1%lo0]:49152` for Pair-Verify, and connects to `[fe80::1%lo0]:<ephemeral-port>` for the negotiated CoreDevice TLS-PSK tunnel. The relay forwards both connections to the phone's Tailscale IP on the matching port.

Because `fe80::1%lo0` is separate from `127.0.0.1` and `::1`, binding `49152-65499` does not interfere with IPv4 or IPv6 localhost traffic, and leaving `65500-65535` unbound gives `remotepairingd` free source ports on `fe80::1%lo0`.

### Wi-Fi Requirement on iOS

iOS shuts down `remotepairingd` (port `49152`) and `lockdownd` (port `62078`) when Wi-Fi is completely turned off. To start a new remote session, the iPhone must be connected to any Wi-Fi network (office, hotel, coffee shop, guest network, or another device's hotspot) with Tailscale enabled. An already active tunnel can survive a handoff to cellular, though starting cold requires Wi-Fi.

## Requirements

- macOS 14 or newer with Xcode Command Line Tools (`xcrun devicectl`, `swift`)
- Tailscale installed and running on both the Mac and the iPhone on the same tailnet
- iPhone previously paired with the Mac over USB or local Wi-Fi, with Developer Mode enabled

## Install

### Homebrew

```bash
brew install nailington/tap/locally-remote
```

You can start the daemon with either `locally-remote install-agent` or `brew services start locally-remote`.

### macOS Installer Package (.pkg)

Download `locally-remote-<version>-macos-universal.pkg` from the [GitHub Releases](https://github.com/Nailington/Locally-Remote/releases) page. Double-click it to install `/usr/local/bin/locally-remote`, or run it headlessly:

```bash
sudo installer -pkg locally-remote-<version>-macos-universal.pkg -target /
```

### Shell Script

Downloads the latest universal tarball, verifies its SHA256 checksum, and installs to `~/.local/bin/locally-remote`:

```bash
curl -fsSL https://raw.githubusercontent.com/Nailington/Locally-Remote/main/scripts/install.sh | sh
```

### Build From Source

```bash
swift build -c release
mkdir -p ~/.local/bin
cp .build/release/locally-remote ~/.local/bin/locally-remote.new
mv -f ~/.local/bin/locally-remote.new ~/.local/bin/locally-remote
```

### Shell Completions

Homebrew installs zsh, bash, and fish completions into Homebrew's completion directories, and the `.pkg` installer installs zsh completions to `/usr/local/share/zsh/site-functions/_locally-remote`.

To install completions directly for your current shell (or wire `~/.zshrc` when needed):

```bash
# Built-in one-time command
locally-remote completions install

# Or run the standalone completion installer script
curl -fsSL https://raw.githubusercontent.com/Nailington/Locally-Remote/main/scripts/install-completions.sh | sh
```

To print a completion script to stdout for manual placement, run `locally-remote completions zsh`, `locally-remote completions bash`, or `locally-remote completions fish`.

## Quick Start

Run these commands on the Mac while the iPhone is unlocked on the same local Wi-Fi network:

```bash
# Capture the phone's Bonjour record and link it to its Tailscale peer
locally-remote capture

# Install and start the background LaunchAgent
locally-remote install-agent

# Verify setup
locally-remote doctor
locally-remote status
```

## Using With Xcode, devicectl, and SweetPad

Because `remotepairingd` creates the standard CoreDevice `utun` and RSD device once connected through the relay, standard tooling works with the device UDID unchanged:

```bash
# Directly on the Mac
xcrun devicectl list devices
xcrun devicectl device info details --device <DEVICE_UDID>

# From a remote Linux/Windows/macOS workstation using sweetpad-remote
sweetpad device info <DEVICE_UDID> --remote "<Remote Mac>" --timeout 20 -o json --non-interactive
sweetpad run --remote "<Remote Mac>" --scheme <Scheme> --on <DEVICE_UDID> --detach -o json --non-interactive
```

## Documentation and Agent Skills

- [skills/locally-remote/SKILL.md](skills/locally-remote/SKILL.md) provides concise operating instructions for coding agents using `locally-remote`.
- [docs/architecture.md](docs/architecture.md) covers the CoreDevice wire flow, Bonjour replay mechanics, `fe80::1%lo0` port isolation, and bind modes.
- [docs/cli-reference.md](docs/cli-reference.md) lists all commands, flags, exit codes, and JSON schemas.
- [docs/troubleshooting.md](docs/troubleshooting.md) documents failure modes, unified log predicates, and the `--bind lan` fallback.
