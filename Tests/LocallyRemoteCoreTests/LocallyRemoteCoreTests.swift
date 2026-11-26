import Foundation
import Darwin
import Testing
@testable import LocallyRemoteCore

@Suite("LocallyRemoteCore Tests")
struct LocallyRemoteCoreTests {

    @Test("Version string follows semantic versioning")
    func versionStringFormat() {
        let parts = LocallyRemoteVersion.current.split(separator: ".")
        #expect(parts.count == 3)
        #expect(parts.allSatisfy { Int($0) != nil })
    }

    @Test("TXT record encodes and decodes RFC 6763 wire format")
    func txtRecordRoundTrip() {
        let record = BonjourRecord(
            instanceName: "11111111-2222-3333-4444-555555555555",
            identifier: "11111111-2222-3333-4444-555555555555",
            authTag: "dGVzdFRh",
            version: "26",
            minVersion: "8",
            flags: "0",
            port: 49152
        )
        let encoded = record.encodeTXTRecord()
        let decoded = BonjourRecord.decodeTXTRecord(Data(encoded))

        #expect(decoded["identifier"] == "11111111-2222-3333-4444-555555555555")
        #expect(decoded["authTag"] == "dGVzdFRh")
        #expect(decoded["ver"] == "26")
        #expect(decoded["minVer"] == "8")
        #expect(decoded["flags"] == "0")
    }

    @Test("Tailscale status JSON parsing and peer matching")
    func tailscaleParsingAndMatching() throws {
        let sample = """
        {
          "BackendState": "Running",
          "Self": {
            "DNSName": "build-mac.example-tailnet.ts.net.",
            "TailscaleIPs": ["100.64.0.10"]
          },
          "Peer": {
            "nodekey:abc123": {
              "DNSName": "test-iphone.example-tailnet.ts.net.",
              "HostName": "localhost",
              "OS": "iOS",
              "TailscaleIPs": ["100.64.0.20", "fd7a:115c:a1e0::1"],
              "Online": true,
              "Active": true
            },
            "nodekey:def456": {
              "DNSName": "dev-linux.example-tailnet.ts.net.",
              "HostName": "dev-linux",
              "OS": "linux",
              "TailscaleIPs": ["100.64.0.30"],
              "Online": true,
              "Active": false
            }
          }
        }
        """
        let snapshot = try TailscaleClient.parseStatusJSON(Data(sample.utf8))
        #expect(snapshot.backendState == "Running")
        #expect(snapshot.iosPeers.count == 1)
        #expect(snapshot.iosPeers.first?.ipv4 == "100.64.0.20")
        #expect(snapshot.iosPeers.first?.shortName == "test-iphone")

        let matched = TailscaleClient.matchPeer(in: snapshot, hint: "test-iphone")
        #expect(matched?.nodeKey == "nodekey:abc123")

        let autoMatched = TailscaleClient.matchPeer(in: snapshot)
        #expect(autoMatched?.ipv4 == "100.64.0.20")
    }

    @Test("devicectl list devices JSON parsing")
    func deviceCtlParsing() throws {
        let sample = """
        {
          "result": {
            "devices": [
              {
                "identifier": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
                "connectionProperties": {
                  "pairingState": "paired",
                  "tunnelState": "disconnected",
                  "transportType": "localNetwork",
                  "potentialHostnames": ["Test-iPhone.coredevice.local"]
                },
                "deviceProperties": {
                  "name": "Test iPhone",
                  "osVersionNumber": "26.0",
                  "developerModeStatus": "enabled"
                },
                "hardwareProperties": {
                  "marketingName": "iPhone 16 Pro",
                  "productType": "iPhone17,1",
                  "udid": "00008110-000123456789001E"
                }
              }
            ]
          }
        }
        """
        let devices = try DeviceCtlClient.parseListDevicesJSON(Data(sample.utf8))
        #expect(devices.count == 1)
        #expect(devices[0].udid == "00008110-000123456789001E")
        #expect(devices[0].pairingState == "paired")
        #expect(devices[0].potentialHostnames == ["Test-iPhone.coredevice.local"])
    }

