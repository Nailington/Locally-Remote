import Foundation
import Darwin
import dnssd

/// A resolved `_remotepairing._tcp` Bonjour advertisement discovered on a physical interface.
public struct DiscoveredBonjourService: Sendable, Equatable {
    public let instanceName: String
    public let interfaceIndex: UInt32
    public let interfaceName: String
    public let hostTarget: String
    public let port: UInt16
    public let resolvedAddresses: [String]
    public let record: BonjourRecord

    /// Actively checks whether the advertised LAN endpoint is accepting TCP connections.
    /// Filters out stale mDNSResponder cache entries after a device leaves Wi-Fi without a goodbye packet.
    public func isLiveOnLAN(timeoutSeconds: Double = 0.6) -> Bool {
        let lanAddrs = Array(resolvedAddresses.filter { !NetworkHelpers.isTailscaleOrLoopbackAddress($0) }.prefix(2))
        guard !lanAddrs.isEmpty else { return false }
        for addr in lanAddrs {
            let scope: UInt32 = addr.lowercased().hasPrefix("fe80:") ? interfaceIndex : 0
            if NetworkHelpers.probeTCP(host: addr, port: port, scopeIndex: scope, timeoutSeconds: timeoutSeconds) {
                return true
            }
        }
        return false
    }
}

