import Foundation
import Darwin
import LocallyRemoteCore

// Signal hook for stopping the daemon on SIGINT/SIGTERM.
nonisolated(unsafe) private var activeController: BridgeController?

private func installSignalHandlers(for controller: BridgeController) {
    activeController = controller
    signal(SIGPIPE, SIG_IGN)
    signal(SIGINT) { _ in
        activeController?.stop()
    }
    signal(SIGTERM) { _ in
        activeController?.stop()
    }
}

private func printUsage() {
    let usage = """
    locally-remote - Headless Tailscale bridge for Xcode, CoreDevice, and SweetPad wireless builds

    USAGE:
      locally-remote <command> [options]

    COMMANDS:
      capture            Capture a paired iPhone's _remotepairing._tcp Bonjour record on local Wi-Fi
                         and link it to its Tailscale peer.
        --device <ref>         Optional UDID or name to select from devicectl
        --tailscale-peer <ref> Optional Tailscale hostname, DNS name, or IP
        --timeout <sec>        Bonjour browse timeout in seconds (default: 6)
        --json                 Output JSON

      daemon             Run the background bridge daemon (auto-switches between native LAN and Tailscale)
        --force-bridge         Keep the Tailscale proxy bridge active even when on home Wi-Fi
        --bind <lo0|lan|loopback4>  Local bind strategy (default: lo0 -> fe80::1%lo0)
        --port-range <a:b>     Local relay port range (default: 49152:65499)
        --poll-interval <sec>  Reconcile interval in seconds (default: 5)
        --verbose              Log individual proxied control/tunnel connections

      status             Show daemon/LaunchAgent state, bridged devices, and active tunnel stats
        --json                 Output JSON

      devices            List saved devices, live devicectl paired devices, and Tailscale iOS peers
        --json                 Output JSON

      wake               Verify bridge/reachability and wake the CoreDevice tunnel via devicectl
        --device <ref>         Optional UDID (defaults to first saved device)
        --timeout <sec>        devicectl timeout in seconds (default: 15)
        --json                 Output JSON

      doctor             Run end-to-end environment & reachability diagnostics
        --json                 Output JSON

      install-agent      Install and start the user LaunchAgent (~/Library/LaunchAgents/dev.hammerpot.locally-remote.plist)
        --bind <lo0|lan|loopback4>  Bind strategy for LaunchAgent (default: lo0)
        --force-bridge         Pass --force-bridge to the LaunchAgent daemon
        --bin <path>           Override binary path (default: current executable)

      uninstall-agent    Stop and remove the LaunchAgent

      remove <ref>       Remove a saved device by UDID, name, or Tailscale hostname

      completions        Print or install shell tab completions (zsh, bash, fish)
        <zsh|bash|fish>        Print completion script to stdout
        install [--shell <s>]  Install completion script for current or chosen shell
        --json                 Output JSON (with install)

      version            Print the locally-remote version (--version, -v)

      help               Show this help message
    """
    print(usage)
}

private func printJSON<T: Encodable>(_ value: T) {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    if let data = try? encoder.encode(value), let str = String(data: data, encoding: .utf8) {
        print(str)
    }
}

struct ParsedArgs {
    let command: String
    let positionals: [String]
    let flags: Set<String>
    let options: [String: String]

    var wantsJSON: Bool { flags.contains("--json") }
}

func parseArgs(_ argv: [String]) -> ParsedArgs {
    guard argv.count >= 2 else {
        return ParsedArgs(command: "help", positionals: [], flags: [], options: [:])
    }
    let command = argv[1]
    var positionals: [String] = []
    var flags: Set<String> = []
    var options: [String: String] = [:]

    let valueOptions: Set<String> = [
        "--device", "--tailscale-peer", "--timeout", "--bind",
        "--port-range", "--poll-interval", "--bin", "--shell"
    ]

    var i = 2
    while i < argv.count {
        let arg = argv[i]
        if valueOptions.contains(arg), i + 1 < argv.count {
            options[arg] = argv[i + 1]
            i += 2
        } else if arg.hasPrefix("--") {
            flags.insert(arg)
            i += 1
        } else {
            positionals.append(arg)
            i += 1
        }
    }
    return ParsedArgs(command: command, positionals: positionals, flags: flags, options: options)
}

private func parsePortRange(_ raw: String) -> ClosedRange<UInt16>? {
    let parts = raw.split(separator: ":")
    guard parts.count == 2,
          let lo = UInt16(parts[0]),
          let hi = UInt16(parts[1]),
          lo <= hi else { return nil }
    return lo...hi
}

