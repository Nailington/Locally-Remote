import Foundation
import Darwin

public struct RelayStats: Sendable, Equatable {
    public let boundPortCount: Int
    public let activeConnections: Int
    public let activeTunnelPorts: [UInt16]
    public let totalConnectionsHandled: UInt64
    public let totalBytesRelayed: UInt64
}

public enum PortRelayError: Error, LocalizedError {
    case kqueueFailed(Int32)
    case noPortsBound(String)

    public var errorDescription: String? {
        switch self {
        case .kqueueFailed(let code):
            return "kqueue() failed with errno \(code)"
        case .noPortsBound(let msg):
            return "Failed to bind any local relay ports: \(msg)"
        }
    }
}

/// Multi-port TCP relay built on `kqueue`.
/// Binds every port in `portRange` on `bindEndpoint` (default `fe80::1%lo0`, `49152...65499`)
/// and forwards accepted connections on port `P` to `remoteHost:P` over Tailscale.
///
/// Binding `fe80::1%lo0` leaves `127.0.0.1` and `::1` untouched, and stopping at `65499` leaves
/// `65500...65535` open for `remotepairingd` client source ports while covering iOS ephemeral tunnel ports.
public final class PortRelayServer: @unchecked Sendable {
    private typealias KEvent = Darwin.kevent

    public let bindEndpoint: NetworkHelpers.BindEndpoint
    public let remoteHost: String
    public let controlPort: UInt16
    public let portRange: ClosedRange<UInt16>
    private let verbose: Bool

    private let lock = NSLock()
    private var running = false
    private var kqFD: Int32 = -1
    private var wakePipe: [Int32] = [-1, -1]
    private var listenFDToPort: [Int32: UInt16] = [:]
    private var activeByPort: [UInt16: Int] = [:]
    private var activeClientFDs: Set<Int32> = []
    private var totalConnections: UInt64 = 0
    private var totalBytes: UInt64 = 0
    private var acceptThread: Thread?

    public init(
        bindEndpoint: NetworkHelpers.BindEndpoint,
        remoteHost: String,
        controlPort: UInt16 = 49152,
        portRange: ClosedRange<UInt16> = 49152...65499,
        verbose: Bool = false
    ) {
        self.bindEndpoint = bindEndpoint
        self.remoteHost = remoteHost
        self.controlPort = controlPort
        self.portRange = portRange
        self.verbose = verbose
    }

    public func stats() -> RelayStats {
        lock.lock()
        defer { lock.unlock() }
        let totalActive = activeByPort.values.reduce(0, +)
        let tunnelPorts = activeByPort
            .filter { $0.key != controlPort && $0.value > 0 }
            .map(\.key)
            .sorted()
        return RelayStats(
            boundPortCount: listenFDToPort.count,
            activeConnections: totalActive,
            activeTunnelPorts: tunnelPorts,
            totalConnectionsHandled: totalConnections,
            totalBytesRelayed: totalBytes
        )
    }

