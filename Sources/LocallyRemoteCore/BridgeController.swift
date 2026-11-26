import Foundation

/// Active bridge bundle (TCP relay + Bonjour proxy registration) for one device.
private final class ActiveDeviceBridge {
    let udid: String
    let remoteIP: String
    let remotePort: UInt16
    let bindEndpoint: NetworkHelpers.BindEndpoint
    let bonjourHost: String
    let relay: PortRelayServer
    let advertiser: BonjourAdvertiser

    init(
        device: SavedDevice,
        remoteIP: String,
        remotePort: UInt16,
        bindEndpoint: NetworkHelpers.BindEndpoint,
        portRange: ClosedRange<UInt16>,
        verbose: Bool
    ) throws {
        self.udid = device.udid
        self.remoteIP = remoteIP
        self.remotePort = remotePort
        self.bindEndpoint = bindEndpoint
        self.bonjourHost = NetworkHelpers.makeProxyHostname(udid: device.udid)

        self.relay = PortRelayServer(
            bindEndpoint: bindEndpoint,
            remoteHost: remoteIP,
            controlPort: remotePort,
            portRange: portRange,
            verbose: verbose
        )
        self.advertiser = BonjourAdvertiser(
            hostname: self.bonjourHost,
            bindEndpoint: bindEndpoint,
            record: device.bonjourRecord,
            advertisedPort: remotePort
        )

        try self.relay.start()
        do {
            try self.advertiser.start()
        } catch {
            self.relay.stop()
            throw error
        }
    }

    func stop() {
        advertiser.stop()
        relay.stop()
    }
}

/// Coordinates LAN Bonjour observation, Tailscale peer probing, and per-device proxy bridges.
///
/// Watches physical interfaces for `_remotepairing._tcp` ads so saved `authTag` records stay fresh
/// while a device is on local Wi-Fi. When a saved device leaves the LAN (or `forceBridge` is set)
/// and accepts TCP connections on Tailscale, starts `PortRelayServer` and `BonjourAdvertiser`.
/// Stops the bridge when the device returns to the LAN or becomes unreachable.
public final class BridgeController: @unchecked Sendable {
    private let store: ConfigStore
    private let tailscale: TailscaleClient
    private let deviceCtl: DeviceCtlClient
    private let bindModeOverride: BindMode?
    private let portRangeOverride: ClosedRange<UInt16>?
    private let pollIntervalOverride: Double?
    private let forceBridge: Bool
    private let verbose: Bool

    private let lock = NSLock()
    private var running = false
    private let startedAt = Date()
    private let browser = PhysicalBonjourBrowser()
    private var activeBridges: [String: ActiveDeviceBridge] = [:]
    private var lastLANServices: [DiscoveredBonjourService] = []
    private var lanLastSeenByUDID: [String: Date] = [:]

    /// Grace window before declaring a LAN device gone (avoids flapping during brief mDNS rotations).
    private let lanGraceSeconds: TimeInterval = 12.0

    public init(
        store: ConfigStore = ConfigStore(),
        tailscale: TailscaleClient = TailscaleClient(),
        deviceCtl: DeviceCtlClient = DeviceCtlClient(),
        bindModeOverride: BindMode? = nil,
        portRangeOverride: ClosedRange<UInt16>? = nil,
        pollIntervalOverride: Double? = nil,
        forceBridge: Bool = false,
        verbose: Bool = false
    ) {
        self.store = store
        self.tailscale = tailscale
        self.deviceCtl = deviceCtl
        self.bindModeOverride = bindModeOverride
        self.portRangeOverride = portRangeOverride
        self.pollIntervalOverride = pollIntervalOverride
        self.forceBridge = forceBridge
        self.verbose = verbose
    }

    public func runForever() {
        lock.lock()
        running = true
        lock.unlock()

        log("Starting locally-remote daemon (pid=\(ProcessInfo.processInfo.processIdentifier), forceBridge=\(forceBridge))")

        // Write initial state immediately so `locally-remote status` sees the live daemon during first probe.
        let initialConfig = (try? store.loadConfig()) ?? AppConfig()
        try? store.saveRuntimeState(DaemonRuntimeState(
            pid: ProcessInfo.processInfo.processIdentifier,
            startedAt: startedAt,
            updatedAt: Date(),
            bindMode: bindModeOverride ?? initialConfig.bindMode,
            forceBridge: forceBridge,
            devices: []
        ))

        browser.start { [weak self] services in
            self?.handleLANServicesUpdated(services)
        }

        // Initial small settle so LAN browser sees any immediately present devices before deciding to bridge
        if !forceBridge {
            Thread.sleep(forTimeInterval: 1.5)
        }

        while isRunning() {
            let interval = reconcileOnce()
            let steps = max(1, Int(interval / 0.25))
            for _ in 0..<steps {
                if !isRunning() { break }
                Thread.sleep(forTimeInterval: 0.25)
            }
        }

        shutdownAll()
    }

