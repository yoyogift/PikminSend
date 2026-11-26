import Darwin
import Foundation

@MainActor
final class DiscoveryManager: ObservableObject {
    @Published private(set) var peers: [LocalSendPeer] = []
    @Published private(set) var isScanning = false

    private let multicastAddress = "224.0.0.167"
    private let multicastPort: UInt16 = 53317

    private var socketFD: Int32 = -1
    private var readSource: DispatchSourceRead?
    private let socketQueue = DispatchQueue(label: "com.kokoa.PikminSend.multicast")
    private var localPort: Int = 53318

    func start(localPort: Int) {
        self.localPort = localPort
        startMulticastListener()
        Task {
            await refreshAll()
        }
    }

    func stop() {
        readSource?.cancel()
        readSource = nil
        if socketFD >= 0 {
            close(socketFD)
            socketFD = -1
        }
    }

    func updateLocalPort(_ port: Int) {
        localPort = port
    }

    func registerOrUpdatePeer(info: LocalSendInfo, ip: String, isTailscale: Bool? = nil) {
        let cleanIP = ip.components(separatedBy: "%").first ?? ip
        guard info.fingerprint != LocalIdentity.fingerprint else { return }
        guard !Self.localIPAddresses().contains(cleanIP) else { return }

        let tailscale = isTailscale ?? cleanIP.hasPrefix("100.")
        let peer = LocalSendPeer(
            alias: info.alias,
            deviceModel: info.deviceModel,
            deviceType: info.deviceType,
            fingerprint: info.fingerprint,
            ip: cleanIP,
            port: info.port,
            protocolScheme: info.protocolScheme,
            isTailscale: tailscale,
            lastSeen: Date()
        )
        upsertPeer(peer)
    }

    func refreshAll() async {
        isScanning = true
        sendMulticastAnnouncement()
        async let lanTask: Void = scanLANPeersFromARP()
        async let tsTask: Void = scanTailscalePeers()
        _ = await (lanTask, tsTask)
        pruneStalePeers()
        isScanning = false
    }

    private func upsertPeer(_ peer: LocalSendPeer) {
        if let idx = peers.firstIndex(where: { $0.id == peer.id }) {
            peers[idx] = peer
        } else {
            peers.append(peer)
        }
        peers.sort { lhs, rhs in
            if lhs.isTailscale != rhs.isTailscale {
                return !lhs.isTailscale
            }
            return lhs.alias.localizedCaseInsensitiveCompare(rhs.alias) == .orderedAscending
        }
    }

    private func pruneStalePeers() {
        let cutoff = Date().addingTimeInterval(-120)
        peers.removeAll { $0.lastSeen < cutoff }
    }

    // MARK: - 本機 IP 過濾（避免列到同台 Mac 上的官方 LocalSend）

    private static func localIPAddresses() -> Set<String> {
        var result: Set<String> = ["127.0.0.1", "::1"]
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else {
            return result
        }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let current = ptr {
            if let addr = current.pointee.ifa_addr {
                let family = Int32(addr.pointee.sa_family)
                if family == AF_INET || family == AF_INET6 {
                    var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                    let addrLen = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
                    if getnameinfo(addr, addrLen, &hostBuffer, socklen_t(hostBuffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                        let ipStr = String(cString: hostBuffer).components(separatedBy: "%").first ?? ""
                        if !ipStr.isEmpty {
                            result.insert(ipStr)
                        }
                    }
                }
            }
            ptr = current.pointee.ifa_next
        }
        return result
    }

    // MARK: - UDP Multicast (LAN)

    private func startMulticastListener() {
        let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return }

        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = multicastPort.bigEndian
        addr.sin_addr = in_addr(s_addr: INADDR_ANY.bigEndian)

        let bindResult = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            PikminLog.write("multicast bind(53317) failed: errno=\(errno)")
            close(fd)
            return
        }

        var mreq = ip_mreq()
        inet_pton(AF_INET, multicastAddress, &mreq.imr_multiaddr)
        mreq.imr_interface = in_addr(s_addr: INADDR_ANY.bigEndian)
        setsockopt(fd, IPPROTO_IP, IP_ADD_MEMBERSHIP, &mreq, socklen_t(MemoryLayout<ip_mreq>.size))

