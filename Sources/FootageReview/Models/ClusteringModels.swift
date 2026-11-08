import Foundation

indirect enum ClusterJSON: Codable, Sendable, Equatable {
    case object([String: ClusterJSON]), array([ClusterJSON]), string(String), number(Double), bool(Bool), null

    init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let item = try? value.decode(Bool.self) { self = .bool(item) }
        else if let item = try? value.decode(String.self) { self = .string(item) }
        else if let item = try? value.decode(Double.self) { self = .number(item) }
        else if let item = try? value.decode([ClusterJSON].self) { self = .array(item) }
        else { self = .object(try value.decode([String: ClusterJSON].self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .object(let item): try value.encode(item)
        case .array(let item): try value.encode(item)
        case .string(let item): try value.encode(item)
        case .number(let item): try value.encode(item)
        case .bool(let item): try value.encode(item)
        case .null: try value.encodeNil()
        }
    }

    var prettyPrinted: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self), let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }
}

struct ClusterGroup: Codable, Sendable, Identifiable {
    let id: String
    var name: String
    var note: String
    var appearanceIDs: [String]
    var origin: String
    var reviewed: Bool
    var dirty: Bool
    var similarity: Double?
    enum CodingKeys: String, CodingKey {
        case id, name, note, origin, reviewed, dirty, similarity
        case appearanceIDs = "appearance_ids"
    }
}

struct ClusterJob: Codable, Sendable, Identifiable {
    let id: String
    let workspaceID: String
    let kind: String
    let status: String
    let phase: String
    let completed: Int
    let total: Int
    let error: String?
    var isActive: Bool { ["queued", "running", "paused"].contains(status) }
    enum CodingKeys: String, CodingKey {
        case id, kind, status, phase, completed, total, error
        case workspaceID = "workspace_id"
    }
}

struct ClusterSavedImport: Codable, Sendable, Identifiable {
    let id: String
    let status: String
    let payload: ClusterJSON
    let response: ClusterJSON?
    let error: String?
    let createdAt: String
    var prettyPayload: String { payload.prettyPrinted }
    enum CodingKeys: String, CodingKey {
        case id, status, payload, response, error
        case createdAt = "created_at"
    }
}

struct ClusterWorkspace: Codable, Sendable, Identifiable {
    let id: String
    let name: String
    let libraryID: String
    let baseRevision: Int
    let appearanceCount: Int
    let exportComplete: Bool
    let groups: [ClusterGroup]
    let jobs: [ClusterJob]
    let imports: [ClusterSavedImport]
    enum CodingKeys: String, CodingKey {
        case id, name, groups, jobs, imports
        case libraryID = "library_id", baseRevision = "base_revision"
        case appearanceCount = "appearance_count", exportComplete = "export_complete"
    }
}

struct ClusterBackendStatus: Decodable, Sendable {
    let connected: Bool
    let sessionActive: Bool
    let libraryID: String?
    let modelsReady: Bool
    let modelMessage: String
    enum CodingKeys: String, CodingKey {
        case connected
        case sessionActive = "session_active", libraryID = "library_id"
        case modelsReady = "models_ready", modelMessage = "model_message"
    }
}

struct ClusterExportCreated: Decodable, Sendable {
    let workspaceID: String
    let jobID: String
    enum CodingKeys: String, CodingKey { case workspaceID = "workspace_id", jobID = "job_id" }
}
struct ClusterJobCreated: Decodable, Sendable {
    let jobID: String
    enum CodingKeys: String, CodingKey { case jobID = "job_id" }
}
struct ClusterOK: Decodable, Sendable { let ok: Bool }

struct ClusteringFailure: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}
