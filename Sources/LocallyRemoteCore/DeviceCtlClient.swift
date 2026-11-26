import Foundation

public enum DeviceCtlError: Error, LocalizedError {
    case commandFailed(String)
    case invalidJSON(String)

    public var errorDescription: String? {
        switch self {
        case .commandFailed(let msg):
            return "devicectl failed: \(msg)"
        case .invalidJSON(let msg):
            return "Failed to parse devicectl JSON: \(msg)"
        }
    }
}

public struct DeviceCtlClient: Sendable {
    public init() {}

    public func listDevices(timeout: TimeInterval = 15) throws -> [DeviceCtlDevice] {
        let tmpPath = "/tmp/locally-remote-devicectl-\(UUID().uuidString).json"
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }

        let result = try NetworkHelpers.runProcess(
            executable: "/usr/bin/xcrun",
            arguments: ["devicectl", "list", "devices", "--json-output", tmpPath],
            timeout: timeout
        )
        guard result.exitCode == 0 else {
            throw DeviceCtlError.commandFailed(result.stderr.isEmpty ? result.stdout : result.stderr)
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: tmpPath))
        return try Self.parseListDevicesJSON(data)
    }

    /// Asks CoreDevice to connect to a device and returns the command result.
    public func probeDevice(identifier: String, timeoutSeconds: Int = 15) throws -> (ok: Bool, locked: Bool, output: String) {
        let result = try NetworkHelpers.runProcess(
            executable: "/usr/bin/xcrun",
            arguments: ["devicectl", "device", "info", "details", "--device", identifier, "--timeout", "\(timeoutSeconds)"],
            timeout: TimeInterval(timeoutSeconds + 10)
        )
        let combined = [result.stdout, result.stderr].filter { !$0.isEmpty }.joined(separator: "\n")
        let locked = combined.localizedCaseInsensitiveContains("still locked") ||
                     combined.localizedCaseInsensitiveContains("not been unlocked")
        let ok = result.exitCode == 0 && !locked && !combined.contains("ERROR:")
        return (ok, locked, combined)
    }

    public static func parseListDevicesJSON(_ data: Data) throws -> [DeviceCtlDevice] {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let devicesRaw = result["devices"] as? [[String: Any]] else {
            throw DeviceCtlError.invalidJSON("Missing result.devices array")
        }

        var devices: [DeviceCtlDevice] = []
        for entry in devicesRaw {
            guard let identifier = entry["identifier"] as? String else { continue }
            let hw = entry["hardwareProperties"] as? [String: Any] ?? [:]
            let dp = entry["deviceProperties"] as? [String: Any] ?? [:]
            let cp = entry["connectionProperties"] as? [String: Any] ?? [:]

            guard let udid = hw["udid"] as? String else { continue }
            let name = dp["name"] as? String ?? "Unknown iOS Device"
            let model = hw["marketingName"] as? String ?? (hw["productType"] as? String ?? "iPhone")
            let productType = hw["productType"] as? String ?? ""
            let osVersion = dp["osVersionNumber"] as? String ?? ""
            let pairingState = cp["pairingState"] as? String ?? "unknown"
            let tunnelState = cp["tunnelState"] as? String ?? "unknown"
            let transportType = cp["transportType"] as? String
            let potentialHostnames = cp["potentialHostnames"] as? [String] ?? []
            let devMode = dp["developerModeStatus"] as? String

            devices.append(DeviceCtlDevice(
                coreDeviceIdentifier: identifier,
                udid: udid,
                name: name,
                model: model,
                productType: productType,
                osVersion: osVersion,
                pairingState: pairingState,
                tunnelState: tunnelState,
                transportType: transportType,
                potentialHostnames: potentialHostnames,
                developerModeStatus: devMode
            ))
        }
        return devices
    }

    /// Queries recent `remotepairingd` unified logs to find which UDID a Bonjour advertisement instance resolved to.
    public func lookupUDIDForBonjourInstance(_ instanceName: String) -> String? {
        let predicate = "process == \"remotepairingd\" AND eventMessage CONTAINS \"\(instanceName)\" AND eventMessage CONTAINS \"udid\""
        guard let result = try? NetworkHelpers.runProcess(
            executable: "/usr/bin/log",
            arguments: ["show", "--last", "2m", "--predicate", predicate, "--info"],
            timeout: 8
        ) else { return nil }

        // Matches `udid 00008110-000123456789001E` or `udid Optional("00008110-000123456789001E")`.
        let pattern = #"udid (?:Optional\(")?([0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}|[0-9A-Fa-f]{40})"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(result.stdout.startIndex..<result.stdout.endIndex, in: result.stdout)
        let matches = regex.matches(in: result.stdout, range: range)
        if let last = matches.last, let r = Range(last.range(at: 1), in: result.stdout) {
            return String(result.stdout[r])
        }
        return nil
    }
}