private func formatBytes(_ bytes: UInt64) -> String {
    if bytes < 1024 { return "\(bytes) B" }
    if bytes < 1024 * 1024 { return String(format: "%.1f KB", Double(bytes) / 1024.0) }
    return String(format: "%.2f MB", Double(bytes) / (1024.0 * 1024.0))
}

// MARK: - Command Implementations

private func runCapture(_ args: ParsedArgs, store: ConfigStore) -> Int32 {
    let timeout = Double(args.options["--timeout"] ?? "6") ?? 6.0
    let tsClient = TailscaleClient()
    let devClient = DeviceCtlClient()

    let devDevices: [DeviceCtlDevice]
    do {
        devDevices = try devClient.listDevices()
    } catch {
        fputs("Error querying devicectl: \(error.localizedDescription)\n", stderr)
        return 1
    }

    let pairedDevices = devDevices.filter { $0.pairingState.lowercased() == "paired" }
    guard !pairedDevices.isEmpty else {
        fputs("No paired iOS devices found in `xcrun devicectl list devices`. Pair your iPhone with this Mac via USB or local Wi-Fi first.\n", stderr)
        return 1
    }

    if !args.wantsJSON {
        print("Browsing local Wi-Fi for `_remotepairing._tcp` advertisements (up to \(Int(timeout))s)...")
    }
    let discovered = PhysicalBonjourBrowser.captureOnce(timeout: timeout)
    guard !discovered.isEmpty else {
        fputs("No `_remotepairing._tcp` Bonjour advertisements found on local Wi-Fi.\nEnsure your iPhone is unlocked, on the same Wi-Fi network as this Mac, and has Developer Mode enabled.\n", stderr)
        return 1
    }

    // Match discovered Bonjour service to a paired devicectl device
    let deviceFilter = args.options["--device"]?.lowercased()
    var chosenService: DiscoveredBonjourService?
    var chosenDevice: DeviceCtlDevice?

    for svc in discovered {
        let logUDID = devClient.lookupUDIDForBonjourInstance(svc.instanceName)
        let hostPrefix = svc.hostTarget.replacingOccurrences(of: ".local.", with: "").lowercased()

        let matched = pairedDevices.first(where: { dev in
            if let deviceFilter,
               dev.udid.lowercased() != deviceFilter,
               dev.coreDeviceIdentifier.lowercased() != deviceFilter,
               !dev.name.lowercased().contains(deviceFilter) {
                return false
            }
            if let logUDID, dev.udid.caseInsensitiveCompare(logUDID) == .orderedSame {
                return true
            }
            if dev.potentialHostnames.contains(where: { $0.lowercased().hasPrefix(hostPrefix + ".") }) {
                return true
            }
            return pairedDevices.count == 1 && discovered.count == 1
        })

        if let matched {
            chosenService = svc
            chosenDevice = matched
            break
        }
    }

    guard let svc = chosenService, let dev = chosenDevice else {
        fputs("Found \(discovered.count) Bonjour service(s) but could not match to a paired device. Pass `--device <UDID>`.\n", stderr)
        return 1
    }

    // Match Tailscale peer
    let tsSnapshot = try? tsClient.status()
    let peerHint = args.options["--tailscale-peer"]
    let matchedPeer = tsSnapshot.flatMap { TailscaleClient.matchPeer(in: $0, hint: peerHint) }

    let resolvedIP: String
    if let peer = matchedPeer, let ip = peer.ipv4 ?? peer.ipv6 {
        resolvedIP = ip
    } else if let peerHint, peerHint.contains(".") || peerHint.contains(":") {
        resolvedIP = peerHint
    } else {
        fputs("Could not match an iOS Tailscale peer. Pass `--tailscale-peer <hostname-or-ip>`.\n", stderr)
        return 1
    }

    let saved = SavedDevice(
        udid: dev.udid,
        coreDeviceIdentifier: dev.coreDeviceIdentifier,
        name: dev.name,
        model: dev.model,
        tailscaleDNSName: matchedPeer?.dnsName,
        tailscaleNodeKey: matchedPeer?.nodeKey,
        tailscaleIP: resolvedIP,
        bonjourRecord: svc.record,
        enabled: true,
        updatedAt: Date()
    )

    do {
        _ = try store.upsertDevice(saved)
    } catch {
        fputs("Failed to save config: \(error.localizedDescription)\n", stderr)
        return 1
    }

    if args.wantsJSON {
        printJSON(saved)
    } else {
        print("Captured and saved device:")
        print("  Name:           \(saved.name) (\(saved.model ?? "iPhone"))")
        print("  UDID:           \(saved.udid)")
        print("  Tailscale Peer: \(saved.tailscaleDNSName ?? "manual") (\(saved.tailscaleIP))")
        print("  Bonjour ID:     \(saved.bonjourRecord.identifier)")
        print("  AuthTag:        \(saved.bonjourRecord.authTag) (ver=\(saved.bonjourRecord.version), minVer=\(saved.bonjourRecord.minVersion))")
        print("  Port:           \(saved.bonjourRecord.port)")
        print("  Config saved:   \(store.configURL.path)")
    }
    return 0
}

