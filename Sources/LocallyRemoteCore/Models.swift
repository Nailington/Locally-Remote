import Foundation

/// Captured `_remotepairing._tcp` Bonjour advertisement fields from a paired iOS device.
public struct BonjourRecord: Codable, Equatable, Sendable {
    public var instanceName: String
    public var identifier: String
    public var authTag: String
    public var version: String
    public var minVersion: String
    public var flags: String
    public var port: UInt16
    public var originalHostTarget: String?
    public var capturedAt: Date

    public init(
        instanceName: String,
        identifier: String,
        authTag: String,
        version: String = "26",
        minVersion: String = "8",
        flags: String = "0",
        port: UInt16 = 49152,
        originalHostTarget: String? = nil,
        capturedAt: Date = Date()
    ) {
        self.instanceName = instanceName
        self.identifier = identifier
        self.authTag = authTag
        self.version = version
        self.minVersion = minVersion
        self.flags = flags
        self.port = port
        self.originalHostTarget = originalHostTarget
        self.capturedAt = capturedAt
    }

    /// Encodes TXT key/value pairs into RFC 6763 DNS-SD TXT wire format.
    public func encodeTXTRecord() -> [UInt8] {
        let entries = [
            "identifier=\(identifier)",
            "authTag=\(authTag)",
            "ver=\(version)",
            "minVer=\(minVersion)",
            "flags=\(flags)"
        ]
        var result: [UInt8] = []
        for entry in entries {
            let bytes = Array(entry.utf8)
            guard bytes.count <= 255 else { continue }
            result.append(UInt8(bytes.count))
            result.append(contentsOf: bytes)
        }
        return result
    }

    /// Decodes RFC 6763 DNS-SD TXT wire bytes into a dictionary.
    public static func decodeTXTRecord(_ data: Data) -> [String: String] {
        var result: [String: String] = [:]
        var index = data.startIndex
        while index < data.endIndex {
            let length = Int(data[index])
            index = data.index(after: index)
            guard length > 0, data.distance(from: index, to: data.endIndex) >= length else {
                break
            }
            let slice = data[index..<data.index(index, offsetBy: length)]
            index = data.index(index, offsetBy: length)
            if let entry = String(data: slice, encoding: .utf8),
               let eq = entry.firstIndex(of: "=") {
                let key = String(entry[..<eq])
                let value = String(entry[entry.index(after: eq)...])
                result[key] = value
            }
        }
        return result
    }
}

/// Strategy for which local interface/address the Bonjour advert and TCP relay bind to.
public enum BindMode: String, Codable, Equatable, Sendable, CaseIterable {
    /// Loopback IPv6 link-local `fe80::1%lo0`: zero collision with `127.0.0.1` / `::1`, no LAN multicast spam.
    case lo0
    /// Primary active physical LAN interface (e.g. `en1` or `en0` IPv6 link-local or IPv4) if `lo0` delegate is restricted.
    case lan
    /// Loopback IPv4 `127.0.0.1` (only recommended with explicit narrow port range or testing).
    case loopback4
}

/// Persistent record for a paired iOS device bridged over Tailscale.
public struct SavedDevice: Codable, Equatable, Sendable, Identifiable {
    public var id: String { udid }
    public var udid: String
    public var coreDeviceIdentifier: String?
    public var name: String
    public var model: String?
    public var tailscaleDNSName: String?
    public var tailscaleNodeKey: String?
    public var tailscaleIP: String
    public var bonjourRecord: BonjourRecord
    public var enabled: Bool
    public var updatedAt: Date

    public init(
        udid: String,
        coreDeviceIdentifier: String? = nil,
        name: String,
        model: String? = nil,
        tailscaleDNSName: String? = nil,
        tailscaleNodeKey: String? = nil,
        tailscaleIP: String,
        bonjourRecord: BonjourRecord,
        enabled: Bool = true,
        updatedAt: Date = Date()
    ) {
        self.udid = udid
        self.coreDeviceIdentifier = coreDeviceIdentifier
        self.name = name
        self.model = model
        self.tailscaleDNSName = tailscaleDNSName
        self.tailscaleNodeKey = tailscaleNodeKey
        self.tailscaleIP = tailscaleIP
        self.bonjourRecord = bonjourRecord
        self.enabled = enabled
        self.updatedAt = updatedAt
    }
}

/// Top-level configuration file stored at `~/.config/locally-remote/config.json`.
public struct AppConfig: Codable, Equatable, Sendable {
    public var schemaVersion: Int
    public var bindMode: BindMode
    public var portRangeStart: UInt16
    public var portRangeEnd: UInt16
    public var pollIntervalSeconds: Double
    public var devices: [SavedDevice]

    public init(
        schemaVersion: Int = 1,
        bindMode: BindMode = .lo0,
        portRangeStart: UInt16 = 49152,
        portRangeEnd: UInt16 = 65499,
        pollIntervalSeconds: Double = 5.0,
        devices: [SavedDevice] = []
    ) {
        self.schemaVersion = schemaVersion
        self.bindMode = bindMode
        self.portRangeStart = portRangeStart
        self.portRangeEnd = portRangeEnd
        self.pollIntervalSeconds = pollIntervalSeconds
        self.devices = devices
    }
}

/// Live Tailscale peer info parsed from `tailscale status --json`.
public struct TailscalePeer: Codable, Equatable, Sendable {
    public var nodeKey: String
    public var dnsName: String
    public var hostName: String
    public var os: String
    public var ips: [String]
    public var online: Bool
    public var active: Bool

    public var ipv4: String? {
        ips.first(where: { !$0.contains(":") })
    }

    public var ipv6: String? {
        ips.first(where: { $0.contains(":") })
    }

    public var shortName: String {
        dnsName.split(separator: ".").first.map(String.init) ?? hostName
    }
}

/// Paired physical iOS device info parsed from `xcrun devicectl list devices --json-output`.
public struct DeviceCtlDevice: Codable, Equatable, Sendable {
    public var coreDeviceIdentifier: String
    public var udid: String
    public var name: String
    public var model: String
    public var productType: String
    public var osVersion: String
    public var pairingState: String
    public var tunnelState: String
    public var transportType: String?
    public var potentialHostnames: [String]
    public var developerModeStatus: String?
}

/// Per-device runtime status emitted by the daemon to `~/.config/locally-remote/state.json`.
public struct DeviceBridgeStatus: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case localLAN = "local_lan"
        case bridged = "bridged"
        case unreachable = "unreachable"
        case tailscaleOffline = "tailscale_offline"
        case disabled = "disabled"
        case error = "error"
    }

    public var udid: String
    public var name: String
    public var phase: Phase
    public var detail: String
    public var tailscaleIP: String
    public var tailscaleOnline: Bool
    public var remotePort: UInt16
    public var lanPresent: Bool
    public var proxyBindAddress: String?
    public var proxyInterface: String?
    public var bonjourHost: String?
    public var boundPortCount: Int
    public var activeConnections: Int
    public var activeTunnelPorts: [UInt16]
    public var totalConnectionsHandled: UInt64
    public var totalBytesRelayed: UInt64
    public var lastUpdated: Date
}

/// Overall daemon runtime state snapshot written periodically by `locally-remote daemon`.
public struct DaemonRuntimeState: Codable, Equatable, Sendable {
    public var pid: Int32
    public var startedAt: Date
    public var updatedAt: Date
    public var bindMode: BindMode
    public var forceBridge: Bool
    public var devices: [DeviceBridgeStatus]
}
