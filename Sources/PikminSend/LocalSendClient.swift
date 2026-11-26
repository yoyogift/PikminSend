import CryptoKit
import Foundation

final class InsecureTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }
}

enum PikminLog {
    private static let logURL = URL(fileURLWithPath: "/tmp/pikminsend.log")
    private static let queue = DispatchQueue(label: "com.kokoa.PikminSend.log")

    static func write(_ message: String) {
        let ts = ISO8601DateFormatter().string(from: Date())
        let line = "[\(ts)] \(message)\n"
        queue.async {
            if let data = line.data(using: .utf8) {
                if FileManager.default.fileExists(atPath: logURL.path),
                   let handle = try? FileHandle(forWritingTo: logURL) {
                    defer { try? handle.close() }
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: data)
                } else {
                    try? data.write(to: logURL)
                }
            }
        }
    }
}

enum LocalSendTransferError: LocalizedError {
    case emptyPayload
    case folderNotSupported
    case unreachablePeer(String)
    case invalidResponse
    case rejectedByPeer(Int, String)
    case missingFileToken

    var errorDescription: String? {
        switch self {
        case .emptyPayload:
            return "籃子裡沒有內容"
        case .folderNotSupported:
            return "暫不支援直接傳送資料夾，請先壓縮為 zip"
        case .unreachablePeer(let alias):
            return "無法連線到 \(alias)，請確認對方已開啟 LocalSend 並在同一網路"
        case .invalidResponse:
            return "對方回應格式錯誤或網址無效"
        case .rejectedByPeer(let code, let detail):
            if detail.isEmpty {
                return "對方拒絕或無法接收 (HTTP \(code))"
            }
            return "對方拒絕或無法接收 (HTTP \(code)): \(detail)"
        case .missingFileToken:
            return "缺少上傳憑證 Token"
        }
    }
}

final class LocalSendClient: @unchecked Sendable {
    static let shared = LocalSendClient()

    private let session: URLSession
    private let probeSession: URLSession

    private init() {
        let delegate = InsecureTrustDelegate()

        let transferConfig = URLSessionConfiguration.default
        transferConfig.timeoutIntervalForRequest = 60
        transferConfig.timeoutIntervalForResource = 3600
        self.session = URLSession(configuration: transferConfig, delegate: delegate, delegateQueue: nil)

        let probeConfig = URLSessionConfiguration.ephemeral
        probeConfig.timeoutIntervalForRequest = 2.5
        probeConfig.timeoutIntervalForResource = 3.5
        self.probeSession = URLSession(configuration: probeConfig, delegate: delegate, delegateQueue: nil)
    }

    private func formattedHost(_ ip: String) -> String {
        ip.contains(":") && !ip.hasPrefix("[") ? "[\(ip)]" : ip
    }

    func register(ip: String, port: Int, scheme: String, localPort: Int) async -> RegisterResponse? {
        let host = formattedHost(ip)
        guard let url = URL(string: "\(scheme)://\(host):\(port)/api/localsend/v2/register") else {
            return nil
        }

        let info = LocalIdentity.info(port: localPort)
        let reqBody = RegisterRequest(
            alias: info.alias,
            version: info.version,
            deviceModel: info.deviceModel,
            deviceType: info.deviceType,
            fingerprint: info.fingerprint,
            port: info.port,
            protocolScheme: info.protocolScheme,
            download: false
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(reqBody)

        do {
            let (data, response) = try await probeSession.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return nil
            }
            return try JSONDecoder().decode(RegisterResponse.self, from: data)
        } catch {
            PikminLog.write("register failed (\(url.absoluteString)): \(error.localizedDescription)")
            return nil
        }
    }

    func send(payload: BasketPayload, to peer: LocalSendPeer, localPort: Int) async throws {
        let fileId = UUID().uuidString
        let fileData: Data
        let metadata: LocalSendFileMetadata

        switch payload {
        case .empty:
            throw LocalSendTransferError.emptyPayload

        case .file(let fileURL):
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDir), isDir.boolValue {
                throw LocalSendTransferError.folderNotSupported
            }
            let data = try Data(contentsOf: fileURL)
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            fileData = data
            metadata = LocalSendFileMetadata(
                id: fileId,
                fileName: fileURL.lastPathComponent,
                size: Int64(data.count),
                fileType: mimeType(for: fileURL),
                sha256: hash,
                preview: nil
            )

        case .text(let text, let isClipboard):
            let data = Data(text.utf8)
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            fileData = data
            metadata = LocalSendFileMetadata(
                id: fileId,
                fileName: isClipboard ? "clipboard.txt" : "message.txt",
                size: Int64(data.count),
                fileType: "text/plain",
                sha256: hash,
                preview: text
            )
        }