    public func start() throws {
        lock.lock()
        if running {
            lock.unlock()
            return
        }
        lock.unlock()

        // Ensure process FD limit can hold the entire ephemeral port pool + active relays.
        let desiredLimit = UInt64(portRange.count) + 4096
        NetworkHelpers.raiseFileDescriptorLimit(target: desiredLimit)

        let kq = kqueue()
        guard kq >= 0 else {
            throw PortRelayError.kqueueFailed(errno)
        }

        var pipeFDs: [Int32] = [-1, -1]
        if pipe(&pipeFDs) == 0 {
            var wakeEv = KEvent(
                ident: UInt(pipeFDs[0]),
                filter: Int16(EVFILT_READ),
                flags: UInt16(EV_ADD | EV_ENABLE),
                fflags: 0,
                data: 0,
                udata: nil
            )
            _ = kevent(kq, &wakeEv, 1, nil, 0, nil)
        }

        var boundMap: [Int32: UInt16] = [:]
        boundMap.reserveCapacity(portRange.count)

        var batchEvents: [KEvent] = []
        batchEvents.reserveCapacity(256)

        // Ensure controlPort is always included even if outside portRange
        var portsToBind: [UInt16] = Array(portRange)
        if !portRange.contains(controlPort) {
            portsToBind.insert(controlPort, at: 0)
        }

        for port in portsToBind {
            guard let fd = Self.createListeningSocket(endpoint: bindEndpoint, port: port) else {
                continue
            }
            boundMap[fd] = port
            batchEvents.append(KEvent(
                ident: UInt(fd),
                filter: Int16(EVFILT_READ),
                flags: UInt16(EV_ADD | EV_ENABLE),
                fflags: 0,
                data: 0,
                udata: nil
            ))
            if batchEvents.count >= 256 {
                _ = batchEvents.withUnsafeBufferPointer { ptr in
                    kevent(kq, ptr.baseAddress, Int32(ptr.count), nil, 0, nil)
                }
                batchEvents.removeAll(keepingCapacity: true)
            }
        }

        if !batchEvents.isEmpty {
            _ = batchEvents.withUnsafeBufferPointer { ptr in
                kevent(kq, ptr.baseAddress, Int32(ptr.count), nil, 0, nil)
            }
        }

        guard !boundMap.isEmpty else {
            close(kq)
            if pipeFDs[0] >= 0 { close(pipeFDs[0]) }
            if pipeFDs[1] >= 0 { close(pipeFDs[1]) }
            throw PortRelayError.noPortsBound("bind failed on \(bindEndpoint.address) (\(bindEndpoint.interfaceName))")
        }

        lock.lock()
        self.kqFD = kq
        self.wakePipe = pipeFDs
        self.listenFDToPort = boundMap
        self.running = true
        lock.unlock()

        let thread = Thread { [weak self] in
            self?.acceptLoop()
        }
        thread.name = "LocallyRemote.PortRelay.\(remoteHost)"
        lock.lock()
        self.acceptThread = thread
        lock.unlock()
        thread.start()
    }

    public func stop() {
        lock.lock()
        guard running else {
            lock.unlock()
            return
        }
        running = false
        let wfd = wakePipe[1]
        let rfd = wakePipe[0]
        wakePipe = [-1, -1]
        let kq = kqFD
        kqFD = -1
        let fdsToClose = Array(listenFDToPort.keys)
        listenFDToPort.removeAll()
        let clientsToClose = Array(activeClientFDs)
        activeClientFDs.removeAll()
        activeByPort.removeAll()
        lock.unlock()

        if wfd >= 0 {
            var byte: UInt8 = 1
            _ = write(wfd, &byte, 1)
            close(wfd)
        }
        if rfd >= 0 { close(rfd) }
        if kq >= 0 { close(kq) }
        for fd in fdsToClose { close(fd) }
        for fd in clientsToClose {
            shutdown(fd, SHUT_RDWR)
            close(fd)
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

    private func acceptLoop() {
        var events = Array<KEvent>(repeating: KEvent(), count: 64)
        while isRunning() {
            lock.lock()
            let kq = kqFD
            let wakeRead = wakePipe[0]
            lock.unlock()
            guard kq >= 0 else { break }

            var ts = timespec(tv_sec: 1, tv_nsec: 0)
            let count = kevent(kq, nil, 0, &events, Int32(events.count), &ts)
            if count < 0 {
                if errno == EINTR { continue }
                break
            }
            guard count > 0 else { continue }

            for i in 0..<Int(count) {
                let fd = Int32(events[i].ident)
                if fd == wakeRead {
                    return
                }
                lock.lock()
                let port = listenFDToPort[fd]
                lock.unlock()
                guard let port else { continue }

                while true {
                    let clientFD = accept(fd, nil, nil)
                    if clientFD < 0 {
                        break
                    }
                    // Disable SIGPIPE on client socket
                    var noSigPipe: Int32 = 1
                    setsockopt(clientFD, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
                    var noDelay: Int32 = 1
                    setsockopt(clientFD, IPPROTO_TCP, TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))

                    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                        self?.handleClient(clientFD: clientFD, port: port)
                    }
                }
            }
        }
    }

    private func handleClient(clientFD: Int32, port: UInt16) {
        guard let upstreamFD = Self.connectUpstream(host: remoteHost, port: port, timeoutSeconds: 5.0) else {
            if verbose {
                fputs("[relay] failed to connect upstream \(remoteHost):\(port)\n", stderr)
            }
            close(clientFD)
            return
        }

        lock.lock()
        if !running {
            lock.unlock()
            close(clientFD)
            close(upstreamFD)
            return
        }
        activeClientFDs.insert(clientFD)
        activeClientFDs.insert(upstreamFD)
        activeByPort[port, default: 0] += 1
        totalConnections += 1
        lock.unlock()

        if verbose {
            let role = (port == controlPort) ? "control" : "tunnel"
            fputs("[relay] connected \(role) port \(port) -> \(remoteHost):\(port)\n", stderr)
        }

        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let bytes = Self.pump(from: clientFD, to: upstreamFD)
            self?.recordBytes(bytes)
            group.leave()
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let bytes = Self.pump(from: upstreamFD, to: clientFD)
            self?.recordBytes(bytes)
            group.leave()
        }

        group.wait()

        lock.lock()
        activeClientFDs.remove(clientFD)
        activeClientFDs.remove(upstreamFD)
        if let cur = activeByPort[port], cur > 1 {
            activeByPort[port] = cur - 1
        } else {
            activeByPort.removeValue(forKey: port)
        }
        lock.unlock()

        close(clientFD)
        close(upstreamFD)

        if verbose {
            fputs("[relay] closed port \(port)\n", stderr)
        }
    }

