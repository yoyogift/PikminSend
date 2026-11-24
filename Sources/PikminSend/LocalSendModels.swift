import Foundation

struct LocalSendInfo: Codable, Equatable {
    let alias: String
    let version: String
    let deviceModel: String?
    let deviceType: String?
    let fingerprint: String
    let port: Int
    let protocolScheme: String
    let download: Bool?

    enum CodingKeys: String, CodingKey {
        case alias
        case version
        case deviceModel
        case deviceType
        case fingerprint
        case port
        case protocolScheme = "protocol"
        case download
    }
}

struct MulticastAnnouncement: Codable {
    let alias: String
    let version: String
    let deviceModel: String?
    let deviceType: String?
    let fingerprint: String
    let port: Int
    let protocolScheme: String
    let download: Bool?
    let announce: Bool?

    enum CodingKeys: String, CodingKey {
        case alias
        case version
        case deviceModel
        case deviceType
        case fingerprint
        case port
        case protocolScheme = "protocol"
        case download
        case announce
    }
}

struct RegisterRequest: Codable {
    let alias: String
    let version: String
    let deviceModel: String?
    let deviceType: String?
    let fingerprint: String
    let port: Int
    let protocolScheme: String
    let download: Bool?

    enum CodingKeys: String, CodingKey {
        case alias
        case version
        case deviceModel
        case deviceType
        case fingerprint
        case port
        case protocolScheme = "protocol"
        case download
    }
}

struct RegisterResponse: Codable {
    let alias: String
    let version: String?
    let deviceModel: String?
    let deviceType: String?
    let fingerprint: String?
    let download: Bool?
}

struct LocalSendFileMetadata: Codable, Equatable {
    let id: String
    let fileName: String
    let size: Int64
    let fileType: String
    let sha256: String?
    let preview: String?
}

struct PrepareUploadRequest: Codable {
    let info: LocalSendInfo
    let files: [String: LocalSendFileMetadata]
}

struct PrepareUploadResponse: Codable {
    let sessionId: String
    let files: [String: String]
}

struct LocalSendPeer: Identifiable, Equatable {
    var id: String { "\(ip):\(port)" }
    let alias: String
    let deviceModel: String?
    let deviceType: String?
    let fingerprint: String
    let ip: String
    let port: Int
    let protocolScheme: String
    let isTailscale: Bool
    var lastSeen: Date
}

enum LocalIdentity {
    static let fingerprint: String = {
        let key = "PikminSend.Fingerprint"
        if let existing = UserDefaults.standard.string(forKey: key), !existing.isEmpty {
            return existing
        }
        let generated = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        UserDefaults.standard.set(generated, forKey: key)
        return generated
    }()

    static var alias: String {
        Host.current().localizedName ?? "Pikmin Mac"
    }

    static func info(port: Int) -> LocalSendInfo {
        LocalSendInfo(
            alias: alias,
            version: "2.0",
            deviceModel: "macOS",
            deviceType: "desktop",
            fingerprint: fingerprint,
            port: port,
            protocolScheme: "http",
            download: false
        )
    }
}