    @Test("devicectl device info details JSON parsing checks tunnelState")
    func deviceDetailsParsing() throws {
        let unavailableJSON = """
        {
          "result": {
            "connectionProperties": {
              "tunnelState": "unavailable"
            },
            "deviceProperties": {
              "ddiServicesAvailable": false
            }
          }
        }
        """
        let unavailable = try #require(DeviceCtlClient.parseDeviceDetailsJSON(Data(unavailableJSON.utf8)))
        #expect(unavailable.tunnelState == "unavailable")
        #expect(unavailable.ddiServicesAvailable == false)

        let connectedJSON = """
        {
          "result": {
            "connectionProperties": {
              "tunnelState": "connected"
            },
            "deviceProperties": {
              "ddiServicesAvailable": true
            }
          }
        }
        """
        let connected = try #require(DeviceCtlClient.parseDeviceDetailsJSON(Data(connectedJSON.utf8)))
        #expect(connected.tunnelState == "connected")
        #expect(connected.ddiServicesAvailable == true)
    }

    @Test("LAN address filter excludes loopback and Tailscale ranges")
    func lanAddressFilter() {
        #expect(NetworkHelpers.isTailscaleOrLoopbackAddress("127.0.0.1") == true)
        #expect(NetworkHelpers.isTailscaleOrLoopbackAddress("::1") == true)
        #expect(NetworkHelpers.isTailscaleOrLoopbackAddress("fe80::1") == true)
        #expect(NetworkHelpers.isTailscaleOrLoopbackAddress("100.64.0.20") == true)
        #expect(NetworkHelpers.isTailscaleOrLoopbackAddress("100.127.255.1") == true)
        #expect(NetworkHelpers.isTailscaleOrLoopbackAddress("fd7a:115c:a1e0::1") == true)

        #expect(NetworkHelpers.isTailscaleOrLoopbackAddress("192.168.1.50") == false)
        #expect(NetworkHelpers.isTailscaleOrLoopbackAddress("10.0.0.12") == false)
        #expect(NetworkHelpers.isTailscaleOrLoopbackAddress("fe80::c51:c6e6:1ca6:5e1c") == false)
    }

    @Test("ConfigStore saves, upserts, and removes devices atomically")
    func configStoreRoundTrip() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("locally-remote-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = ConfigStore(baseDirectory: tempDir)
        let dev = SavedDevice(
            udid: "00008110-000123456789001E",
            name: "Test iPhone",
            model: "iPhone 16 Pro",
            tailscaleDNSName: "test-iphone.example-tailnet.ts.net.",
            tailscaleIP: "100.64.0.20",
            bonjourRecord: BonjourRecord(
                instanceName: "11111111-2222-3333-4444-555555555555",
                identifier: "11111111-2222-3333-4444-555555555555",
                authTag: "dGVzdFRh"
            )
        )

        let savedConfig = try store.upsertDevice(dev)
        #expect(savedConfig.devices.count == 1)

        let reloaded = try store.loadConfig()
        #expect(reloaded.devices.first?.udid == dev.udid)
        #expect(reloaded.devices.first?.bonjourRecord.authTag == "dGVzdFRh")

        let (removed, afterRemove) = try store.removeDevice(matching: "00008110-000123456789001E")
        #expect(removed?.udid == dev.udid)
        #expect(afterRemove.devices.isEmpty)
    }

    @Test("LaunchAgent plist rendering contains SoftResourceLimits and flags")
    func launchAgentPlistRender() {
        let xml = LaunchAgentManager.renderPlist(
            executablePath: "/Users/dev/.local/bin/locally-remote",
            bindMode: .lo0,
            forceBridge: false,
            logPath: "/Users/dev/.config/locally-remote/daemon.log"
        )
        #expect(xml.contains("<string>\(LaunchAgentManager.label)</string>"))
        #expect(xml.contains("<key>NumberOfFiles</key>"))
        #expect(xml.contains("<integer>24576</integer>"))
        #expect(!xml.contains("--force-bridge"))
    }

