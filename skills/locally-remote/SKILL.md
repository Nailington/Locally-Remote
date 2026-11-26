---
name: locally-remote
description: Manage and verify remote iOS device bridging over Tailscale using the locally-remote macOS CLI and LaunchAgent. Use when setting up, checking, waking, or troubleshooting wireless Xcode, devicectl, or sweetpad-remote builds to a paired iPhone on a different network.
---

# Locally Remote

`locally-remote` runs on a build Mac and bridges Apple's `remotepairingd` and CoreDevice tunnels over Tailscale. Once active, Xcode, `xcrun devicectl`, `xcodebuild`, and `sweetpad --remote` target the remote iOS device by its standard UDID with no wrapper commands.

## Prerequisites

- Check for the CLI on the Mac with `locally-remote --version`. To install it with Homebrew, run `brew install nailington/tap/locally-remote`.
- The iOS device was paired with the Mac at least once over USB or local Wi-Fi and has Developer Mode enabled.
- Both the Mac and the iOS device are signed into the same Tailscale tailnet.
- To start a new remote session, the iOS device must be on any Wi-Fi network with Tailscale enabled. iOS stops listening on TCP port `49152` when Wi-Fi is completely off.

## Check Bridge Health First

Before building to a remote physical device, run `doctor` and `status` in JSON mode on the Mac (locally or over SSH):

```bash
locally-remote doctor --json
locally-remote status --json
```

Read `status --json` fields:

- `daemonRunning`: `true` when the background daemon process is alive.
- `runtime.devices[].phase`:
  - `local_lan`: device is on the Mac's home Wi-Fi; native LAN path is active.
  - `bridged`: Tailscale relay and `lo0` Bonjour proxy are active. Check `boundPortCount`, `activeConnections`, and `activeTunnelPorts`.
  - `unreachable`: Tailscale peer is online, but TCP port `49152` refused or timed out. Usually means Wi-Fi is off on the iPhone or the phone is deeply asleep.
  - `tailscale_offline`: Tailscale reports the peer offline.
  - `error`: local bind or Bonjour registration failed; inspect `detail`.

## Initial Setup (One Time on Shared Wi-Fi)

Run while the Mac and iPhone share the same local Wi-Fi network:

```bash
locally-remote capture --json
locally-remote install-agent
locally-remote doctor --json
```

If multiple paired iOS devices or Tailscale peers exist, disambiguate explicitly:

```bash
locally-remote capture --device <DEVICE_UDID> --tailscale-peer <TAILSCALE_NAME_OR_IP> --json
```

## Wake and Verify Before Building

Use `wake` to verify Tailscale TCP reachability and ask `devicectl` to bring up the CoreDevice tunnel:

```bash
locally-remote wake --device <DEVICE_UDID> --timeout 20 --json
```

Branch on the JSON output:

- `ready: true`: device is unlocked and CoreDevice tunnel is up; proceed with `xcodebuild`, `devicectl`, or `sweetpad run`.
- `locked: true`: tunnel reached the device, but iOS requires the screen to be unlocked before installing or launching. Ask the user to unlock the phone.
- `ready: false` and `tcpReachable: false`: check that the phone is connected to Wi-Fi and Tailscale is active on both sides.

## Using With sweetpad-remote

When running SweetPad from a remote workstation against a build Mac that has the `locally-remote` LaunchAgent running, target the iOS device UDID directly:

```bash
sweetpad device info <DEVICE_UDID> --remote "<Remote Mac>" --timeout 20 -o json --non-interactive
sweetpad run --remote "<Remote Mac>" --scheme <Scheme> --on <DEVICE_UDID> --detach -o json --non-interactive
```

## Common Remediation

- If `daemonRunning` is `false`, install or reload the LaunchAgent with `locally-remote install-agent`.
- If `remotepairingd` rejects `lo0` as a virtual interface delegate on a specific macOS version, switch the LaunchAgent to bind the active physical LAN interface's link-local IPv6 address:
  ```bash
  locally-remote install-agent --bind lan
  ```
- To test the Tailscale relay path while the phone is still on the Mac's local Wi-Fi, run the daemon in the foreground with `--force-bridge --verbose`.

## Deeper Documentation

- [docs/architecture.md](../../docs/architecture.md): CoreDevice protocol flow, Bonjour `authTag` replay, and `fe80::1%lo0` port relay design.
- [docs/cli-reference.md](../../docs/cli-reference.md): Full subcommands, flags, exit codes, and config/state JSON schemas.
- [docs/troubleshooting.md](../../docs/troubleshooting.md): Diagnostic log predicates and failure recovery steps.