        let nonBlock = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, nonBlock | O_NONBLOCK)

        socketFD = fd

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: socketQueue)
        source.setEventHandler { [weak self] in
            self?.drainMulticastSocket()
        }
        source.resume()
        readSource = source
    }

    private func drainMulticastSocket() {
        guard socketFD >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: 4096)
        var senderAddr = sockaddr_in()
        var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)

        while true {
            let bytesRead = withUnsafeMutablePointer(to: &senderAddr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                    recvfrom(socketFD, &buffer, buffer.count, 0, ptr, &addrLen)
                }
            }
            if bytesRead <= 0 { break }

            let data = Data(buffer[0..<bytesRead])
            var ipBuffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var addrCopy = senderAddr.sin_addr
            inet_ntop(AF_INET, &addrCopy, &ipBuffer, socklen_t(INET_ADDRSTRLEN))
            let senderIP = String(cString: ipBuffer)

            guard let msg = try? JSONDecoder().decode(MulticastAnnouncement.self, from: data),
                  msg.fingerprint != LocalIdentity.fingerprint else {
                continue
            }

            let info = LocalSendInfo(
                alias: msg.alias,
                version: msg.version,
                deviceModel: msg.deviceModel,
                deviceType: msg.deviceType,
                fingerprint: msg.fingerprint,
                port: msg.port,
                protocolScheme: msg.protocolScheme,
                download: msg.download
            )

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.registerOrUpdatePeer(info: info, ip: senderIP, isTailscale: false)
                if msg.announce == true {
                    _ = await LocalSendClient.shared.register(
                        ip: senderIP,
                        port: msg.port,
                        scheme: msg.protocolScheme,
                        localPort: self.localPort
                    )
                }
            }
        }
    }

    func sendMulticastAnnouncement() {
        let info = LocalIdentity.info(port: localPort)
        let announcement = MulticastAnnouncement(
            alias: info.alias,
            version: info.version,
            deviceModel: info.deviceModel,
            deviceType: info.deviceType,
            fingerprint: info.fingerprint,
            port: info.port,
            protocolScheme: info.protocolScheme,
            download: false,
            announce: true
        )
        guard let data = try? JSONEncoder().encode(announcement) else { return }

        socketQueue.async { [multicastAddress, multicastPort] in
            let fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
            guard fd >= 0 else { return }
            defer { close(fd) }

            var dest = sockaddr_in()
            dest.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            dest.sin_family = sa_family_t(AF_INET)
            dest.sin_port = multicastPort.bigEndian
            inet_pton(AF_INET, multicastAddress, &dest.sin_addr)

            data.withUnsafeBytes { rawBuffer in
                guard let base = rawBuffer.baseAddress else { return }
                withUnsafePointer(to: &dest) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { ptr in
                        _ = sendto(fd, base, data.count, 0, ptr, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
    }

    // MARK: - 主動區網 ARP 掃描（避免官方版佔用 UDP 53317 時漏掉設備）

    private func scanLANPeersFromARP() async {
        let selfIPs = Self.localIPAddresses()
        let arpIPs = await Task.detached(priority: .utility) { () -> [String] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
            process.arguments = ["-an"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()

            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                let output = String(data: data, encoding: .utf8) ?? ""
                var ips: [String] = []
                for line in output.components(separatedBy: .newlines) {
                    guard let start = line.firstIndex(of: "("),
                          let end = line.firstIndex(of: ")"),
                          start < end else { continue }
                    let ip = String(line[line.index(after: start)..<end])
                    if ip.hasPrefix("169.254.") || ip.hasPrefix("224.") || ip.hasPrefix("239.") || ip.hasSuffix(".255") || ip.hasPrefix("100.") {
                        continue
                    }
                    if !selfIPs.contains(ip) {
                        ips.append(ip)
                    }
                }
                return Array(Set(ips))
            } catch {
                return []
            }
        }.value

        guard !arpIPs.isEmpty else { return }
        let myPort = localPort

        await withTaskGroup(of: LocalSendPeer?.self) { group in
            for ip in arpIPs {
                group.addTask {
                    await Self.probePeer(ip: ip, fallbackName: ip, isTailscale: false, myPort: myPort)
                }
            }
            for await peer in group {
                if let peer {
                    upsertPeer(peer)
                }
            }
        }
    }

    // MARK: - Tailscale Peer Discovery

    private func scanTailscalePeers() async {
        let candidates = await fetchOnlineTailscaleIPs()
        PikminLog.write("Tailscale online candidates: \(candidates.map { "\($0.hostName)(\($0.ip))" }.joined(separator: ", "))")
        guard !candidates.isEmpty else { return }

        let myPort = localPort
        await withTaskGroup(of: LocalSendPeer?.self) { group in
            for candidate in candidates {
                group.addTask {
                    await Self.probePeer(
                        ip: candidate.ip,
                        fallbackName: candidate.hostName,
                        isTailscale: true,
                        myPort: myPort
                    )
                }
            }

            for await peer in group {
                if let peer {
                    PikminLog.write("Tailscale peer found: \(peer.alias) @ \(peer.protocolScheme)://\(peer.ip):\(peer.port)")
                    upsertPeer(peer)
                }
            }
        }
    }

    private static func probePeer(ip: String, fallbackName: String, isTailscale: Bool, myPort: Int) async -> LocalSendPeer? {
        let targets: [(scheme: String, port: Int)] = [
            ("https", 53317),
            ("http", 53317),
            ("https", 53318),
            ("http", 53318)
        ]

        return await withTaskGroup(of: LocalSendPeer?.self) { group in
            for target in targets {
                group.addTask {
                    if let resp = await LocalSendClient.shared.register(
                        ip: ip,
                        port: target.port,
                        scheme: target.scheme,
                        localPort: myPort
                    ) {
                        if resp.fingerprint == LocalIdentity.fingerprint {
                            return nil
                        }
                        return LocalSendPeer(
                            alias: resp.alias.isEmpty ? fallbackName : resp.alias,
                            deviceModel: resp.deviceModel,
                            deviceType: resp.deviceType,
                            fingerprint: resp.fingerprint ?? ip,
                            ip: ip,
                            port: target.port,
                            protocolScheme: target.scheme,
                            isTailscale: isTailscale,
                            lastSeen: Date()
                        )
                    }
                    return nil
                }
            }

            for await result in group {
                if let peer = result {
                    group.cancelAll()
                    return peer
                }
            }
            return nil
        }
    }

    private func fetchOnlineTailscaleIPs() async -> [(hostName: String, ip: String)] {
        await Task.detached(priority: .utility) {
            let cliPaths = [
                "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
                "/opt/homebrew/bin/tailscale",
                "/usr/local/bin/tailscale",
                "/usr/bin/tailscale"
            ]

            guard let cliPath = cliPaths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
                PikminLog.write("Tailscale CLI not found")
                return []
            }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: cliPath)
            process.arguments = ["status", "--json"]
            let pipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = pipe
            process.standardError = errPipe

            do {
                try process.run()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                guard process.terminationStatus == 0 else {
                    let errStr = String(data: errData, encoding: .utf8) ?? ""
                    PikminLog.write("tailscale status failed (\(process.terminationStatus)): \(errStr)")
                    return []
                }

                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let peerMap = json["Peer"] as? [String: [String: Any]] else {
                    return []
                }

                var result: [(String, String)] = []
                for (_, info) in peerMap {
                    let online = info["Online"] as? Bool ?? false
                    guard online else { continue }
                    let hostName = (info["HostName"] as? String) ?? "Tailscale Node"
                    if let ips = info["TailscaleIPs"] as? [String],
                       let ipv4 = ips.first(where: { !$0.contains(":") }) {
                        result.append((hostName, ipv4))
                    }
                }
                return result
            } catch {
                PikminLog.write("tailscale status error: \(error.localizedDescription)")
                return []
            }
        }.value
    }
}
