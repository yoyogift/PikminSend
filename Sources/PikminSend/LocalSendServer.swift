import CryptoKit
import Foundation
import Network

struct IncomingTransferOffer {
    let sessionId: String
    let senderName: String
    let itemSummary: String
    let isTextOnly: Bool
    let textPreview: String?
}

final class LocalSendServer: @unchecked Sendable {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.kokoa.PikminSend.server")

    private(set) var boundPort: Int = 53318

    var onPeerSeen: ((LocalSendInfo, String) -> Void)?
    var onIncomingOffer: ((IncomingTransferOffer, @escaping @Sendable (Bool) -> Void) -> Void)?
    var onIncomingCancelled: ((String) -> Void)?
    var onTransferCompleted: ((String, URL?, String?) -> Void)?

    private struct ActiveSession {
        let sessionId: String
        let senderName: String
        var files: [String: LocalSendFileMetadata]
        var tokens: [String: String]
    }

    private var activeSessions: [String: ActiveSession] = [:]
    private var pendingDecisions: [String: (Bool) -> Void] = [:]

    func start() {
        // 避開官方 LocalSend 預設的 53317 埠，讓兩者可同時在同台 Mac 共存
        startListener(on: 53318, allowFallback: true)
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func startListener(on portValue: UInt16, allowFallback: Bool) {
        guard let nwPort = NWEndpoint.Port(rawValue: portValue) else { return }

        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            let newListener = try NWListener(using: params, on: nwPort)

            newListener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.boundPort = Int(portValue)
                case .failed:
                    if allowFallback && portValue == 53318 {
                        newListener.cancel()
                        self.startListener(on: 53319, allowFallback: false)
                    }
                default:
                    break
                }
            }