    @Test("Shell completions generate valid zsh, bash, and fish scripts")
    func shellCompletionsGenerate() {
        let zsh = ShellCompletions.generate(for: .zsh)
        #expect(zsh.hasPrefix("#compdef locally-remote"))
        #expect(zsh.contains("install-agent"))
        #expect(zsh.contains("completions"))
        #expect(zsh.contains("lo0 lan loopback4"))

        let bash = ShellCompletions.generate(for: .bash)
        #expect(bash.contains("complete -F _locally_remote locally-remote"))
        #expect(bash.contains("--force-bridge"))

        let fish = ShellCompletions.generate(for: .fish)
        #expect(fish.contains("complete -c locally-remote"))
        #expect(fish.contains("uninstall-agent"))
    }

    @Test("Shell completions install writes script to target directory")
    func shellCompletionsInstall() throws {
        let tempHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("locally-remote-comp-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempHome) }

        let zshResult = try ShellCompletions.install(
            shell: .zsh,
            homeDirectory: tempHome,
            systemSearchPaths: []
        )
        #expect(zshResult.shell == .zsh)
        #expect(zshResult.usesDefaultFpath == false)
        #expect(FileManager.default.fileExists(atPath: zshResult.path))
        let zshText = try String(contentsOfFile: zshResult.path, encoding: .utf8)
        #expect(zshText.contains("#compdef locally-remote"))

        let fishResult = try ShellCompletions.install(
            shell: .fish,
            homeDirectory: tempHome,
            systemSearchPaths: []
        )
        #expect(fishResult.shell == .fish)
        #expect(FileManager.default.fileExists(atPath: fishResult.path))
    }

    @Test("PortRelayServer forwards bidirectional TCP bytes on fe80::1%lo0 to upstream")
    func liveTCPRelayLoopbackTest() throws {
        let echoPort: UInt16 = 59876
        let serverFD = socket(AF_INET, SOCK_STREAM, 0)
        #expect(serverFD >= 0)
        defer { close(serverFD) }

        var yes: Int32 = 1
        setsockopt(serverFD, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        var saddr = sockaddr_in()
        saddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        saddr.sin_family = sa_family_t(AF_INET)
        saddr.sin_port = echoPort.bigEndian
        inet_pton(AF_INET, "127.0.0.1", &saddr.sin_addr)
        let bindRC = withUnsafePointer(to: &saddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(serverFD, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        #expect(bindRC == 0)
        #expect(listen(serverFD, 4) == 0)

        let echoDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let cfd = accept(serverFD, nil, nil)
            if cfd >= 0 {
                var buf = [UInt8](repeating: 0, count: 256)
                let n = read(cfd, &buf, buf.count)
                if n > 0 {
                    _ = write(cfd, &buf, n)
                }
                close(cfd)
            }
            echoDone.signal()
        }

        let endpoint = try #require(NetworkHelpers.resolveBindEndpoint(mode: .lo0))
        let relay = PortRelayServer(
            bindEndpoint: endpoint,
            remoteHost: "127.0.0.1",
            controlPort: echoPort,
            portRange: (echoPort - 2)...(echoPort + 2)
        )
        try relay.start()
        defer { relay.stop() }

        #expect(relay.stats().boundPortCount == 5)

        let clientFD = socket(AF_INET6, SOCK_STREAM, 0)
        #expect(clientFD >= 0)
        defer { close(clientFD) }

        var caddr = sockaddr_in6()
        caddr.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        caddr.sin6_family = sa_family_t(AF_INET6)
        caddr.sin6_port = echoPort.bigEndian
        caddr.sin6_scope_id = endpoint.interfaceIndex
        inet_pton(AF_INET6, endpoint.address, &caddr.sin6_addr)
        let connRC = withUnsafePointer(to: &caddr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(clientFD, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        #expect(connRC == 0)

        let payload = Array("hello-coredevice-tunnel".utf8)
        let written = payload.withUnsafeBytes { write(clientFD, $0.baseAddress!, payload.count) }
        #expect(written == payload.count)

        var reply = [UInt8](repeating: 0, count: 64)
        let readCount = read(clientFD, &reply, reply.count)
        #expect(readCount == payload.count)
        #expect(String(bytes: reply.prefix(readCount), encoding: .utf8) == "hello-coredevice-tunnel")

        _ = echoDone.wait(timeout: .now() + 2)
        Thread.sleep(forTimeInterval: 0.1)
        #expect(relay.stats().totalConnectionsHandled == 1)
        #expect(relay.stats().totalBytesRelayed >= UInt64(payload.count * 2))
    }
}