private func runDaemon(_ args: ParsedArgs, store: ConfigStore) -> Int32 {
    let bindMode: BindMode?
    if let raw = args.options["--bind"] {
        guard let parsed = BindMode(rawValue: raw) else {
            fputs("Invalid --bind value '\(raw)'. Expected one of: lo0, lan, loopback4\n", stderr)
            return 2
        }
        bindMode = parsed
    } else {
        bindMode = nil
    }

    let portRange: ClosedRange<UInt16>?
    if let raw = args.options["--port-range"] {
        guard let parsed = parsePortRange(raw) else {
            fputs("Invalid --port-range '\(raw)'. Expected <start>:<end>, e.g. 49152:65499\n", stderr)
            return 2
        }
        portRange = parsed
    } else {
        portRange = nil
    }

    let pollInterval = args.options["--poll-interval"].flatMap(Double.init)
    let forceBridge = args.flags.contains("--force-bridge")
    let verbose = args.flags.contains("--verbose")

    let controller = BridgeController(
        store: store,
        bindModeOverride: bindMode,
        portRangeOverride: portRange,
        pollIntervalOverride: pollInterval,
        forceBridge: forceBridge,
        verbose: verbose
    )
    installSignalHandlers(for: controller)
    controller.runForever()
    return 0
}

private struct StatusPayload: Codable {
    let configPath: String
    let launchAgent: LaunchAgentStatus
    let daemonRunning: Bool
    let runtime: DaemonRuntimeState?
    let savedDeviceCount: Int
}

private func runStatus(_ args: ParsedArgs, store: ConfigStore) -> Int32 {
    let config = (try? store.loadConfig()) ?? AppConfig()
    let agent = LaunchAgentManager.status()
    let rawRuntime = store.loadRuntimeState()
    let daemonAlive = rawRuntime.map { NetworkHelpers.isProcessAlive($0.pid) } ?? false
    let runtime = daemonAlive ? rawRuntime : nil

    let payload = StatusPayload(
        configPath: store.configURL.path,
        launchAgent: agent,
        daemonRunning: daemonAlive,
        runtime: runtime,
        savedDeviceCount: config.devices.count
    )

    if args.wantsJSON {
        printJSON(payload)
        return 0
    }

    print("Locally Remote Status")
    print("  Config:       \(store.configURL.path) (\(config.devices.count) saved device(s))")
    print("  LaunchAgent:  \(agent.installed ? "installed" : "not installed"), \(agent.loaded ? "loaded" : "not loaded")\(agent.pid.map { " (pid \($0))" } ?? "")")
    if let rt = runtime {
        print("  Daemon:       running (pid \(rt.pid), bind=\(rt.bindMode.rawValue), forceBridge=\(rt.forceBridge))")
        print("")
        if rt.devices.isEmpty {
            print("  No saved devices configured. Run `locally-remote capture` while your iPhone is on local Wi-Fi.")
        } else {
            for dev in rt.devices {
                print("  • \(dev.name) [\(dev.udid)]")
                print("    Phase:      \(dev.phase.rawValue)")
                print("    Detail:     \(dev.detail)")
                print("    Tailscale:  \(dev.tailscaleIP) (online=\(dev.tailscaleOnline))")
                if let addr = dev.proxyBindAddress, let iface = dev.proxyInterface {
                    print("    Proxy:      [\(addr)%\(iface)] (\(dev.boundPortCount) ports bound) -> \(dev.tailscaleIP):\(dev.remotePort)")
                    print("    Traffic:    \(dev.activeConnections) active conn(s), total=\(dev.totalConnectionsHandled), relayed=\(formatBytes(dev.totalBytesRelayed))")
                    if !dev.activeTunnelPorts.isEmpty {
                        print("    Tunnels:    ports \(dev.activeTunnelPorts.map(String.init).joined(separator: ", "))")
                    }
                }
            }
        }
    } else {
        print("  Daemon:       stopped")
        if !config.devices.isEmpty {
            print("  Saved devices:")
            for dev in config.devices {
                print("    • \(dev.name) [\(dev.udid)] -> \(dev.tailscaleIP):\(dev.bonjourRecord.port)")
            }
        }
    }
    return 0
}

