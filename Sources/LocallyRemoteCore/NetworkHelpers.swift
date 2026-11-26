import Foundation
import Darwin

public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
}

public enum NetworkHelpers {
    /// Runs an external command synchronously with an optional timeout and returns stdout/stderr.
    public static func runProcess(
        executable: String,
        arguments: [String],
        timeout: TimeInterval = 15
    ) throws -> ProcessResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        let deadline = DispatchTime.now() + timeout
        let group = DispatchGroup()
        group.enter()
        process.terminationHandler = { _ in group.leave() }

        if group.wait(timeout: deadline) == .timedOut {
            process.terminate()
            _ = group.wait(timeout: .now() + 2)
        }

        let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        return ProcessResult(
            exitCode: process.terminationStatus,
            stdout: String(data: outData, encoding: .utf8) ?? "",
            stderr: String(data: errData, encoding: .utf8) ?? ""
        )
    }

    /// Raises `RLIMIT_NOFILE` so the kqueue relay can bind the full ephemeral port range without sudo.
    @discardableResult
    public static func raiseFileDescriptorLimit(target: UInt64 = 24576) -> UInt64 {
        var rl = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &rl) == 0 else { return 0 }
        let maxFiles = sysctlMaxFilesPerProc() ?? 49152
        let clamped = min(target, min(rl.rlim_max, maxFiles > 1024 ? maxFiles - 512 : target))
        if rl.rlim_cur < clamped {
            rl.rlim_cur = clamped
            _ = setrlimit(RLIMIT_NOFILE, &rl)
        }
        getrlimit(RLIMIT_NOFILE, &rl)
        return rl.rlim_cur
    }

    public static func sysctlMaxFilesPerProc() -> UInt64? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("kern.maxfilesperproc", &value, &size, nil, 0) == 0, value > 0 {
            return UInt64(value)
        }
        return nil
    }

    /// Non-blocking TCP connect probe to test whether `<ip>:<port>` is accepting connections.
    public static func probeTCP(
        host: String,
        port: UInt16,
        scopeIndex: UInt32 = 0,
        timeoutSeconds: Double = 2.0
    ) -> Bool {
        let isIPv6 = host.contains(":")
        let fd = socket(isIPv6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let connectResult: Int32
        if isIPv6 {
            var addr = sockaddr_in6()
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = port.bigEndian
            addr.sin6_scope_id = scopeIndex
            guard inet_pton(AF_INET6, host, &addr.sin6_addr) == 1 else { return false }
            connectResult = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        } else {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return false }
            connectResult = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        if connectResult == 0 {
            return true
        }
        if errno != EINPROGRESS {
            return false
        }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let timeoutMs = Int32(max(100, timeoutSeconds * 1000))
        let ready = poll(&pfd, 1, timeoutMs)
        guard ready > 0 else { return false }

        var sockErr: Int32 = 0
        var errLen = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &sockErr, &errLen) == 0 else {
            return false
        }
        return sockErr == 0
    }

    /// Returns true if an IP address belongs to loopback or Tailscale (100.64.0.0/10 or fd7a:115c:a1e0::/48).
    public static func isTailscaleOrLoopbackAddress(_ ip: String) -> Bool {
        let lower = ip.lowercased()
        if lower == "::1" || lower == "fe80::1" || lower.hasPrefix("127.") {
            return true
        }
        if lower.hasPrefix("fd7a:115c:a1e0:") {
            return true
        }
        let parts = lower.split(separator: ".")
        if parts.count == 4, let a = Int(parts[0]), let b = Int(parts[1]) {
            if a == 100 && (64...127).contains(b) {
                return true
            }
        }
        return false
    }

    /// Resolves the best active RemotePairing port on the remote iPhone (prefers `preferredPort`, usually `49152`).
    public static func discoverRemotePairingPort(
        host: String,
        preferredPort: UInt16 = 49152,
        timeoutSeconds: Double = 1.5
    ) -> UInt16? {
        if probeTCP(host: host, port: preferredPort, timeoutSeconds: timeoutSeconds) {
            return preferredPort
        }
        if preferredPort != 49152, probeTCP(host: host, port: 49152, timeoutSeconds: timeoutSeconds) {
            return 49152
        }
        return nil
    }

    public struct BindEndpoint: Sendable, Equatable {
        public let interfaceName: String
        public let interfaceIndex: UInt32
        public let address: String
        public let isIPv6: Bool
    }

    /// Picks the concrete local interface and IP address for the selected `BindMode`.
    public static func resolveBindEndpoint(mode: BindMode) -> BindEndpoint? {
        switch mode {
        case .lo0:
            let idx = if_nametoindex("lo0")
            guard idx > 0 else { return nil }
            return BindEndpoint(interfaceName: "lo0", interfaceIndex: idx, address: "fe80::1", isIPv6: true)
        case .loopback4:
            let idx = if_nametoindex("lo0")
            guard idx > 0 else { return nil }
            return BindEndpoint(interfaceName: "lo0", interfaceIndex: idx, address: "127.0.0.1", isIPv6: false)
        case .lan:
            return findPrimaryLANEndpoint()
        }
    }

    /// Finds the active primary LAN interface (`en0`, `en1`, etc.) preferring its link-local IPv6 address (or IPv4 fallback).
    public static func findPrimaryLANEndpoint() -> BindEndpoint? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var ipv6Candidates: [(name: String, index: UInt32, addr: String)] = []
        var ipv4Candidates: [(name: String, index: UInt32, addr: String)] = []

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            defer { ptr = current.pointee.ifa_next }
            guard let namePtr = current.pointee.ifa_name,
                  let sa = current.pointee.ifa_addr else { continue }
            let name = String(cString: namePtr)
            let flags = Int32(current.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0 && (flags & IFF_RUNNING) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            guard isUp, !isLoopback, name.hasPrefix("en") else { continue }
            let index = if_nametoindex(name)
            guard index > 0 else { continue }

            let family = Int32(sa.pointee.sa_family)
            if family == AF_INET6 {
                var sin6 = sa.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { $0.pointee }
                var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                let ip: String? = buf.withUnsafeMutableBufferPointer { ptr in
                    guard let base = ptr.baseAddress,
                          inet_ntop(AF_INET6, &sin6.sin6_addr, base, socklen_t(ptr.count)) != nil else {
                        return nil
                    }
                    return String(cString: base)
                }
                if let ip, ip.lowercased().hasPrefix("fe80:") {
                    ipv6Candidates.append((name, index, ip))
                }
            } else if family == AF_INET {
                var sin = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee }
                var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                let ip: String? = buf.withUnsafeMutableBufferPointer { ptr in
                    guard let base = ptr.baseAddress,
                          inet_ntop(AF_INET, &sin.sin_addr, base, socklen_t(ptr.count)) != nil else {
                        return nil
                    }
                    return String(cString: base)
                }
                if let ip, !ip.hasPrefix("169.254.") {
                    ipv4Candidates.append((name, index, ip))
                }
            }
        }

        // Prefer an interface with an active IPv4 address, then bind its link-local IPv6
        // so we do not collide with IPv4 ephemeral ports on the Mac.
        let activeNames = Set(ipv4Candidates.map(\.name))
        if let v6 = ipv6Candidates.first(where: { activeNames.contains($0.name) }) {
            return BindEndpoint(interfaceName: v6.name, interfaceIndex: v6.index, address: v6.addr, isIPv6: true)
        }
        if let v4 = ipv4Candidates.first {
            return BindEndpoint(interfaceName: v4.name, interfaceIndex: v4.index, address: v4.addr, isIPv6: false)
        }
        return nil
    }

    /// Checks whether a PID is currently alive on macOS.
    public static func isProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// Produces a safe mDNS hostname label from a device name / UDID.
    public static func makeProxyHostname(udid: String) -> String {
        let suffix = udid.replacingOccurrences(of: "-", with: "").lowercased().prefix(8)
        return "locally-remote-\(suffix).local."
    }
}
