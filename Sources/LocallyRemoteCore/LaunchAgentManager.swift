import Foundation

public struct LaunchAgentStatus: Codable, Sendable {
    public let label: String
    public let plistPath: String
    public let installed: Bool
    public let loaded: Bool
    public let pid: Int32?
}

public enum LaunchAgentManager {
    public static let label = "dev.hammerpot.locally-remote"

    public static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(label).plist")
    }

    public static func renderPlist(
        executablePath: String,
        bindMode: BindMode,
        forceBridge: Bool,
        logPath: String
    ) -> String {
        var args = [executablePath, "daemon", "--bind", bindMode.rawValue]
        if forceBridge {
            args.append("--force-bridge")
        }
        let argsXML = args.map { "        <string>\(xmlEscape($0))</string>" }.joined(separator: "\n")
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(label)</string>
            <key>ProgramArguments</key>
            <array>
        \(argsXML)
            </array>
            <key>RunAtLoad</key>
            <true/>
            <key>KeepAlive</key>
            <true/>
            <key>SoftResourceLimits</key>
            <dict>
                <key>NumberOfFiles</key>
                <integer>24576</integer>
            </dict>
            <key>StandardOutPath</key>
            <string>\(xmlEscape(logPath))</string>
            <key>StandardErrorPath</key>
            <string>\(xmlEscape(logPath))</string>
            <key>ProcessType</key>
            <string>Background</string>
        </dict>
        </plist>
        """
    }

    public static func install(
        executablePath: String,
        bindMode: BindMode,
        forceBridge: Bool,
        store: ConfigStore
    ) throws {
        try store.ensureDirectory()
        let agentsDir = plistURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: agentsDir, withIntermediateDirectories: true)

        let plist = renderPlist(
            executablePath: executablePath,
            bindMode: bindMode,
            forceBridge: forceBridge,
            logPath: store.logURL.path
        )
        try plist.write(to: plistURL, atomically: true, encoding: .utf8)

        let uid = getuid()
        // Unload any prior instance before bootstrapping the updated plist.
        _ = try? NetworkHelpers.runProcess(
            executable: "/bin/launchctl",
            arguments: ["bootout", "gui/\(uid)/\(label)"],
            timeout: 10
        )
        let boot = try NetworkHelpers.runProcess(
            executable: "/bin/launchctl",
            arguments: ["bootstrap", "gui/\(uid)", plistURL.path],
            timeout: 10
        )
        if boot.exitCode != 0 {
            throw NSError(
                domain: "LocallyRemote.LaunchAgent",
                code: Int(boot.exitCode),
                userInfo: [NSLocalizedDescriptionKey: "launchctl bootstrap failed: \(boot.stderr.isEmpty ? boot.stdout : boot.stderr)"]
            )
        }
    }

    public static func uninstall() throws {
        let uid = getuid()
        _ = try? NetworkHelpers.runProcess(
            executable: "/bin/launchctl",
            arguments: ["bootout", "gui/\(uid)/\(label)"],
            timeout: 10
        )
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
    }

    public static func status() -> LaunchAgentStatus {
        let installed = FileManager.default.fileExists(atPath: plistURL.path)
        let uid = getuid()
        let result = try? NetworkHelpers.runProcess(
            executable: "/bin/launchctl",
            arguments: ["print", "gui/\(uid)/\(label)"],
            timeout: 5
        )
        let loaded = (result?.exitCode == 0)
        var pid: Int32?
        if let out = result?.stdout {
            for line in out.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("pid = ") {
                    let num = trimmed.dropFirst("pid = ".count).trimmingCharacters(in: .whitespaces)
                    pid = Int32(num)
                    break
                }
            }
        }
        return LaunchAgentStatus(
            label: label,
            plistPath: plistURL.path,
            installed: installed,
            loaded: loaded,
            pid: pid
        )
    }

    private static func xmlEscape(_ str: String) -> String {
        str
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }
}
