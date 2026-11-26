# Architecture

`locally-remote` bridges Apple's iOS 17+ CoreDevice wireless debugging stack across Tailscale without root privileges, kernel extensions, or an iOS companion app.

## CoreDevice Connection Flow on macOS

When Xcode, `xcrun devicectl`, or SweetPad targets a wireless iOS device, macOS executes this sequence inside `remotepairingd` and `CoreDeviceService`:

1. `remotepairingd` browses `_remotepairing._tcp.local.` through `NWBrowser`.
2. Each iOS advertisement carries a TXT record containing a session `identifier` UUID, an `authTag` derived from the shared `altIRK`, and wire protocol version metadata (`ver`, `minVer`, `flags`).
3. `remotepairingd` checks `authTag` against its paired peers (`CUPairedPeer` records stored by `RemotePairingDataVaultHelper`) to map the advertisement to a known UDID.
4. `remotepairingd` opens a TCP control channel to the advertised host and port (usually `49152`), scoped to the network interface where Bonjour reported the advertisement, and performs Pair-Verify.
5. When a client requests a device assertion (such as `devicectl` or `xcodebuild`), `remotepairingd` sends a `createListener` request over the encrypted control channel.
6. iOS opens a fresh ephemeral TCP listener in `49152-65535` (for example `53324`) and returns that port along with a TLS pre-shared key.
7. `remotepairingd` combines the control channel's remote IP address with the returned port, opens a TLS-PSK TCP connection (`TLS_PSK_WITH_AES_128_GCM_SHA256`), completes the `CDTunnel` handshake, creates a local `utun` interface (IPv6 ULA point-to-point link), and registers a Remote Service Discovery (`remoted`) backend device.

Once `remoted` attaches the device, every Apple developer tool sees the phone as a normal local wireless target.

## Why Direct Tailscale Advertising Fails

Pointing `dns-sd -P` directly at the iPhone's `100.x.y.z` Tailscale IP fails inside macOS `Network.framework`:

- The Bonjour advertisement arrives on a local interface (`en1` or `lo0`).
- `NWConnection` scopes hostname resolution and TCP flow creation to that interface index (`IPv4:49152@en1`).
- SYN packets destined for `100.x.y.z` go out `en1` toward the LAN router instead of routing through the Tailscale `utun` interface, and time out.

## How Locally Remote Bridges Both Channels

### 1. Replaying Captured Bonjour Records

`remotepairingd` validates any `(identifier, authTag)` pair signed with the device's `altIRK`. The iPhone rotates its Bonjour instance UUID periodically, but replaying a previously captured pair still resolves to the paired UDID on the Mac. After `remotepairingd` connects to TCP port `49152`, the actual authentication happens via live Pair-Verify with the phone.

During `locally-remote capture`, `PhysicalBonjourBrowser` uses `DNSServiceBrowse` and `DNSServiceResolve` (filtering out `lo0` and `utun*`) to record `identifier`, `authTag`, `ver`, `minVer`, `flags`, and `port`. It matches the advertisement to a paired UDID using `xcrun devicectl list devices --json-output` and `remotepairingd` unified logs, then links it to the matching iOS peer from `Tailscale status --json`. Whenever the daemon sees the phone back on local Wi-Fi, it refreshes this record in `~/.config/locally-remote/config.json`.

### 2. Scoped `lo0` Advertisement

`BonjourAdvertiser` uses Apple's native `dnssd` C API (`DNSServiceCreateConnection`, `DNSServiceRegisterRecord`, and `DNSServiceRegister`) scoped to `if_nametoindex("lo0")`. It registers:

- An `AAAA` record for `locally-remote-<udid-prefix>.local.` pointing to `fe80::1`.
- A `_remotepairing._tcp` service record pointing to that hostname and the remote pairing port (typically `49152`), carrying the saved TXT keys.

Scoping to `lo0` avoids broadcasting fake mDNS records onto the physical LAN.

### 3. Catching Dynamic Tunnel Ports Without Root

Because the `createListener` response is encrypted inside the Pair-Verify control channel, a transparent TCP proxy cannot read the ephemeral port (`49152-65535`) before `remotepairingd` connects to it. Reacting after reading `Got tunnel endpoint:` from `log stream` loses the race against a local TCP SYN returning `ECONNREFUSED`.

`PortRelayServer` avoids both `sudo`/`pf` and the race condition:

