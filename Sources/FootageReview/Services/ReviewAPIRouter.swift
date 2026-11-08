import Darwin
import Foundation
import ImageIO

actor ReviewAPIRouter {
    private let snapshot: @Sendable () async throws -> APILibrarySnapshot
    private let apply: @Sendable (ReviewedGroupImport) async throws -> APIImportResult
    private var exports: [String: ExportSnapshot] = [:]
    private static let bodyLimit = 8 * 1024 * 1024
    private static let imageLimit = 512 * 1024

    init(snapshot: @escaping @Sendable () async throws -> APILibrarySnapshot,
         apply: @escaping @Sendable (ReviewedGroupImport) async throws -> APIImportResult) {
        self.snapshot = snapshot
        self.apply = apply
    }

    func handle(_ request: APIRequest) async -> APIResponse {
        do {
            guard let components = URLComponents(string: request.target), components.host == nil,
                  components.fragment == nil, components.path.hasPrefix("/") else {
                throw APIProblem(status: 400, code: "invalid_path", message: "Use a local API path.")
            }
            let method: String
            switch components.path {
            case "/v1/health", "/v1/groups", "/v1/appearances": method = "GET"
            case "/v1/group-imports": method = "POST"
            default: throw APIProblem(status: 404, code: "not_found", message: "This API route does not exist.")
            }
            guard request.method == method else {
                return problem(405, "method_not_allowed", "Use \(method) for this route.", headers: ["Allow": method])
            }
            switch components.path {
            case "/v1/health":
                let library = try await snapshot()
                return APIResponse.json(value: Health(status: "ok", libraryID: library.libraryID, revision: library.revision))
            case "/v1/groups":
                let library = try await snapshot()
                return APIResponse.json(value: GroupList(libraryID: library.libraryID, revision: library.revision,
                                                       items: library.groups.sorted { $0.id < $1.id }.map(GroupExport.init)))
            case "/v1/appearances":
                return try await appearances(components.queryItems ?? [])
            default:
                let contentType = request.headers.first { $0.key.lowercased() == "content-type" }?.value ?? ""
                guard contentType.split(separator: ";").first?.trimmingCharacters(in: .whitespaces).lowercased() == "application/json" else {
                    throw APIProblem(status: 415, code: "unsupported_media_type", message: "Send group imports as application/json.")
                }
                let imported: ReviewedGroupImport
                do { imported = try JSONDecoder().decode(ReviewedGroupImport.self, from: request.body) }
                catch { throw APIProblem(status: 400, code: "invalid_json", message: "The JSON body must match the reviewed group import schema.") }
                return APIResponse.json(value: try await apply(imported))
            }
        } catch let error as APIProblem {
            return problem(error.status, error.code, error.message)
        } catch {
            return problem(500, "internal_error", "The API could not complete the request.")
        }
    }

    private func appearances(_ parameters: [URLQueryItem]) async throws -> APIResponse {
        let allowed = Set(["limit", "cursor", "source", "date", "camera"])
        var query: [String: String] = [:]
        for item in parameters {
            guard allowed.contains(item.name), query[item.name] == nil, let value = item.value else {
                throw APIProblem(status: 400, code: "invalid_query", message: "Use each supported query parameter at most once with a value.")
            }
            query[item.name] = value
        }
        let limit: Int
        if let raw = query["limit"] {
            guard let value = Int(raw), (1...50).contains(value) else {
                throw APIProblem(status: 400, code: "invalid_limit", message: "limit must be an integer between 1 and 50.")
            }
            limit = value
        } else { limit = 20 }
        let now = Date()
        exports = exports.filter { now.timeIntervalSince($0.value.created) < 1800 }
        let export: ExportSnapshot
        let offset: Int
        if let value = query["cursor"] {
            let cursor = try decodeCursor(value)
            guard let saved = exports[cursor.snapshotID] else {
                throw APIProblem(status: 410, code: "snapshot_expired", message: "This export snapshot expired or was evicted. Start again without cursor.")
            }
            guard cursor.offset > 0, cursor.offset < saved.items.count else {
                throw APIProblem(status: 400, code: "invalid_cursor", message: "The cursor position is invalid.")
            }
            for name in ["source", "date", "camera"] {
                if let value = query[name], value != saved.filters[name] {
                    throw APIProblem(status: 400, code: "cursor_filter_mismatch", message: "Keep the original filters when continuing an export snapshot.")
                }
            }
            export = saved
            offset = cursor.offset
        } else {
            let filters = Dictionary(uniqueKeysWithValues: ["source", "date", "camera"].map { ($0, query[$0] ?? "") })
            let library = try await snapshot()
            let items = library.items.filter { item in
                (filters["source"]!.isEmpty || item.clip.source == filters["source"]) &&
                (filters["date"]!.isEmpty || item.clip.date == filters["date"]) &&
                (filters["camera"]!.isEmpty || item.clip.camera == filters["camera"])
            }.sorted { $0.appearance.id < $1.appearance.id }
            export = ExportSnapshot(id: UUID().uuidString, libraryID: library.libraryID, revision: library.revision,
                                    items: items, filters: filters, created: now)
            if exports.count >= 4, let oldest = exports.min(by: { $0.value.created < $1.value.created })?.key {
                exports.removeValue(forKey: oldest)
            }
            exports[export.id] = export
            offset = 0
        }
        var output: [AppearanceExport] = []
        var estimatedBytes = 0
        for item in export.items.dropFirst(offset).prefix(limit) {
            let crop = try readCrop(item)
            let encoded = AppearanceExport(item: item, jpeg: crop)
            let encodedSize = try JSONEncoder().encode(encoded).count
            if !output.isEmpty && estimatedBytes + encodedSize > Self.bodyLimit - 4096 { break }
            output.append(encoded)
            estimatedBytes += encodedSize
        }
        let nextOffset = offset + output.count
        let next = nextOffset < export.items.count ? try encodeCursor(Cursor(snapshotID: export.id, offset: nextOffset)) : nil
        let response = APIResponse.json(value: AppearanceList(libraryID: export.libraryID, revision: export.revision,
                                                             snapshotID: export.id, items: output, nextCursor: next, total: export.items.count))
        guard response.body.count <= Self.bodyLimit else {
            throw APIProblem(status: 413, code: "export_too_large", message: "This export exceeds 8 MiB. Request a smaller limit.")
        }
        return response
    }

    private func readCrop(_ item: APIExportItem) throws -> Data {
        // O_NOFOLLOW and fstat ensure only the app's regular JPEG crop is opened.
        let descriptor = item.cropURL.withUnsafeFileSystemRepresentation { path in
            path.map { open($0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC) } ?? -1
        }
        guard descriptor >= 0 else {
            throw APIProblem(status: 422, code: "crop_unavailable", message: "The JPEG crop for appearance \(item.appearance.id) is unavailable or unsafe.")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG else {
            throw APIProblem(status: 422, code: "invalid_crop", message: "The crop for appearance \(item.appearance.id) must be a regular JPEG file.")
        }
        guard info.st_size > 0, info.st_size <= Self.imageLimit else {
            throw APIProblem(status: 422, code: "crop_too_large", message: "The crop for appearance \(item.appearance.id) must contain 1–524288 bytes.")
        }
        var data = Data()
        do {
            while data.count <= Self.imageLimit {
                let chunk = try handle.read(upToCount: Self.imageLimit + 1 - data.count) ?? Data()
                if chunk.isEmpty { break }
                data.append(chunk)
            }
        }
        catch { throw APIProblem(status: 422, code: "crop_unavailable", message: "The JPEG crop for appearance \(item.appearance.id) could not be read.") }
        guard data.count <= Self.imageLimit, data.count >= 3, data.starts(with: [0xff, 0xd8, 0xff]),
              let image = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(image) as String? == "public.jpeg",
              CGImageSourceCreateThumbnailAtIndex(image, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                            kCGImageSourceThumbnailMaxPixelSize: 64] as CFDictionary) != nil else {
            throw APIProblem(status: 422, code: "invalid_crop", message: "The crop for appearance \(item.appearance.id) is not a supported JPEG.")
        }
        return data
    }

    private func decodeCursor(_ value: String) throws -> Cursor {
        guard value.count <= 512 else { throw invalidCursor() }
        let base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        let padded = base64 + String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let bytes = Data(base64Encoded: padded), let cursor = try? JSONDecoder().decode(Cursor.self, from: bytes),
              UUID(uuidString: cursor.snapshotID) != nil else { throw invalidCursor() }
        return cursor
    }

    private func encodeCursor(_ cursor: Cursor) throws -> String {
        try JSONEncoder().encode(cursor).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private func invalidCursor() -> APIProblem {
        APIProblem(status: 400, code: "invalid_cursor", message: "The cursor is invalid. Use next_cursor from the preceding response.")
    }

    private func problem(_ status: Int, _ code: String, _ message: String, headers: [String: String] = [:]) -> APIResponse {
        var response = APIResponse.json(status: status, value: ["code": code, "message": message])
        response.headers.merge(headers) { _, new in new }
        return response
    }
}

private struct ExportSnapshot: Sendable {
    let id: String
    let libraryID: String
    let revision: Int
    let items: [APIExportItem]
    let filters: [String: String]
    let created: Date
}

private struct Cursor: Codable {
    let snapshotID: String
    let offset: Int
}

private struct Health: Encodable {
    let status: String
    let libraryID: String
    let revision: Int
    enum CodingKeys: String, CodingKey { case status, libraryID = "library_id", revision }
}

private struct GroupExport: Encodable {
    let id: String
    let name: String
    let note: String
    let appearanceIDs: [String]
    init(_ group: ReviewGroup) {
        id = group.id; name = group.name; note = group.note; appearanceIDs = group.appearanceIDs.sorted()
    }
    enum CodingKeys: String, CodingKey { case id, name, note, appearanceIDs = "appearance_ids" }
}

private struct GroupList: Encodable {
    let libraryID: String
    let revision: Int
    let items: [GroupExport]
    enum CodingKeys: String, CodingKey { case libraryID = "library_id", revision, items }
}

private struct AppearanceList: Encodable {
    let libraryID: String
    let revision: Int
    let snapshotID: String
    let items: [AppearanceExport]
    let nextCursor: String?
    let total: Int
    enum CodingKeys: String, CodingKey { case libraryID = "library_id", revision, snapshotID = "snapshot_id", items, nextCursor = "next_cursor", total }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(libraryID, forKey: .libraryID)
        try container.encode(revision, forKey: .revision)
        try container.encode(snapshotID, forKey: .snapshotID)
        try container.encode(items, forKey: .items)
        try container.encode(nextCursor, forKey: .nextCursor)
        try container.encode(total, forKey: .total)
    }
}

private struct AppearanceExport: Encodable {
    struct Image: Encodable {
        let mimeType = "image/jpeg"
        let base64: String
        enum CodingKeys: String, CodingKey { case mimeType = "mime_type", base64 }
    }
    let id: String
    let clipID: String
    let camera: String
    let source: String
    let date: String
    let clock: String
    let seconds: Double
    let confidence: Double
    let groupIDs: [String]
    let image: Image
    init(item: APIExportItem, jpeg: Data) {
        id = item.appearance.id; clipID = item.clip.id; camera = item.clip.camera; source = item.clip.source
        date = item.clip.date; clock = item.clip.clock; seconds = item.appearance.seconds
        confidence = item.appearance.confidence; groupIDs = item.groupIDs.sorted()
        image = Image(base64: jpeg.base64EncodedString())
    }
    enum CodingKeys: String, CodingKey { case id, clipID = "clip_id", camera, source, date, clock, seconds, confidence, groupIDs = "group_ids", image }
}
