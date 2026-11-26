import Foundation

public enum TailscaleError: Error, LocalizedError {
    case cliNotFound
    case commandFailed(String)
    case invalidJSON(String)

    public var errorDescription: String? {
        switch self {
        case .cliNotFound:
            return "Tailscale CLI not found. Install Tailscale.app or put `tailscale` in PATH."
        case .commandFailed(let msg):
            return "Tailscale command failed: \(msg)"
        case .invalidJSON(let msg):
            return "Failed to parse Tailscale status JSON: \(msg)"
        }
    }
}

public struct TailscaleSnapshot: Sendable {
    public let backendState: String
    public let selfDNSName: String?
    public let selfIPs: [String]
    public let peers: [TailscalePeer]

    public var iosPeers: [TailscalePeer] {
        peers.filter { $0.os.caseInsensitiveCompare("iOS") == .orderedSame }
    }
}

public struct TailscaleClient: Sendable {
    public static let candidatePaths: [String] = [
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
        "/opt/homebrew/bin/tailscale",
        "/usr/local/bin/tailscale",
        "/usr/bin/tailscale"
    ]

    public let executablePath: String?

    public init(executablePath: String? = nil) {
        self.executablePath = executablePath ?? Self.locateCLI()
    }

    public static func locateCLI() -> String? {
        for path in candidatePaths where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    public func status() throws -> TailscaleSnapshot {
        guard let exe = executablePath else {
            throw TailscaleError.cliNotFound
        }
        let result = try NetworkHelpers.runProcess(
            executable: exe,
            arguments: ["status", "--json"],
            timeout: 10
        )
        guard result.exitCode == 0 else {
            throw TailscaleError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        return try Self.parseStatusJSON(Data(result.stdout.utf8))
    }

    public static func parseStatusJSON(_ data: Data) throws -> TailscaleSnapshot {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TailscaleError.invalidJSON("Root object is not a dictionary")
        }
        let backendState = root["BackendState"] as? String ?? "Unknown"
        let selfNode = root["Self"] as? [String: Any]
        let selfDNS = selfNode?["DNSName"] as? String
        let selfIPs = selfNode?["TailscaleIPs"] as? [String] ?? []

        var peers: [TailscalePeer] = []
        if let peerMap = root["Peer"] as? [String: [String: Any]] {
            for (nodeKey, info) in peerMap {
                let dnsName = info["DNSName"] as? String ?? ""
                let hostName = info["HostName"] as? String ?? ""
                let os = info["OS"] as? String ?? ""
                let ips = info["TailscaleIPs"] as? [String] ?? []
                let online = info["Online"] as? Bool ?? false
                let active = info["Active"] as? Bool ?? false
                peers.append(TailscalePeer(
                    nodeKey: nodeKey,
                    dnsName: dnsName,
                    hostName: hostName,
                    os: os,
                    ips: ips,
                    online: online,
                    active: active
                ))
            }
        }
        peers.sort { $0.dnsName.localizedCaseInsensitiveCompare($1.dnsName) == .orderedAscending }
        return TailscaleSnapshot(
            backendState: backendState,
            selfDNSName: selfDNS,
            selfIPs: selfIPs,
            peers: peers
        )
    }

    /// Finds the best matching Tailscale peer for a saved device or user-supplied hint.
    public static func matchPeer(
        in snapshot: TailscaleSnapshot,
        nodeKey: String? = nil,
        dnsName: String? = nil,
        ip: String? = nil,
        hint: String? = nil
    ) -> TailscalePeer? {
        if let nodeKey, let exact = snapshot.peers.first(where: { $0.nodeKey == nodeKey }) {
            return exact
        }
        if let dnsName, !dnsName.isEmpty,
           let exact = snapshot.peers.first(where: { $0.dnsName.caseInsensitiveCompare(dnsName) == .orderedSame }) {
            return exact
        }
        if let ip, !ip.isEmpty,
           let exact = snapshot.peers.first(where: { $0.ips.contains(ip) }) {
            return exact
        }
        if let hint, !hint.isEmpty {
            let q = hint.lowercased()
            if let exact = snapshot.peers.first(where: {
                $0.ips.contains(hint) ||
                $0.dnsName.lowercased() == q ||
                $0.shortName.lowercased() == q ||
                $0.hostName.lowercased() == q
            }) {
                return exact
            }
            if let partial = snapshot.peers.first(where: {
                $0.dnsName.lowercased().contains(q) || $0.hostName.lowercased().contains(q)
            }) {
                return partial
            }
        }
        if snapshot.iosPeers.count == 1 {
            return snapshot.iosPeers.first
        }
        return nil
    }
}