private struct DevicesPayload: Codable {
    let saved: [SavedDevice]
    let devicectl: [DeviceCtlDevice]
    let tailscaleIOSPeers: [TailscalePeer]
}

private func runDevices(_ args: ParsedArgs, store: ConfigStore) -> Int32 {
    let config = (try? store.loadConfig()) ?? AppConfig()
    let devDevices = (try? DeviceCtlClient().listDevices()) ?? []
    let tsPeers = (try? TailscaleClient().status().iosPeers) ?? []

    let payload = DevicesPayload(saved: config.devices, devicectl: devDevices, tailscaleIOSPeers: tsPeers)
    if args.wantsJSON {
        printJSON(payload)
        return 0
    }

    print("Saved Devices (\(config.devices.count)):")
    for d in config.devices {
        print("  • \(d.name) | UDID: \(d.udid) | Tailscale: \(d.tailscaleIP) (\(d.tailscaleDNSName ?? "-")) | Port: \(d.bonjourRecord.port)")
    }
    print("\nCoreDevice Paired Devices (\(devDevices.count)):")
    for d in devDevices {
        print("  • \(d.name) | UDID: \(d.udid) | Pairing: \(d.pairingState) | Tunnel: \(d.tunnelState) | Transport: \(d.transportType ?? "-")")
    }
    print("\nTailscale iOS Peers (\(tsPeers.count)):")
    for p in tsPeers {
        print("  • \(p.shortName) | IPs: \(p.ips.joined(separator: ", ")) | Online: \(p.online)")
    }
    return 0
}

private struct WakePayload: Codable {
    let udid: String
    let ready: Bool
    let locked: Bool
    let tunnelState: String
    let tailscaleIP: String?
    let tcpReachable: Bool
    let output: String
}

private func runWake(_ args: ParsedArgs, store: ConfigStore) -> Int32 {
    let config = (try? store.loadConfig()) ?? AppConfig()
    let targetUDID: String
    let saved: SavedDevice?
    if let opt = args.options["--device"] {
        targetUDID = opt
        saved = config.devices.first(where: { $0.udid.caseInsensitiveCompare(opt) == .orderedSame })
    } else if let first = config.devices.first {
        targetUDID = first.udid
        saved = first
    } else {
        fputs("No saved device found and no `--device <UDID>` specified.\n", stderr)
        return 1
    }

    let timeout = Int(args.options["--timeout"] ?? "15") ?? 15
    var tsIP = saved?.tailscaleIP
    if let saved, let snap = try? TailscaleClient().status(),
       let peer = TailscaleClient.matchPeer(in: snap, nodeKey: saved.tailscaleNodeKey, dnsName: saved.tailscaleDNSName, ip: saved.tailscaleIP) {
        tsIP = peer.ipv4 ?? peer.ipv6 ?? tsIP
    }
    let tcpReachable = tsIP.map { NetworkHelpers.probeTCP(host: $0, port: saved?.bonjourRecord.port ?? 49152, timeoutSeconds: 2.0) } ?? false

    do {
        let probe = try DeviceCtlClient().probeDevice(identifier: targetUDID, timeoutSeconds: timeout)
        let payload = WakePayload(
            udid: targetUDID,
            ready: probe.ready,
            locked: probe.locked,
            tunnelState: probe.tunnelState,
            tailscaleIP: tsIP,
            tcpReachable: tcpReachable,
            output: probe.output
        )
        if args.wantsJSON {
            printJSON(payload)
        } else if probe.ready {
            print("Device \(targetUDID) is READY for Xcode / SweetPad builds (tunnelState=\(probe.tunnelState)).")
        } else if probe.locked {
            print("Device \(targetUDID) is reachable over the tunnel, but LOCKED. Unlock your iPhone and retry.")
        } else {
            print("Device \(targetUDID) is NOT ready (tunnelState=\(probe.tunnelState), tailscale=\(tsIP ?? "unknown"), tcp49152=\(tcpReachable)).")
            if !tcpReachable {
                print("Hint: TCP:49152 did not accept connections. Ensure the iPhone is connected to a Wi-Fi network (iOS stops remotepairingd on cellular-only) with Tailscale active.")
            }
            if !probe.output.isEmpty {
                print(probe.output)
            }
        }
        return probe.ready ? 0 : 1
    } catch {
        fputs("Wake failed: \(error.localizedDescription)\n", stderr)
        return 1
    }
}

