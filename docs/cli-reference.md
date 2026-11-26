# CLI Reference

All commands run on macOS. Read commands accept `--json` for structured output.

## Commands

### `locally-remote capture`

Captures a paired iPhone's `_remotepairing._tcp` Bonjour record on local Wi-Fi, correlates it with `xcrun devicectl`, links it to its Tailscale peer, and saves it to `~/.config/locally-remote/config.json`.

Flags:

- `--device <ref>`: filter by device UDID, CoreDevice identifier, or substring of device name.
- `--tailscale-peer <ref>`: select a Tailscale peer by hostname, DNS name, or IP address.
- `--timeout <sec>`: Bonjour browse timeout in seconds (default `6`).
- `--json`: print the saved `SavedDevice` object as JSON.

### `locally-remote daemon`

Runs the bridge controller in the foreground. Stops on `SIGINT` or `SIGTERM`, deregisters Bonjour records, closes listening sockets, and removes `state.json`.

Flags:

- `--force-bridge`: activate the Tailscale bridge even when the device is present on local Wi-Fi.
- `--bind <lo0|lan|loopback4>`: override `bindMode` from config (default `lo0`).
- `--port-range <start:end>`: override local relay port range (default `49152:65499`).
- `--poll-interval <sec>`: reconciliation interval in seconds (default `5`).
- `--verbose`: log every proxied control and tunnel connection to stderr.

### `locally-remote status`

Reports config path, LaunchAgent status, whether the daemon PID is alive, and live per-device bridge metrics from `state.json`.

Flags:

- `--json`: emit `StatusPayload` JSON.

### `locally-remote devices`

Lists saved devices, live `xcrun devicectl list devices` entries, and Tailscale iOS peers side by side.

Flags:

- `--json`: emit `DevicesPayload` JSON.

### `locally-remote wake`

Checks TCP reachability on the device's Tailscale IP and runs `xcrun devicectl device info details` to establish the CoreDevice tunnel.

Flags:

- `--device <udid>`: target device UDID (defaults to the first saved device).
- `--timeout <sec>`: timeout passed to `devicectl` (default `15`).
- `--json`: emit `WakePayload` JSON (`udid`, `ready`, `locked`, `tailscaleIP`, `tcpReachable`, `output`).

Exit code is `0` only when `ready` is `true`; otherwise `1`.

### `locally-remote doctor`

Runs six environment checks: Tailscale CLI and iOS peers, `devicectl` paired devices, `kern.maxfilesperproc` capacity, resolved bind endpoints, TCP reachability to each saved device over Tailscale, and LaunchAgent/daemon health.

Flags:

- `--json`: emit `{ "ok": bool, "checks": [...] }`.

Exit code is `0` when all checks pass, `1` if any check fails.

### `locally-remote install-agent`

Writes `~/Library/LaunchAgents/dev.hammerpot.locally-remote.plist` with `SoftResourceLimits.NumberOfFiles = 24576`, unloads any prior instance, and loads it via `launchctl bootstrap gui/<uid>`.

Flags:

- `--bind <lo0|lan|loopback4>`: bind mode passed to the daemon (default `lo0`).
- `--force-bridge`: include `--force-bridge` in the LaunchAgent arguments.
- `--bin <path>`: binary path to execute (defaults to `CommandLine.arguments[0]`).

### `locally-remote uninstall-agent`

Runs `launchctl bootout` and deletes the LaunchAgent plist.

### `locally-remote remove <ref>`

Removes a saved device matching UDID, name, CoreDevice identifier, or Tailscale DNS substring from `config.json`.

## Exit Codes

- `0`: command succeeded (or device ready / all doctor checks passed).
- `1`: runtime failure, device not ready, or failing doctor check.
- `2`: invalid command or flag value.

## Files on Disk

All state lives under `~/.config/locally-remote/` (mode `0700`):

- `config.json`: persistent `AppConfig` and saved device list.
- `state.json`: live `DaemonRuntimeState` written on each reconcile cycle and removed on clean shutdown.
- `daemon.log`: stdout and stderr for the LaunchAgent.

### `config.json` Schema

```json
{
  "bindMode": "lo0",
  "devices": [
    {
      "bonjourRecord": {
        "authTag": "dGVzdFRh",
        "capturedAt": "2026-01-01T00:00:00Z",
        "flags": "0",
        "identifier": "11111111-2222-3333-4444-555555555555",
        "instanceName": "11111111-2222-3333-4444-555555555555",
        "minVersion": "8",
        "originalHostTarget": "Test-iPhone.local.",
        "port": 49152,
        "version": "26"
      },
      "coreDeviceIdentifier": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
      "enabled": true,
      "model": "iPhone 16 Pro",
      "name": "Test iPhone",
      "tailscaleDNSName": "test-iphone.example-tailnet.ts.net.",
      "tailscaleIP": "100.64.0.20",
      "tailscaleNodeKey": "nodekey:...",
      "udid": "00008110-000123456789001E",
      "updatedAt": "2026-01-01T00:00:00Z"
    }
  ],
  "pollIntervalSeconds": 5,
  "portRangeEnd": 65499,
  "portRangeStart": 49152,
  "schemaVersion": 1
}
```

### `state.json` Schema

```json
{
  "bindMode": "lo0",
  "devices": [
    {
      "activeConnections": 2,
      "activeTunnelPorts": [53324],
      "bonjourHost": "locally-remote-00008110.local.",
      "boundPortCount": 16346,
      "detail": "Bridged over Tailscale via fe80::1%lo0 -> 100.64.0.20:49152",
      "lanPresent": false,
      "lastUpdated": "2026-01-01T00:01:00Z",
      "name": "Test iPhone",
      "phase": "bridged",
      "proxyBindAddress": "fe80::1",
      "proxyInterface": "lo0",
      "remotePort": 49152,
      "tailscaleIP": "100.64.0.20",
      "tailscaleOnline": true,
      "totalBytesRelayed": 482304,
      "totalConnectionsHandled": 4,
      "udid": "00008110-000123456789001E"
    }
  ],
  "forceBridge": false,
  "pid": 12345,
  "startedAt": "2026-01-01T00:00:00Z",
  "updatedAt": "2026-01-01T00:01:00Z"
}
```