            newListener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }

            newListener.start(queue: queue)
            listener = newListener
        } catch {
            if allowFallback && portValue == 53318 {
                startListener(on: 53319, allowFallback: false)
            }
        }
    }

    private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveHTTPRequest(on: connection, buffer: Data())
    }

    private func receiveHTTPRequest(on connection: NWConnection, buffer: Data, sentContinue: Bool = false) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            var nextBuffer = buffer
            if let chunk {
                nextBuffer.append(chunk)
            }

            if let headerRange = nextBuffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = nextBuffer.subdata(in: 0..<headerRange.lowerBound)
                let bodyStart = headerRange.upperBound
                let headerText = String(data: headerData, encoding: .utf8) ?? ""
                var didSendContinue = sentContinue

                if !didSendContinue && self.hasExpect100Continue(headerText) {
                    didSendContinue = true
                    connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8), completion: .contentProcessed { _ in })
                }

                if self.isChunkedTransfer(headerText) {
                    let rawBody = nextBuffer.subdata(in: bodyStart..<nextBuffer.count)
                    if let decodedBody = self.decodeChunkedBody(rawBody) {
                        self.dispatchHTTPRequest(headerText: headerText, body: decodedBody, connection: connection)
                        return
                    }
                } else {
                    let contentLength = self.parseContentLength(from: headerText)
                    if nextBuffer.count - bodyStart >= contentLength {
                        let bodyData = nextBuffer.subdata(in: bodyStart..<(bodyStart + contentLength))
                        self.dispatchHTTPRequest(headerText: headerText, body: bodyData, connection: connection)
                        return
                    }
                }

                if isComplete || error != nil {
                    connection.cancel()
                    return
                }

                self.receiveHTTPRequest(on: connection, buffer: nextBuffer, sentContinue: didSendContinue)
                return
            }

            if isComplete || error != nil {
                connection.cancel()
                return
            }

            self.receiveHTTPRequest(on: connection, buffer: nextBuffer, sentContinue: sentContinue)
        }
    }

    private func hasExpect100Continue(_ headerText: String) -> Bool {
        for line in headerText.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 && parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "expect" {
                return parts[1].lowercased().contains("100-continue")
            }
        }
        return false
    }

    private func isChunkedTransfer(_ headerText: String) -> Bool {
        for line in headerText.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 && parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "transfer-encoding" {
                return parts[1].lowercased().contains("chunked")
            }
        }
        return false
    }

    private func decodeChunkedBody(_ data: Data) -> Data? {
        var result = Data()
        var index = data.startIndex
        let crlf = Data("\r\n".utf8)

        while true {
            guard let lineEnd = data.range(of: crlf, in: index..<data.endIndex) else {
                return nil
            }
            let sizeLine = String(data: data.subdata(in: index..<lineEnd.lowerBound), encoding: .utf8) ?? ""
            let hexPart = sizeLine.split(separator: ";", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces) ?? ""
            guard let chunkSize = Int(hexPart, radix: 16) else {
                return nil
            }

            index = lineEnd.upperBound
            if chunkSize == 0 {
                if data.distance(from: index, to: data.endIndex) >= 2 {
                    return result
                }
                return nil
            }

            guard data.distance(from: index, to: data.endIndex) >= chunkSize + 2 else {
                return nil
            }
            result.append(data.subdata(in: index..<(index + chunkSize)))
            index += chunkSize + 2
        }
    }

    private func parseContentLength(from headerText: String) -> Int {
        for line in headerText.split(separator: "\r\n") {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2 && parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                return Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
            }
        }
        return 0
    }

    private func dispatchHTTPRequest(headerText: String, body: Data, connection: NWConnection) {
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendResponse(connection: connection, status: "400 Bad Request", body: Data())
            return
        }

        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            sendResponse(connection: connection, status: "400 Bad Request", body: Data())
            return
        }

        let method = String(parts[0])
        let fullTarget = String(parts[1])
        let components = URLComponents(string: "http://localhost\(fullTarget)")
        let path = components?.path ?? fullTarget

        let remoteIP = extractRemoteIP(from: connection)

        switch (method, path) {
        case ("GET", "/api/localsend/v2/info"):
            let info = LocalIdentity.info(port: boundPort)
            let data = (try? JSONEncoder().encode(info)) ?? Data()
            sendJSON(connection: connection, status: "200 OK", data: data)

        case ("POST", "/api/localsend/v2/register"):
            if let req = try? JSONDecoder().decode(RegisterRequest.self, from: body),
               req.fingerprint != LocalIdentity.fingerprint,
               let remoteIP {
                let peerInfo = LocalSendInfo(
                    alias: req.alias,
                    version: req.version,
                    deviceModel: req.deviceModel,
                    deviceType: req.deviceType,
                    fingerprint: req.fingerprint,
                    port: req.port,
                    protocolScheme: req.protocolScheme,
                    download: req.download
                )
                onPeerSeen?(peerInfo, remoteIP)
            }
            let myInfo = LocalIdentity.info(port: boundPort)
            let resp = RegisterResponse(
                alias: myInfo.alias,
                version: myInfo.version,
                deviceModel: myInfo.deviceModel,
                deviceType: myInfo.deviceType,
                fingerprint: myInfo.fingerprint,
                download: false
            )
            let data = (try? JSONEncoder().encode(resp)) ?? Data()
            sendJSON(connection: connection, status: "200 OK", data: data)

        case ("POST", "/api/localsend/v2/prepare-upload"):
            handlePrepareUpload(body: body, connection: connection)

        case ("POST", "/api/localsend/v2/upload"):
            let query = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).compactMap { item in
                item.value.map { (item.name, $0) }
            })
            handleUpload(query: query, body: body, connection: connection)

        case ("POST", "/api/localsend/v2/cancel"):
            let sessionId = components?.queryItems?.first(where: { $0.name == "sessionId" })?.value
            if let sessionId {
                activeSessions.removeValue(forKey: sessionId)
                if let decision = pendingDecisions.removeValue(forKey: sessionId) {
                    decision(false)
                }
                onIncomingCancelled?(sessionId)
            }
            sendResponse(connection: connection, status: "200 OK", body: Data())

        default:
            sendResponse(connection: connection, status: "404 Not Found", body: Data())
        }
    }

    private func handlePrepareUpload(body: Data, connection: NWConnection) {
        guard let req = try? JSONDecoder().decode(PrepareUploadRequest.self, from: body),
              !req.files.isEmpty else {
            sendResponse(connection: connection, status: "400 Bad Request", body: Data())
            return
        }

        let sessionId = UUID().uuidString
        let fileList = Array(req.files.values)
        let isTextOnly = fileList.count == 1 && fileList[0].fileType.hasPrefix("text/") && fileList[0].preview != nil

        let summary: String
        if isTextOnly, let preview = fileList[0].preview {
            let clipped = preview.replacingOccurrences(of: "\n", with: " ")
            summary = clipped.count > 26 ? String(clipped.prefix(26)) + "…" : clipped
        } else if fileList.count == 1 {
            let sizeStr = ByteCountFormatter.string(fromByteCount: fileList[0].size, countStyle: .file)
            summary = "\(fileList[0].fileName) · \(sizeStr)"
        } else {
            let total = fileList.reduce(Int64(0)) { $0 + $1.size }
            let sizeStr = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
            summary = "\(fileList.count) 個檔案 · \(sizeStr)"
        }

        let offer = IncomingTransferOffer(
            sessionId: sessionId,
            senderName: req.info.alias,
            itemSummary: summary,
            isTextOnly: isTextOnly,
            textPreview: fileList.first?.preview
        )

        guard let onIncomingOffer else {
            sendResponse(connection: connection, status: "403 Forbidden", body: Data())
            return
        }

        pendingDecisions[sessionId] = { [weak self] accepted in
            guard let self else { return }
            self.queue.async {
                self.pendingDecisions.removeValue(forKey: sessionId)
                guard accepted else {
                    self.sendResponse(connection: connection, status: "403 Forbidden", body: Data())
                    return
                }

                var tokens: [String: String] = [:]
                for fileId in req.files.keys {
                    tokens[fileId] = UUID().uuidString
                }

                self.activeSessions[sessionId] = ActiveSession(
                    sessionId: sessionId,
                    senderName: req.info.alias,
                    files: req.files,
                    tokens: tokens
                )

                let resp = PrepareUploadResponse(sessionId: sessionId, files: tokens)
                let data = (try? JSONEncoder().encode(resp)) ?? Data()
                self.sendJSON(connection: connection, status: "200 OK", data: data)
            }
        }

        onIncomingOffer(offer) { [weak self] accepted in
            self?.queue.async {
                self?.pendingDecisions[sessionId]?(accepted)
            }
        }
    }

    private func handleUpload(query: [String: String], body: Data, connection: NWConnection) {
        guard let sessionId = query["sessionId"],
              let fileId = query["fileId"],
              let token = query["token"],
              var session = activeSessions[sessionId],
              session.tokens[fileId] == token,
              let meta = session.files[fileId] else {
            sendResponse(connection: connection, status: "403 Forbidden", body: Data())
            return
        }

        if let expectedHash = meta.sha256, !expectedHash.isEmpty {
            let actualHash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
            if actualHash.lowercased() != expectedHash.lowercased() {
                PikminLog.write("422 hash mismatch: expected=\(expectedHash) actual=\(actualHash) bodyBytes=\(body.count)")
                sendResponse(connection: connection, status: "422 Unprocessable Entity", body: Data())
                return
            }
        }

        var savedURL: URL?
        var receivedText: String?

        if (meta.fileType.lowercased().hasPrefix("text/") || meta.preview != nil),
           let text = String(data: body, encoding: .utf8) ?? meta.preview {
            receivedText = text
        } else {
            savedURL = saveToDownloads(fileName: meta.fileName, data: body)
        }

        session.files.removeValue(forKey: fileId)
        if session.files.isEmpty {
            activeSessions.removeValue(forKey: sessionId)
        } else {
            activeSessions[sessionId] = session
        }

        sendResponse(connection: connection, status: "200 OK", body: Data())
        onTransferCompleted?(session.senderName, savedURL, receivedText)
    }

    private func saveToDownloads(fileName: String, data: Data) -> URL? {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads")
        let safeName = URL(fileURLWithPath: fileName).lastPathComponent
        var target = downloads.appendingPathComponent(safeName)

        let stem = target.deletingPathExtension().lastPathComponent
        let ext = target.pathExtension
        var index = 1
        while FileManager.default.fileExists(atPath: target.path) {
            let nextName = ext.isEmpty ? "\(stem) (\(index))" : "\(stem) (\(index)).\(ext)"
            target = downloads.appendingPathComponent(nextName)
            index += 1
        }

        do {
            try data.write(to: target)
            return target
        } catch {
            return nil
        }
    }

    private func extractRemoteIP(from connection: NWConnection) -> String? {
        if case let .hostPort(host, _) = connection.endpoint {
            switch host {
            case .ipv4(let addr):
                return addr.debugDescription.components(separatedBy: "%").first
            case .ipv6(let addr):
                return addr.debugDescription.components(separatedBy: "%").first
            default:
                return host.debugDescription
            }
        }
        return nil
    }

    private func sendJSON(connection: NWConnection, status: String, data: Data) {
        sendResponse(connection: connection, status: status, contentType: "application/json", body: data)
    }

    private func sendResponse(
        connection: NWConnection,
        status: String,
        contentType: String = "text/plain",
        body: Data
    ) {
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        var responseData = Data(header.utf8)
        responseData.append(body)
        connection.send(content: responseData, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