private struct DoctorCheck: Codable {
    let name: String
    let ok: Bool
    let detail: String
}

private struct DoctorPayload: Codable {
    let ok: Bool
    let checks: [DoctorCheck]
}

private func runDoctor(_ args: ParsedArgs, store: ConfigStore) -> Int32 {
    var checks: [DoctorCheck] = []

    // 1. Tailscale CLI + status
    let tsClient = TailscaleClient()
    if let path = tsClient.executablePath {
        if let snap = try? tsClient.status() {
            let iosSummary = snap.iosPeers.map { "\($0.shortName)(\($0.ipv4 ?? "-"), online=\($0.online))" }.joined(separator: ", ")
            checks.append(DoctorCheck(
                name: "tailscale",
                ok: snap.backendState == "Running",
                detail: "CLI=\(path), state=\(snap.backendState), iOS peers=[\(iosSummary)]"
            ))
        } else {
            checks.append(DoctorCheck(name: "tailscale", ok: false, detail: "CLI found at \(path) but `status --json` failed"))
        }
    } else {
        checks.append(DoctorCheck(name: "tailscale", ok: false, detail: "Tailscale CLI not found"))
    }

    // 2. devicectl
    if let devs = try? DeviceCtlClient().listDevices() {
        let paired = devs.filter { $0.pairingState.lowercased() == "paired" }
        checks.append(DoctorCheck(
            name: "devicectl",
            ok: !paired.isEmpty,
            detail: "\(paired.count) paired device(s): \(paired.map { "\($0.name) (\($0.udid))" }.joined(separator: ", "))"
        ))
    } else {
        checks.append(DoctorCheck(name: "devicectl", ok: false, detail: "`xcrun devicectl list devices` failed"))
    }

    // 3. FD limit capacity
    let maxPerProc = NetworkHelpers.sysctlMaxFilesPerProc() ?? 0
    checks.append(DoctorCheck(
        name: "fd_limit",
        ok: maxPerProc >= 20000,
        detail: "kern.maxfilesperproc=\(maxPerProc) (need >= 20000 for full zero-root ephemeral relay)"
    ))

    // 4. Bind endpoints
    let lo0 = NetworkHelpers.resolveBindEndpoint(mode: .lo0)
    let lan = NetworkHelpers.resolveBindEndpoint(mode: .lan)
    checks.append(DoctorCheck(
        name: "bind_endpoints",
        ok: lo0 != nil,
        detail: "lo0=\(lo0.map { "\($0.address)%\($0.interfaceName)" } ?? "unavailable"), lan=\(lan.map { "\($0.address)%\($0.interfaceName)" } ?? "unavailable")"
    ))

    // 5. Saved devices & TCP reachability
    let config = (try? store.loadConfig()) ?? AppConfig()
    if config.devices.isEmpty {
        checks.append(DoctorCheck(name: "saved_devices", ok: false, detail: "No saved devices. Run `locally-remote capture` while on local Wi-Fi."))
    } else {
        for dev in config.devices {
            let reachable = NetworkHelpers.probeTCP(host: dev.tailscaleIP, port: dev.bonjourRecord.port, timeoutSeconds: 2.0)
            checks.append(DoctorCheck(
                name: "device_\(dev.udid)",
                ok: reachable,
                detail: "\(dev.name) -> \(dev.tailscaleIP):\(dev.bonjourRecord.port) tcpReachable=\(reachable)"
            ))
        }
    }

    // 6. LaunchAgent / daemon
    let agent = LaunchAgentManager.status()
    let rt = store.loadRuntimeState()
    let alive = rt.map { NetworkHelpers.isProcessAlive($0.pid) } ?? false
    checks.append(DoctorCheck(
        name: "daemon",
        ok: alive,
        detail: "running=\(alive), launchAgentInstalled=\(agent.installed), loaded=\(agent.loaded)"
    ))

    let allOK = checks.allSatisfy(\.ok)
    let payload = DoctorPayload(ok: allOK, checks: checks)
    if args.wantsJSON {
        printJSON(payload)
    } else {
        for c in checks {
            print("[\(c.ok ? "OK" : "!!")] \(c.name): \(c.detail)")
        }
    }
    return allOK ? 0 : 1
}