    private func recordBytes(_ count: UInt64) {
        guard count > 0 else { return }
        lock.lock()
        totalBytes += count
        lock.unlock()
    }

    private static func pump(from src: Int32, to dst: Int32) -> UInt64 {
        var buffer = [UInt8](repeating: 0, count: 65536)
        var total: UInt64 = 0
        while true {
            let n = read(src, &buffer, buffer.count)
            if n < 0 {
                if errno == EINTR { continue }
                break
            }
            if n == 0 { break }
            var offset = 0
            var failed = false
            while offset < n {
                let written = buffer.withUnsafeBytes { ptr in
                    write(dst, ptr.baseAddress!.advanced(by: offset), n - offset)
                }
                if written < 0 {
                    if errno == EINTR { continue }
                    failed = true
                    break
                }
                if written == 0 {
                    failed = true
                    break
                }
                offset += written
            }
            total += UInt64(offset)
            if failed { break }
        }
        _ = shutdown(dst, SHUT_WR)
        return total
    }

    private static func createListeningSocket(endpoint: NetworkHelpers.BindEndpoint, port: UInt16) -> Int32? {
        let fd = socket(endpoint.isIPv6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let bindResult: Int32
        if endpoint.isIPv6 {
            setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &yes, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in6()
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = port.bigEndian
            addr.sin6_scope_id = endpoint.interfaceIndex
            guard inet_pton(AF_INET6, endpoint.address, &addr.sin6_addr) == 1 else {
                close(fd)
                return nil
            }
            bindResult = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        } else {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            guard inet_pton(AF_INET, endpoint.address, &addr.sin_addr) == 1 else {
                close(fd)
                return nil
            }
            bindResult = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        guard bindResult == 0, listen(fd, 16) == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    private static func connectUpstream(host: String, port: UInt16, timeoutSeconds: Double) -> Int32? {
        let isIPv6 = host.contains(":")
        let fd = socket(isIPv6 ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }

        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        var noDelay: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))

        let origFlags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, origFlags | O_NONBLOCK)

        let rc: Int32
        if isIPv6 {
            var addr = sockaddr_in6()
            addr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr.sin6_family = sa_family_t(AF_INET6)
            addr.sin6_port = port.bigEndian
            guard inet_pton(AF_INET6, host, &addr.sin6_addr) == 1 else {
                close(fd)
                return nil
            }
            rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        } else {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = port.bigEndian
            guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
                close(fd)
                return nil
            }
            rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        if rc != 0 {
            guard errno == EINPROGRESS else {
                close(fd)
                return nil
            }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = poll(&pfd, 1, Int32(max(500, timeoutSeconds * 1000)))
            guard ready > 0 else {
                close(fd)
                return nil
            }
            var sockErr: Int32 = 0
            var errLen = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &sockErr, &errLen) == 0, sockErr == 0 else {
                close(fd)
                return nil
            }
        }

        // Restore blocking mode for clean read/write pumping
        _ = fcntl(fd, F_SETFL, origFlags)
        return fd
    }
}
