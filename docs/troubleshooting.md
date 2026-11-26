# Troubleshooting

## `phase: unreachable` and `TCP:49152 refused`

Check whether the iPhone is on cellular data only. When Wi-Fi is switched off on iOS, the OS stops `remotepairingd` (TCP `49152`) and `lockdownd` (TCP `62078`). Tailscale pings still succeed, while TCP probes to `49152` return `Connection refused`.

Fix: connect the iPhone to any Wi-Fi network (remote Wi-Fi, office, hotel, or another device's hotspot) with Tailscale enabled. Wait one poll cycle (default 5 seconds) and re-check `locally-remote status`.

## Device Is Locked

`locally-remote wake` reports `locked: true` or `devicectl` returns `The device has not been unlocked recently` / `The operation failed because the device was still locked`.

This means the Bonjour proxy and TCP control channel are working. Unlock the iPhone and retry `locally-remote wake` or `sweetpad run`.

## `remotepairingd` Rejects `lo0` When Creating the Virtual Interface

If `remotepairingd` connects to `[fe80::1%lo0]:49152` and opens the tunnel port, but fails during virtual interface setup, inspect the unified log on the Mac:

```bash
/usr/bin/log show --last 2m --predicate 'process == "remotepairingd" AND NOT (eventMessage CONTAINS "Bluetooth" OR eventMessage CONTAINS "CBDevice")' --info | tail -n 80
```

Look for `Failed to set lo0 as the delegate interface on virtual interface` or `Network control channel started but used prohibited interface`. If that occurs on your macOS version, switch the LaunchAgent to bind the active physical LAN interface's link-local IPv6 address instead:

```bash
locally-remote install-agent --bind lan
locally-remote status
```

## Verify Bonjour Registration Locally

While `status` shows `phase: bridged`, verify that mDNSResponder is advertising the proxy record on `lo0`:

```bash
dns-sd -B _remotepairing._tcp local.
dns-sd -L "<INSTANCE_NAME>" _remotepairing._tcp local.
dns-sd -G v6 "locally-remote-<UDID_PREFIX>.local."
```

The lookup should report interface `1` (`lo0`) and resolve to `FE80::1%lo0`.

## Verify `remotepairingd` Recognized the Replayed `authTag`

```bash
/usr/bin/log show --last 2m --predicate 'process == "remotepairingd" AND eventMessage CONTAINS "Resolved bonjour advert"' --info
```

If `remotepairingd` logs `Unable to resolve bonjour advert ... to known identity`, the iPhone was unpaired or re-paired after capture. Re-run `locally-remote capture` while on shared Wi-Fi to store a valid `authTag`.

## Low File Descriptor Count (`boundPortCount` Much Smaller Than 16346)

Check `sysctl kern.maxfilesperproc` and `ulimit -Hn`. `locally-remote doctor` checks that `kern.maxfilesperproc` is at least `20000`, and the LaunchAgent plist sets `SoftResourceLimits.NumberOfFiles = 24576`. If running `locally-remote daemon` manually from a shell with a restrictive hard limit, raise it or run via `install-agent`.

## Tailscale CLI Not Found

`TailscaleClient` checks:

1. `/Applications/Tailscale.app/Contents/MacOS/Tailscale`
2. `/opt/homebrew/bin/tailscale`
3. `/usr/local/bin/tailscale`
4. `/usr/bin/tailscale`

If you installed `tailscale` somewhere else, symlink it into `/usr/local/bin/tailscale`.

## Debugging Traffic Live

Stop the LaunchAgent temporarily and run the daemon in the foreground with verbose logging to watch individual control-channel and dynamic tunnel-port connections:

```bash
locally-remote uninstall-agent
locally-remote daemon --force-bridge --verbose
```

When finished, restore normal background operation:

```bash
locally-remote install-agent
```