        // 先快速確認對方目前可連線，避免無回應時乾等過久
        let reachable = await register(ip: peer.ip, port: peer.port, scheme: peer.protocolScheme, localPort: localPort) != nil
        if !reachable {
            PikminLog.write("peer unreachable before prepare-upload: \(peer.protocolScheme)://\(peer.ip):\(peer.port)")
            throw LocalSendTransferError.unreachablePeer(peer.alias)
        }

        let baseURL = "\(peer.protocolScheme)://\(formattedHost(peer.ip)):\(peer.port)"
        guard let prepareURL = URL(string: "\(baseURL)/api/localsend/v2/prepare-upload") else {
            PikminLog.write("invalid prepareURL: \(baseURL)")
            throw LocalSendTransferError.invalidResponse
        }

        PikminLog.write("prepare-upload -> \(prepareURL.absoluteString) (alias=\(peer.alias), file=\(metadata.fileName))")

        let prepareReq = PrepareUploadRequest(
            info: LocalIdentity.info(port: localPort),
            files: [fileId: metadata]
        )

        var request = URLRequest(url: prepareURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONEncoder().encode(prepareReq)

        let (prepareData, prepareResponse): (Data, URLResponse)
        do {
            (prepareData, prepareResponse) = try await session.data(for: request)
        } catch {
            PikminLog.write("prepare-upload error: \(error)")
            throw error
        }

        guard let httpPrepare = prepareResponse as? HTTPURLResponse else {
            throw LocalSendTransferError.invalidResponse
        }

        PikminLog.write("prepare-upload response: HTTP \(httpPrepare.statusCode)")

        if httpPrepare.statusCode == 204 {
            // 對方已直接透過 preview 完成文字接收
            return
        }

        guard httpPrepare.statusCode == 200 else {
            let bodySnippet = String(data: prepareData, encoding: .utf8) ?? ""
            PikminLog.write("prepare-upload rejected (\(httpPrepare.statusCode)): \(bodySnippet)")
            throw LocalSendTransferError.rejectedByPeer(httpPrepare.statusCode, bodySnippet)
        }

        let prepared = try JSONDecoder().decode(PrepareUploadResponse.self, from: prepareData)
        guard let token = prepared.files[fileId] else {
            throw LocalSendTransferError.missingFileToken
        }

        var components = URLComponents(string: "\(baseURL)/api/localsend/v2/upload")
        components?.queryItems = [
            URLQueryItem(name: "sessionId", value: prepared.sessionId),
            URLQueryItem(name: "fileId", value: fileId),
            URLQueryItem(name: "token", value: token)
        ]

        guard let uploadURL = components?.url else {
            throw LocalSendTransferError.invalidResponse
        }

        var uploadRequest = URLRequest(url: uploadURL)
        uploadRequest.httpMethod = "POST"
        uploadRequest.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")

        let (uploadData, uploadResponse) = try await session.upload(for: uploadRequest, from: fileData)
        guard let httpUpload = uploadResponse as? HTTPURLResponse, (200..<300).contains(httpUpload.statusCode) else {
            let code = (uploadResponse as? HTTPURLResponse)?.statusCode ?? -1
            let bodySnippet = String(data: uploadData, encoding: .utf8) ?? ""
            PikminLog.write("upload rejected (\(code)): \(bodySnippet)")
            throw LocalSendTransferError.rejectedByPeer(code, bodySnippet)
        }
        PikminLog.write("upload completed -> \(peer.alias)")
    }

    private func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "pdf": return "application/pdf"
        case "txt", "md": return "text/plain"
        case "zip": return "application/zip"
        case "mp4", "mov": return "video/mp4"
        default: return "application/octet-stream"
        }
    }
}