    public func stop() {
        lock.lock()
        running = false
        lock.unlock()
    }

    private func isRunning() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func shutdownAll() {
        log("Shutting down locally-remote daemon...")
        browser.stop()
        lock.lock()
        let bridges = Array(activeBridges.values)
        activeBridges.removeAll()
        lock.unlock()
        for b in bridges {
            b.stop()
        }
        store.clearRuntimeState()
        log("Shutdown complete.")
    }

    private func handleLANServicesUpdated(_ services: [DiscoveredBonjourService]) {
        lock.lock()
        lastLANServices = services
        lock.unlock()

        guard !services.isEmpty else { return }
        guard var config = try? store.loadConfig(), !config.devices.isEmpty else { return }

        var configModified = false
        let now = Date()

        for svc in services {
            if let idx = matchSavedDeviceIndex(for: svc, in: config.devices) {
                guard svc.isLiveOnLAN(timeoutSeconds: 1.0) else {
                    continue
                }
                let udid = config.devices[idx].udid
                lock.lock()
                lanLastSeenByUDID[udid] = now
                lock.unlock()

                if config.devices[idx].bonjourRecord.identifier != svc.record.identifier ||
                   config.devices[idx].bonjourRecord.authTag != svc.record.authTag ||
                   config.devices[idx].bonjourRecord.port != svc.record.port {
                    config.devices[idx].bonjourRecord = svc.record
                    config.devices[idx].updatedAt = now
                    configModified = true
                    log("Auto-refreshed LAN Bonjour record for \(config.devices[idx].name) (\(udid)): port=\(svc.record.port), id=\(svc.record.identifier)")
                }
            }
        }

        if configModified {
            try? store.saveConfig(config)
        }
    }

    private func matchSavedDeviceIndex(for svc: DiscoveredBonjourService, in devices: [SavedDevice]) -> Int? {
        if devices.count == 1 {
            return 0
        }
        let hostPrefix = svc.hostTarget.replacingOccurrences(of: ".local.", with: "").lowercased()
        if let idx = devices.firstIndex(where: {
            $0.bonjourRecord.originalHostTarget?.lowercased() == svc.hostTarget.lowercased() ||
            $0.name.lowercased().replacingOccurrences(of: " ", with: "-").contains(hostPrefix)
        }) {
            return idx
        }
        if let udid = deviceCtl.lookupUDIDForBonjourInstance(svc.instanceName) {
            return devices.firstIndex(where: { $0.udid.caseInsensitiveCompare(udid) == .orderedSame })
        }
        return nil
    }