1. It calls `setrlimit(RLIMIT_NOFILE, ...)` up to `24576` (macOS default `kern.maxfilesperproc` is `61440` with an unlimited hard limit).
2. It binds `49152-65499` (16,348 TCP sockets) on `fe80::1%lo0` and monitors all listening descriptors in a single `kqueue` loop.
3. Ports `65500-65535` remain unbound on `fe80::1%lo0`, giving `remotepairingd` 36 free ephemeral source ports when connecting to `fe80::1%lo0`.
4. `127.0.0.1` and `::1` remain completely unbound, so no other local services or ephemeral client pools on the Mac are affected.
5. Any connection accepted on `[fe80::1%lo0]:P` opens a blocking upstream TCP connection to `<tailscale-ip>:P` and relays bytes bidirectionally on worker threads with `TCP_NODELAY` and `SO_NOSIGPIPE`.

Both the control channel (`49152`) and the dynamic TLS-PSK tunnel port (`53xxx` or any port in `49152-65499`) flow through the same relay with no packet inspection and no decryption.

## Bind Modes

`locally-remote` supports three local bind strategies via `--bind`:

- `lo0` (default): binds `fe80::1%lo0` and advertises on `lo0`. Independent of Wi-Fi or Ethernet changes and isolated from `127.0.0.1` and `::1`.
- `lan`: picks the active `en*` interface with an IPv4 address and binds its link-local IPv6 address (`fe80::...%enX`, falling back to IPv4 if no link-local IPv6 exists). Use this if a macOS release rejects `lo0` in `NEVirtualInterfaceSetDelegateInterface`.
- `loopback4`: binds `127.0.0.1`. Only appropriate with a narrow `--port-range` for testing, because binding the full ephemeral range on `127.0.0.1` exhausts IPv4 loopback client ports.

## Daemon State Machine

`BridgeController` runs a reconciliation loop (default every 5 seconds):

1. If a saved device is seen on a physical interface within the 12-second grace window and `--force-bridge` is false, the bridge stays stopped (`local_lan`).
2. If the device is absent from the physical LAN (or `--force-bridge` is true), the controller resolves the latest IP from `Tailscale status --json`.
3. If Tailscale marks the peer offline, any active bridge is torn down (`tailscale_offline`).
4. Otherwise, it runs a 2-second non-blocking TCP probe to `<tailscale-ip>:<port>` (checking the saved port, then `49152`). If refused or timed out, the bridge stays down (`unreachable`).
5. When the TCP probe succeeds, the controller starts or keeps the `PortRelayServer` and `BonjourAdvertiser` running (`bridged`) and writes live telemetry to `~/.config/locally-remote/state.json`.

## Module Map

- `Sources/LocallyRemoteCore/Models.swift`: Codable config, runtime state, Tailscale/devicectl models, and RFC 6763 TXT encoding/decoding.
- `Sources/LocallyRemoteCore/ConfigStore.swift`: Atomic JSON reads and writes under `~/.config/locally-remote/`.
- `Sources/LocallyRemoteCore/NetworkHelpers.swift`: Subprocess runner with timeout, `RLIMIT_NOFILE`, non-blocking TCP probes, and interface lookup.
- `Sources/LocallyRemoteCore/TailscaleClient.swift`: Locates the Tailscale CLI (App Store/standalone app bundle or Homebrew), parses `status --json`, and matches iOS peers.
- `Sources/LocallyRemoteCore/DeviceCtlClient.swift`: Wraps `xcrun devicectl list devices` and `device info details`, plus `remotepairingd` log UDID correlation.
- `Sources/LocallyRemoteCore/BonjourBrowser.swift`: Physical-interface `_remotepairing._tcp` browser and resolver.
- `Sources/LocallyRemoteCore/BonjourAdvertiser.swift`: Scoped `dnssd` service and `AAAA`/`A` record advertiser.
- `Sources/LocallyRemoteCore/PortRelayServer.swift`: `kqueue` multi-port TCP relay and connection counters.
- `Sources/LocallyRemoteCore/BridgeController.swift`: Standby/bridge state machine and `state.json` writer.
- `Sources/LocallyRemoteCore/LaunchAgentManager.swift`: Generates and bootstraps `~/Library/LaunchAgents/dev.hammerpot.locally-remote.plist`.
- `Sources/locally-remote/main.swift`: Argument parser and CLI command handlers.
