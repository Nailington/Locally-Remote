import Foundation

/// Persists `AppConfig` and `DaemonRuntimeState` under `~/.config/locally-remote/`.
public struct ConfigStore: Sendable {
    public let baseDirectory: URL

    public var configURL: URL {
        baseDirectory.appendingPathComponent("config.json")
    }

    public var stateURL: URL {
        baseDirectory.appendingPathComponent("state.json")
    }

    public var logURL: URL {
        baseDirectory.appendingPathComponent("daemon.log")
    }

    public init(baseDirectory: URL? = nil) {
        if let baseDirectory {
            self.baseDirectory = baseDirectory
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser
            self.baseDirectory = home
                .appendingPathComponent(".config", isDirectory: true)
                .appendingPathComponent("locally-remote", isDirectory: true)
        }
    }

    public func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: baseDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    public func loadConfig() throws -> AppConfig {
        guard FileManager.default.fileExists(atPath: configURL.path) else {
            return AppConfig()
        }
        let data = try Data(contentsOf: configURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(AppConfig.self, from: data)
    }

    public func saveConfig(_ config: AppConfig) throws {
        try ensureDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(config)
        let tmp = baseDirectory.appendingPathComponent("config.json.tmp.\(ProcessInfo.processInfo.processIdentifier)")
        try data.write(to: tmp, options: [.atomic])
        _ = try FileManager.default.replaceItemAt(configURL, withItemAt: tmp)
    }

    public func upsertDevice(_ device: SavedDevice) throws -> AppConfig {
        var config = try loadConfig()
        if let idx = config.devices.firstIndex(where: { $0.udid.caseInsensitiveCompare(device.udid) == .orderedSame }) {
            config.devices[idx] = device
        } else {
            config.devices.append(device)
        }
        try saveConfig(config)
        return config
    }

    public func removeDevice(matching query: String) throws -> (removed: SavedDevice?, config: AppConfig) {
        var config = try loadConfig()
        let q = query.lowercased()
        guard let idx = config.devices.firstIndex(where: {
            $0.udid.lowercased() == q ||
            $0.name.lowercased() == q ||
            ($0.coreDeviceIdentifier?.lowercased() == q) ||
            ($0.tailscaleDNSName?.lowercased().contains(q) == true)
        }) else {
            return (nil, config)
        }
        let removed = config.devices.remove(at: idx)
        try saveConfig(config)
        return (removed, config)
    }

    public func saveRuntimeState(_ state: DaemonRuntimeState) throws {
        try ensureDirectory()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)
        try data.write(to: stateURL, options: [.atomic])
    }

    public func loadRuntimeState() -> DaemonRuntimeState? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(DaemonRuntimeState.self, from: data)
    }

    public func clearRuntimeState() {
        try? FileManager.default.removeItem(at: stateURL)
    }
}