    @discardableResult
    public func reconcileOnce() -> Double {
        let config = (try? store.loadConfig()) ?? AppConfig()
        let bindMode = bindModeOverride ?? config.bindMode
        let portRange = portRangeOverride ?? (config.portRangeStart...config.portRangeEnd)
        let pollInterval = pollIntervalOverride ?? config.pollIntervalSeconds
        let tsSnapshot = try? tailscale.status()
        let now = Date()

        // Remove bridges for devices no longer in config
        let configuredUDIDs = Set(config.devices.map(\.udid))
        lock.lock()
        let staleUDIDs = activeBridges.keys.filter { !configuredUDIDs.contains($0) }
        for udid in staleUDIDs {
            activeBridges.removeValue(forKey: udid)?.stop()
        }
        lock.unlock()

        var statuses: [DeviceBridgeStatus] = []

        for device in config.devices {
            if !device.enabled {
                teardownBridge(udid: device.udid)
                statuses.append(DeviceBridgeStatus(
                    udid: device.udid,
                    name: device.name,
                    phase: .disabled,
                    detail: "Device disabled in config",
                    tailscaleIP: device.tailscaleIP,
                    tailscaleOnline: false,
                    remotePort: device.bonjourRecord.port,
                    lanPresent: false,
                    proxyBindAddress: nil,
                    proxyInterface: nil,
                    bonjourHost: nil,
                    boundPortCount: 0,
                    activeConnections: 0,
                    activeTunnelPorts: [],
                    totalConnectionsHandled: 0,
                    totalBytesRelayed: 0,
                    lastUpdated: now
                ))
                continue
            }

            // Actively verify LAN liveness so stale mDNSResponder cache entries after Wi-Fi off
            // do not hold the daemon in local_lan standby.
            let matchingLAN = browser.currentServices().filter {
                matchSavedDeviceIndex(for: $0, in: [device]) != nil
            }
            let liveOnLAN = matchingLAN.contains(where: { $0.isLiveOnLAN(timeoutSeconds: 0.6) })
            if liveOnLAN {
                lock.lock()
                lanLastSeenByUDID[device.udid] = now
                lock.unlock()
            } else if !matchingLAN.isEmpty {
                // Service is still in mDNS cache, but direct LAN TCP failed: clear stale LAN state now.
                lock.lock()
                lanLastSeenByUDID.removeValue(forKey: device.udid)
                lock.unlock()
            }

            lock.lock()
            let lastSeenLAN = lanLastSeenByUDID[device.udid]
            lock.unlock()
            let lanPresent = liveOnLAN || (lastSeenLAN.map { now.timeIntervalSince($0) < lanGraceSeconds } ?? false)

            // Resolve current Tailscale IP from live tailscale status when available
            let matchedPeer = tsSnapshot.flatMap {
                TailscaleClient.matchPeer(
                    in: $0,
                    nodeKey: device.tailscaleNodeKey,
                    dnsName: device.tailscaleDNSName,
                    ip: device.tailscaleIP
                )
            }
            let effectiveIP = matchedPeer?.ipv4 ?? matchedPeer?.ipv6 ?? device.tailscaleIP
            let tsOnline = matchedPeer?.online ?? true // If tailscale CLI unavailable, still attempt TCP probe

            // Case 1: Present on home LAN and not forced to bridge -> stay in native standby
            if lanPresent && !forceBridge {
                if hasBridge(udid: device.udid) {
                    log("Device \(device.name) (\(device.udid)) appeared on local LAN: deactivating remote bridge")
                    teardownBridge(udid: device.udid)
                }
                statuses.append(DeviceBridgeStatus(
                    udid: device.udid,
                    name: device.name,
                    phase: .localLAN,
                    detail: "Reachable on local Wi-Fi (standby; Bonjour record kept fresh)",
                    tailscaleIP: effectiveIP,
                    tailscaleOnline: tsOnline,
                    remotePort: device.bonjourRecord.port,
                    lanPresent: true,
                    proxyBindAddress: nil,
                    proxyInterface: nil,
                    bonjourHost: nil,
                    boundPortCount: 0,
                    activeConnections: 0,
                    activeTunnelPorts: [],
                    totalConnectionsHandled: 0,
                    totalBytesRelayed: 0,
                    lastUpdated: now
                ))
                continue
            }

            // Case 2: Tailscale reports peer offline
            if let matchedPeer, !matchedPeer.online {
                teardownBridge(udid: device.udid)
                statuses.append(DeviceBridgeStatus(
                    udid: device.udid,
                    name: device.name,
                    phase: .tailscaleOffline,
                    detail: "Tailscale peer \(matchedPeer.shortName) (\(effectiveIP)) is offline",
                    tailscaleIP: effectiveIP,
                    tailscaleOnline: false,
                    remotePort: device.bonjourRecord.port,
                    lanPresent: lanPresent,
                    proxyBindAddress: nil,
                    proxyInterface: nil,
                    bonjourHost: nil,
                    boundPortCount: 0,
                    activeConnections: 0,
                    activeTunnelPorts: [],
                    totalConnectionsHandled: 0,
                    totalBytesRelayed: 0,
                    lastUpdated: now
                ))
                continue
            }

            // Case 3: Probe TCP RemotePairing port on Tailscale IP
            let discoveredPort = NetworkHelpers.discoverRemotePairingPort(
                host: effectiveIP,
                preferredPort: device.bonjourRecord.port,
                timeoutSeconds: 2.0
            )
            guard let remotePort = discoveredPort else {
                if hasBridge(udid: device.udid) {
                    log("Device \(device.name) (\(effectiveIP):\(device.bonjourRecord.port)) stopped accepting connections: pausing bridge")
                    teardownBridge(udid: device.udid)
                }
                statuses.append(DeviceBridgeStatus(
                    udid: device.udid,
                    name: device.name,
                    phase: .unreachable,
                    detail: "Tailscale reachable (\(effectiveIP)) but TCP:\(device.bonjourRecord.port) refused/timed out (iPhone must be connected to a Wi-Fi network for iOS remotepairingd to listen)",
                    tailscaleIP: effectiveIP,
                    tailscaleOnline: tsOnline,
                    remotePort: device.bonjourRecord.port,
                    lanPresent: lanPresent,
                    proxyBindAddress: nil,
                    proxyInterface: nil,
                    bonjourHost: nil,
                    boundPortCount: 0,
                    activeConnections: 0,
                    activeTunnelPorts: [],
                    totalConnectionsHandled: 0,
                    totalBytesRelayed: 0,
                    lastUpdated: now
                ))
                continue
            }

            // Case 4: Ensure bridge is running and matches current remoteIP / remotePort / bindEndpoint
            guard let bindEndpoint = NetworkHelpers.resolveBindEndpoint(mode: bindMode) else {
                statuses.append(DeviceBridgeStatus(
                    udid: device.udid,
                    name: device.name,
                    phase: .error,
                    detail: "Unable to resolve local bind endpoint for mode '\(bindMode.rawValue)'",
                    tailscaleIP: effectiveIP,
                    tailscaleOnline: tsOnline,
                    remotePort: remotePort,
                    lanPresent: lanPresent,
                    proxyBindAddress: nil,
                    proxyInterface: nil,
                    bonjourHost: nil,
                    boundPortCount: 0,
                    activeConnections: 0,
                    activeTunnelPorts: [],
                    totalConnectionsHandled: 0,
                    totalBytesRelayed: 0,
                    lastUpdated: now
                ))
                continue
            }

            do {
                let bridge = try ensureBridge(
                    device: device,
                    remoteIP: effectiveIP,
                    remotePort: remotePort,
                    bindEndpoint: bindEndpoint,
                    portRange: portRange
                )
                let stats = bridge.relay.stats()
                statuses.append(DeviceBridgeStatus(
                    udid: device.udid,
                    name: device.name,
                    phase: .bridged,
                    detail: forceBridge
                        ? "Forced bridge active via \(bindEndpoint.address)%\(bindEndpoint.interfaceName) -> \(effectiveIP):\(remotePort)"
                        : "Bridged over Tailscale via \(bindEndpoint.address)%\(bindEndpoint.interfaceName) -> \(effectiveIP):\(remotePort)",
                    tailscaleIP: effectiveIP,
                    tailscaleOnline: tsOnline,
                    remotePort: remotePort,
                    lanPresent: lanPresent,
                    proxyBindAddress: bindEndpoint.address,
                    proxyInterface: bindEndpoint.interfaceName,
                    bonjourHost: bridge.bonjourHost,
                    boundPortCount: stats.boundPortCount,
                    activeConnections: stats.activeConnections,
                    activeTunnelPorts: stats.activeTunnelPorts,
                    totalConnectionsHandled: stats.totalConnectionsHandled,
                    totalBytesRelayed: stats.totalBytesRelayed,
                    lastUpdated: now
                ))
            } catch {
                log("Error starting bridge for \(device.name): \(error.localizedDescription)")
                statuses.append(DeviceBridgeStatus(
                    udid: device.udid,
                    name: device.name,
                    phase: .error,
                    detail: error.localizedDescription,
                    tailscaleIP: effectiveIP,
                    tailscaleOnline: tsOnline,
                    remotePort: remotePort,
                    lanPresent: lanPresent,
                    proxyBindAddress: bindEndpoint.address,
                    proxyInterface: bindEndpoint.interfaceName,
                    bonjourHost: nil,
                    boundPortCount: 0,
                    activeConnections: 0,
                    activeTunnelPorts: [],
                    totalConnectionsHandled: 0,
                    totalBytesRelayed: 0,
                    lastUpdated: now
                ))
            }
        }

        let state = DaemonRuntimeState(
            pid: ProcessInfo.processInfo.processIdentifier,
            startedAt: startedAt,
            updatedAt: now,
            bindMode: bindMode,
            forceBridge: forceBridge,
            devices: statuses
        )
        try? store.saveRuntimeState(state)
        return pollInterval
    }

