import Foundation

struct APIRequest: Sendable {
    let method: String
    let target: String
    let headers: [String: String]
    let body: Data
}

struct APIResponse: Sendable {
    let status: Int
    var headers: [String: String]
    let body: Data

    static func json<T: Encodable>(status: Int = 200, value: T) -> Self {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            return Self(status: status,
                        headers: ["Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store"],
                        body: try encoder.encode(value))
        } catch {
            return Self(status: 500,
                        headers: ["Content-Type": "application/json", "Cache-Control": "no-store"],
                        body: Data(#"{"code":"encoding_failed","message":"The response could not be encoded."}"#.utf8))
        }
    }
}

struct APIProblem: Error, Sendable {
    let status: Int
    let code: String
    let message: String
}

struct APIExportItem: Sendable {
    let appearance: Appearance
    let clip: ReviewClip
    let cropURL: URL
    let groupIDs: [String]
}

struct APILibrarySnapshot: Sendable {
    let libraryID: String
    let revision: Int
    let groups: [ReviewGroup]
    let items: [APIExportItem]
}

struct ReviewedGroupAssignment: Codable, Sendable {
    let id: String
    let name: String
    let note: String
    let appearanceIDs: [String]

    enum CodingKeys: String, CodingKey {
        case id, name, note
        case appearanceIDs = "appearance_ids"
    }

    init(id: String, name: String, note: String = "", appearanceIDs: [String]) {
        self.id = id
        self.name = name
        self.note = note
        self.appearanceIDs = appearanceIDs
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        note = try values.decodeIfPresent(String.self, forKey: .note) ?? ""
        appearanceIDs = try values.decode([String].self, forKey: .appearanceIDs)
    }
}

struct ReviewedGroupImport: Codable, Sendable {
    let importID: String
    let libraryID: String
    let baseRevision: Int
    let reviewer: String?
    let groups: [ReviewedGroupAssignment]

    enum CodingKeys: String, CodingKey {
        case reviewer, groups
        case importID = "import_id"
        case libraryID = "library_id"
        case baseRevision = "base_revision"
    }
}

struct APIImportResult: Codable, Sendable {
    let importID: String
    let revision: Int
    let currentRevision: Int
    let groupIDs: [String]
    let appearanceCount: Int
    let replayed: Bool

    enum CodingKeys: String, CodingKey {
        case revision, replayed
        case importID = "import_id"
        case currentRevision = "current_revision"
        case groupIDs = "group_ids"
        case appearanceCount = "appearance_count"
    }
}

struct ReviewAPIState: Codable, Sendable {
    var libraryID = UUID().uuidString
    var revision = 0
    var imports: [String: ReviewedImportReceipt] = [:]
    var lastImportID: String?
}

struct ReviewedImportReceipt: Codable, Sendable {
    let digest: String
    let revision: Int
    let groupIDs: [String]
    let appearanceCount: Int
    let reviewer: String?
    let receivedAt: String
}