private func runInstallAgent(_ args: ParsedArgs, store: ConfigStore) -> Int32 {
    let bindRaw = args.options["--bind"] ?? "lo0"
    guard let bindMode = BindMode(rawValue: bindRaw) else {
        fputs("Invalid --bind '\(bindRaw)'. Expected lo0, lan, or loopback4.\n", stderr)
        return 2
    }
    let forceBridge = args.flags.contains("--force-bridge")
    let binPath = args.options["--bin"] ?? URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path

    do {
        try LaunchAgentManager.install(
            executablePath: binPath,
            bindMode: bindMode,
            forceBridge: forceBridge,
            store: store
        )
        print("Installed and started LaunchAgent \(LaunchAgentManager.label)")
        print("  Binary: \(binPath)")
        print("  Plist:  \(LaunchAgentManager.plistURL.path)")
        print("  Logs:   \(store.logURL.path)")
        return 0
    } catch {
        fputs("Failed to install LaunchAgent: \(error.localizedDescription)\n", stderr)
        return 1
    }
}

private func runUninstallAgent() -> Int32 {
    do {
        try LaunchAgentManager.uninstall()
        print("Unloaded and removed \(LaunchAgentManager.plistURL.path)")
        return 0
    } catch {
        fputs("Failed to uninstall LaunchAgent: \(error.localizedDescription)\n", stderr)
        return 1
    }
}

private func runRemove(_ args: ParsedArgs, store: ConfigStore) -> Int32 {
    guard let target = args.positionals.first else {
        fputs("Usage: locally-remote remove <udid-or-name>\n", stderr)
        return 2
    }
    do {
        let (removed, _) = try store.removeDevice(matching: target)
        if let removed {
            print("Removed \(removed.name) (\(removed.udid)) from \(store.configURL.path)")
            return 0
        } else {
            fputs("No saved device matching '\(target)'\n", stderr)
            return 1
        }
    } catch {
        fputs("Failed to update config: \(error.localizedDescription)\n", stderr)
        return 1
    }
}

private func runCompletions(_ args: ParsedArgs) -> Int32 {
    guard let target = args.positionals.first?.lowercased() else {
        fputs("Usage: locally-remote completions <zsh|bash|fish|install> [--shell <zsh|bash|fish>] [--json]\n", stderr)
        return 2
    }

    if target == "install" {
        let chosenShell: ShellType?
        if let raw = args.options["--shell"]?.lowercased() {
            guard let parsed = ShellType(rawValue: raw) else {
                fputs("Unsupported shell '\(raw)'. Expected one of: zsh, bash, fish.\n", stderr)
                return 2
            }
            chosenShell = parsed
        } else {
            chosenShell = nil
        }

        do {
            let result = try ShellCompletions.install(shell: chosenShell)
            if args.wantsJSON {
                printJSON(result)
            } else {
                print("Installed \(result.shell.rawValue) completions to \(result.path)")
                print(result.nextSteps)
            }
            return 0
        } catch {
            fputs("Failed to install completions: \(error.localizedDescription)\n", stderr)
            return 1
        }
    }

    guard let shell = ShellType(rawValue: target) else {
        fputs("Unsupported completions target '\(target)'. Expected one of: zsh, bash, fish, install.\n", stderr)
        return 2
    }
    print(ShellCompletions.generate(for: shell))
    return 0
}

// MARK: - Main Entry Point

let args = parseArgs(CommandLine.arguments)
let store = ConfigStore()

let exitCode: Int32
switch args.command {
case "capture":
    exitCode = runCapture(args, store: store)
case "daemon":
    exitCode = runDaemon(args, store: store)
case "status":
    exitCode = runStatus(args, store: store)
case "devices":
    exitCode = runDevices(args, store: store)
case "wake":
    exitCode = runWake(args, store: store)
case "doctor":
    exitCode = runDoctor(args, store: store)
case "install-agent":
    exitCode = runInstallAgent(args, store: store)
case "uninstall-agent":
    exitCode = runUninstallAgent()
case "remove":
    exitCode = runRemove(args, store: store)
case "completions":
    exitCode = runCompletions(args)
case "version", "--version", "-v":
    print(LocallyRemoteVersion.current)
    exitCode = 0
case "help", "-h", "--help":
    printUsage()
    exitCode = 0
default:
    fputs("Unknown command: \(args.command)\n\n", stderr)
    printUsage()
    exitCode = 2
}

exit(exitCode)