    private func hasBridge(udid: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return activeBridges[udid] != nil
    }

    private func teardownBridge(udid: String) {
        lock.lock()
        let existing = activeBridges.removeValue(forKey: udid)
        lock.unlock()
        existing?.stop()
    }

    private func ensureBridge(
        device: SavedDevice,
        remoteIP: String,
        remotePort: UInt16,
        bindEndpoint: NetworkHelpers.BindEndpoint,
        portRange: ClosedRange<UInt16>
    ) throws -> ActiveDeviceBridge {
        lock.lock()
        if let existing = activeBridges[device.udid],
           existing.remoteIP == remoteIP,
           existing.remotePort == remotePort,
           existing.bindEndpoint == bindEndpoint {
            lock.unlock()
            return existing
        }
        let stale = activeBridges.removeValue(forKey: device.udid)
        lock.unlock()

        stale?.stop()

        log("Activating Tailscale bridge for \(device.name) (\(device.udid)): \(bindEndpoint.address)%\(bindEndpoint.interfaceName) [\(portRange.lowerBound)...\(portRange.upperBound)] -> \(remoteIP):\(remotePort)")
        let created = try ActiveDeviceBridge(
            device: device,
            remoteIP: remoteIP,
            remotePort: remotePort,
            bindEndpoint: bindEndpoint,
            portRange: portRange,
            verbose: verbose
        )
        lock.lock()
        activeBridges[device.udid] = created
        lock.unlock()
        return created
    }

    private func log(_ msg: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        fputs("[\(ts)] \(msg)\n", stderr)
    }
}