/// Native `dnssd` browser for `_remotepairing._tcp` services on physical (non-loopback) interfaces.
public final class PhysicalBonjourBrowser: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    private var browseRef: DNSServiceRef?
    private var thread: Thread?
    private var activeServices: [String: DiscoveredBonjourService] = [:] // key: "\(ifIndex):\(instanceName)"
    private var onChange: (@Sendable ([DiscoveredBonjourService]) -> Void)?

    public init() {}

    public func currentServices() -> [DiscoveredBonjourService] {
        lock.lock()
        defer { lock.unlock() }
        return Array(activeServices.values)
    }

    /// One-shot capture helper: browses physical LAN interfaces for up to `timeout` seconds and returns all resolved services.
    public static func captureOnce(timeout: TimeInterval = 5.0) -> [DiscoveredBonjourService] {
        let browser = PhysicalBonjourBrowser()
        let sem = DispatchSemaphore(value: 0)
        browser.start { services in
            if !services.isEmpty {
                sem.signal()
            }
        }
        // Wait for first discovery, then allow 1s extra to collect any additional devices
        _ = sem.wait(timeout: .now() + timeout)
        if !browser.currentServices().isEmpty {
            Thread.sleep(forTimeInterval: 0.75)
        }
        let found = browser.currentServices()
        browser.stop()
        return found
    }

    public func start(onChange: (@Sendable ([DiscoveredBonjourService]) -> Void)? = nil) {
        lock.lock()
        if running {
            lock.unlock()
            return
        }
        running = true
        self.onChange = onChange
        lock.unlock()

        let worker = Thread { [weak self] in
            self?.runLoop()
        }
        worker.name = "LocallyRemote.BonjourBrowser"
        lock.lock()
        self.thread = worker
        lock.unlock()
        worker.start()
    }

    public func stop() {
        lock.lock()
        let wasRunning = running
        running = false
        let ref = browseRef
        browseRef = nil
        lock.unlock()

        if wasRunning, let ref {
            DNSServiceRefDeallocate(ref)
        }
    }

    deinit {
        stop()
    }

    private func isRunning() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func runLoop() {
        let loIndex = if_nametoindex("lo0")
        let context = Unmanaged.passRetained(self).toOpaque()
        defer { Unmanaged<PhysicalBonjourBrowser>.fromOpaque(context).release() }

        var ref: DNSServiceRef?
        let err = DNSServiceBrowse(
            &ref,
            0,
            0, // all interfaces; we filter out lo0 inside callback
            "_remotepairing._tcp",
            "local.",
            { _, flags, interfaceIndex, errorCode, serviceName, regtype, replyDomain, ctx in
                guard errorCode == kDNSServiceErr_NoError,
                      let ctx,
                      let serviceName,
                      let regtype,
                      let replyDomain else { return }
                let browser = Unmanaged<PhysicalBonjourBrowser>.fromOpaque(ctx).takeUnretainedValue()
                let name = String(cString: serviceName)
                let type = String(cString: regtype)
                let domain = String(cString: replyDomain)
                let isAdd = (flags & DNSServiceFlags(kDNSServiceFlagsAdd)) != 0
                browser.handleBrowseEvent(
                    isAdd: isAdd,
                    interfaceIndex: interfaceIndex,
                    name: name,
                    type: type,
                    domain: domain
                )
            },
            context
        )

        guard err == kDNSServiceErr_NoError, let browseRef = ref else {
            return
        }

        lock.lock()
        if !running {
            lock.unlock()
            DNSServiceRefDeallocate(browseRef)
            return
        }
        self.browseRef = browseRef
        lock.unlock()

        _ = loIndex
        let fd = DNSServiceRefSockFD(browseRef)
        guard fd >= 0 else { return }

        while isRunning() {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let rc = poll(&pfd, 1, 250)
            if rc > 0 && (pfd.revents & Int16(POLLIN)) != 0 {
                if !isRunning() { break }
                let procErr = DNSServiceProcessResult(browseRef)
                if procErr != kDNSServiceErr_NoError {
                    break
                }
            } else if rc < 0 && errno != EINTR {
                break
            }
        }
    }

    private func handleBrowseEvent(
        isAdd: Bool,
        interfaceIndex: UInt32,
        name: String,
        type: String,
        domain: String
    ) {
        let loIndex = if_nametoindex("lo0")
        if interfaceIndex == loIndex {
            return
        }
        var ifBuf = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
        let ifName = if_indextoname(interfaceIndex, &ifBuf).map { String(cString: $0) } ?? "if\(interfaceIndex)"
        if ifName == "lo0" || ifName.hasPrefix("utun") {
            return
        }

        let key = "\(interfaceIndex):\(name)"
        if !isAdd {
            lock.lock()
            let removed = activeServices.removeValue(forKey: key) != nil
            let snapshot = Array(activeServices.values)
            let cb = onChange
            lock.unlock()
            if removed {
                cb?(snapshot)
            }
            return
        }

        // Resolve the service asynchronously so we don't block the browse loop
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self, self.isRunning() else { return }
            guard let resolved = Self.resolveService(
                name: name,
                type: type,
                domain: domain,
                interfaceIndex: interfaceIndex,
                interfaceName: ifName
            ) else { return }

            // Ignore our own proxy hostnames if advertised on LAN mode
            if resolved.hostTarget.lowercased().hasPrefix("locally-remote-") {
                return
            }

            self.lock.lock()
            self.activeServices[key] = resolved
            let snapshot = Array(self.activeServices.values)
            let cb = self.onChange
            self.lock.unlock()
            cb?(snapshot)
        }
    }

    private final class ResolveBox: @unchecked Sendable {
        let instanceName: String
        let interfaceIndex: UInt32
        let interfaceName: String
        var result: DiscoveredBonjourService?
        var done = false

        init(instanceName: String, interfaceIndex: UInt32, interfaceName: String) {
            self.instanceName = instanceName
            self.interfaceIndex = interfaceIndex
            self.interfaceName = interfaceName
        }
    }

    private static func resolveService(
        name: String,
        type: String,
        domain: String,
        interfaceIndex: UInt32,
        interfaceName: String,
        timeout: TimeInterval = 3.0
    ) -> DiscoveredBonjourService? {
        let box = ResolveBox(instanceName: name, interfaceIndex: interfaceIndex, interfaceName: interfaceName)
        let ctx = Unmanaged.passRetained(box).toOpaque()
        defer { Unmanaged<ResolveBox>.fromOpaque(ctx).release() }

        var ref: DNSServiceRef?
        let err = DNSServiceResolve(
            &ref,
            0,
            interfaceIndex,
            name,
            type,
            domain,
            { _, _, _, errorCode, _, hosttarget, port, txtLen, txtRecord, context in
                guard let context else { return }
                let b = Unmanaged<ResolveBox>.fromOpaque(context).takeUnretainedValue()
                defer { b.done = true }
                guard errorCode == kDNSServiceErr_NoError, let hosttarget else { return }

                let host = String(cString: hosttarget)
                let hostPort = UInt16(bigEndian: port)
                let txtData: Data
                if let txtRecord, txtLen > 0 {
                    txtData = Data(bytes: txtRecord, count: Int(txtLen))
                } else {
                    txtData = Data()
                }
                let txt = BonjourRecord.decodeTXTRecord(txtData)
                guard let identifier = txt["identifier"], let authTag = txt["authTag"] else {
                    return
                }
                let record = BonjourRecord(
                    instanceName: b.instanceName,
                    identifier: identifier,
                    authTag: authTag,
                    version: txt["ver"] ?? "26",
                    minVersion: txt["minVer"] ?? "8",
                    flags: txt["flags"] ?? "0",
                    port: hostPort,
                    originalHostTarget: host,
                    capturedAt: Date()
                )
                b.result = DiscoveredBonjourService(
                    instanceName: b.instanceName,
                    interfaceIndex: b.interfaceIndex,
                    interfaceName: b.interfaceName,
                    hostTarget: host,
                    port: hostPort,
                    resolvedAddresses: [],
                    record: record
                )
            },
            ctx
        )

        guard err == kDNSServiceErr_NoError, let resolveRef = ref else { return nil }
        defer { DNSServiceRefDeallocate(resolveRef) }

        let fd = DNSServiceRefSockFD(resolveRef)
        guard fd >= 0 else { return nil }

        let deadline = Date().addingTimeInterval(timeout)
        while !box.done && Date() < deadline {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let rc = poll(&pfd, 1, 200)
            if rc > 0 && (pfd.revents & Int16(POLLIN)) != 0 {
                if DNSServiceProcessResult(resolveRef) != kDNSServiceErr_NoError {
                    break
                }
            }
        }
        guard let resolved = box.result else { return nil }
        let addrs = resolveHostAddresses(host: resolved.hostTarget, interfaceIndex: interfaceIndex, timeout: 1.0)
        return DiscoveredBonjourService(
            instanceName: resolved.instanceName,
            interfaceIndex: resolved.interfaceIndex,
            interfaceName: resolved.interfaceName,
            hostTarget: resolved.hostTarget,
            port: resolved.port,
            resolvedAddresses: addrs,
            record: resolved.record
        )
    }

    private final class AddrBox: @unchecked Sendable {
        var addresses: [String] = []
        var moreComing = true
    }

    /// Resolves IPv4 and IPv6 addresses for an mDNS host target scoped to a specific interface.
    private static func resolveHostAddresses(
        host: String,
        interfaceIndex: UInt32,
        timeout: TimeInterval = 1.0
    ) -> [String] {
        let box = AddrBox()
        let ctx = Unmanaged.passRetained(box).toOpaque()
        defer { Unmanaged<AddrBox>.fromOpaque(ctx).release() }

        var ref: DNSServiceRef?
        let err = DNSServiceGetAddrInfo(
            &ref,
            0,
            interfaceIndex,
            DNSServiceProtocol(kDNSServiceProtocol_IPv4 | kDNSServiceProtocol_IPv6),
            host,
            { _, flags, _, errorCode, _, address, _, context in
                guard let context else { return }
                let b = Unmanaged<AddrBox>.fromOpaque(context).takeUnretainedValue()
                b.moreComing = (flags & DNSServiceFlags(kDNSServiceFlagsMoreComing)) != 0
                guard errorCode == kDNSServiceErr_NoError,
                      (flags & DNSServiceFlags(kDNSServiceFlagsAdd)) != 0,
                      let address else { return }

                let family = Int32(address.pointee.sa_family)
                if family == AF_INET {
                    var sin = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                    var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    let ip: String? = buf.withUnsafeMutableBufferPointer { ptr in
                        guard let base = ptr.baseAddress,
                              inet_ntop(AF_INET, &sin.sin_addr, base, socklen_t(ptr.count)) != nil else { return nil }
                        return String(cString: base)
                    }
                    if let ip, !b.addresses.contains(ip) {
                        b.addresses.append(ip)
                    }
                } else if family == AF_INET6 {
                    var sin6 = address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                    var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                    let ip: String? = buf.withUnsafeMutableBufferPointer { ptr in
                        guard let base = ptr.baseAddress,
                              inet_ntop(AF_INET6, &sin6.sin6_addr, base, socklen_t(ptr.count)) != nil else { return nil }
                        return String(cString: base)
                    }
                    if let ip, !b.addresses.contains(ip) {
                        b.addresses.append(ip)
                    }
                }
            },
            ctx
        )

        guard err == kDNSServiceErr_NoError, let addrRef = ref else { return [] }
        defer { DNSServiceRefDeallocate(addrRef) }

        let fd = DNSServiceRefSockFD(addrRef)
        guard fd >= 0 else { return [] }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let rc = poll(&pfd, 1, 150)
            if rc > 0 && (pfd.revents & Int16(POLLIN)) != 0 {
                if DNSServiceProcessResult(addrRef) != kDNSServiceErr_NoError {
                    break
                }
                if !box.moreComing && !box.addresses.isEmpty {
                    break
                }
            }
        }
        // Prefer IPv4 first for fast LAN reachability checks, then IPv6.
        let v4 = box.addresses.filter { !$0.contains(":") }
        let v6 = box.addresses.filter { $0.contains(":") }
        return v4 + v6
    }
}
