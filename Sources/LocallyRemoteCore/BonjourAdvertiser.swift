import Foundation
import Darwin
import dnssd

public enum BonjourAdvertiserError: Error, LocalizedError {
    case invalidAddress(String)
    case dnsServiceFailed(String, Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidAddress(let addr):
            return "Invalid IP address for Bonjour advertisement: \(addr)"
        case .dnsServiceFailed(let op, let code):
            return "\(op) failed with DNSServiceErrorType \(code)"
        }
    }
}

/// Registers a proxy `_remotepairing._tcp` Bonjour service and matching `AAAA`/`A` host record
/// scoped to the chosen local interface (default `lo0`, `fe80::1`).
public final class BonjourAdvertiser: @unchecked Sendable {
    private let lock = NSLock()
    private var connRef: DNSServiceRef?
    private var recordRef: DNSRecordRef?
    private var serviceRef: DNSServiceRef?
    private var running = false
    private var workerThread: Thread?

    public let hostname: String
    public let bindEndpoint: NetworkHelpers.BindEndpoint
    public let record: BonjourRecord
    public let advertisedPort: UInt16

    public init(
        hostname: String,
        bindEndpoint: NetworkHelpers.BindEndpoint,
        record: BonjourRecord,
        advertisedPort: UInt16
    ) {
        self.hostname = hostname
        self.bindEndpoint = bindEndpoint
        self.record = record
        self.advertisedPort = advertisedPort
    }

    public func start() throws {
        lock.lock()
        if running {
            lock.unlock()
            return
        }
        lock.unlock()

        var sharedConn: DNSServiceRef?
        let connErr = DNSServiceCreateConnection(&sharedConn)
        guard connErr == kDNSServiceErr_NoError, let sharedConn else {
            throw BonjourAdvertiserError.dnsServiceFailed("DNSServiceCreateConnection", connErr)
        }

        var regRecord: DNSRecordRef?
        let recErr: DNSServiceErrorType
        if bindEndpoint.isIPv6 {
            var addr6 = in6_addr()
            guard inet_pton(AF_INET6, bindEndpoint.address, &addr6) == 1 else {
                DNSServiceRefDeallocate(sharedConn)
                throw BonjourAdvertiserError.invalidAddress(bindEndpoint.address)
            }
            recErr = withUnsafeBytes(of: &addr6) { buf in
                DNSServiceRegisterRecord(
                    sharedConn,
                    &regRecord,
                    DNSServiceFlags(kDNSServiceFlagsShared),
                    bindEndpoint.interfaceIndex,
                    hostname,
                    UInt16(kDNSServiceType_AAAA),
                    UInt16(kDNSServiceClass_IN),
                    UInt16(buf.count),
                    buf.baseAddress,
                    120,
                    { _, _, _, _, _ in },
                    nil
                )
            }
        } else {
            var addr4 = in_addr()
            guard inet_pton(AF_INET, bindEndpoint.address, &addr4) == 1 else {
                DNSServiceRefDeallocate(sharedConn)
                throw BonjourAdvertiserError.invalidAddress(bindEndpoint.address)
            }
            recErr = withUnsafeBytes(of: &addr4) { buf in
                DNSServiceRegisterRecord(
                    sharedConn,
                    &regRecord,
                    DNSServiceFlags(kDNSServiceFlagsShared),
                    bindEndpoint.interfaceIndex,
                    hostname,
                    UInt16(kDNSServiceType_A),
                    UInt16(kDNSServiceClass_IN),
                    UInt16(buf.count),
                    buf.baseAddress,
                    120,
                    { _, _, _, _, _ in },
                    nil
                )
            }
        }

        guard recErr == kDNSServiceErr_NoError else {
            DNSServiceRefDeallocate(sharedConn)
            throw BonjourAdvertiserError.dnsServiceFailed("DNSServiceRegisterRecord", recErr)
        }

        let txtBytes = record.encodeTXTRecord()
        var svcRef: DNSServiceRef?
        let svcErr = txtBytes.withUnsafeBytes { buf in
            DNSServiceRegister(
                &svcRef,
                0,
                bindEndpoint.interfaceIndex,
                record.instanceName,
                "_remotepairing._tcp",
                "local.",
                hostname,
                advertisedPort.bigEndian,
                UInt16(buf.count),
                buf.baseAddress,
                { _, _, _, _, _, _, _ in },
                nil
            )
        }

        guard svcErr == kDNSServiceErr_NoError, let svcRef else {
            DNSServiceRefDeallocate(sharedConn)
            throw BonjourAdvertiserError.dnsServiceFailed("DNSServiceRegister", svcErr)
        }

        lock.lock()
        self.connRef = sharedConn
        self.recordRef = regRecord
        self.serviceRef = svcRef
        self.running = true
        lock.unlock()

        let thread = Thread { [weak self] in
            self?.processEvents()
        }
        thread.name = "LocallyRemote.BonjourAdvertiser"
        lock.lock()
        self.workerThread = thread
        lock.unlock()
        thread.start()
    }

    public func stop() {
        lock.lock()
        let wasRunning = running
        running = false
        let c = connRef
        let s = serviceRef
        connRef = nil
        recordRef = nil
        serviceRef = nil
        lock.unlock()

        guard wasRunning else { return }
        if let s { DNSServiceRefDeallocate(s) }
        if let c { DNSServiceRefDeallocate(c) }
    }

    deinit {
        stop()
    }

    private func isRunning() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    private func processEvents() {
        lock.lock()
        let conn = connRef
        let svc = serviceRef
        lock.unlock()
        guard let conn, let svc else { return }

        let fd1 = DNSServiceRefSockFD(conn)
        let fd2 = DNSServiceRefSockFD(svc)
        guard fd1 >= 0, fd2 >= 0 else { return }

        var pfds = [
            pollfd(fd: fd1, events: Int16(POLLIN), revents: 0),
            pollfd(fd: fd2, events: Int16(POLLIN), revents: 0)
        ]

        while isRunning() {
            pfds[0].revents = 0
            pfds[1].revents = 0
            let rc = poll(&pfds, 2, 250)
            if rc > 0 {
                if !isRunning() { break }
                if (pfds[0].revents & Int16(POLLIN)) != 0 {
                    if DNSServiceProcessResult(conn) != kDNSServiceErr_NoError { break }
                }
                if (pfds[1].revents & Int16(POLLIN)) != 0 {
                    if DNSServiceProcessResult(svc) != kDNSServiceErr_NoError { break }
                }
            } else if rc < 0 && errno != EINTR {
                break
            }
        }
    }
}
