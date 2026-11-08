import CryptoKit
import Foundation

enum ReviewedGroupPlanner {
    static func plan(
        _ request: ReviewedGroupImport,
        state: ReviewAPIState,
        groups: [ReviewGroup],
        knownAppearanceIDs: Set<String>
    ) throws -> (ReviewAPIState, [ReviewGroup], APIImportResult) {
        guard let importUUID = UUID(uuidString: request.importID),
              let libraryUUID = UUID(uuidString: request.libraryID) else {
            throw problem(400, "invalid_identifier", "Use UUIDs for import_id and library_id.")
        }
        guard libraryUUID.uuidString == state.libraryID else {
            throw problem(409, "wrong_library", "These assignments belong to another review library.")
        }
        guard (1...100).contains(request.groups.count),
              request.groups.reduce(0, { $0 + $1.appearanceIDs.count }) <= 10_000 else {
            throw problem(400, "import_limit", "Submit 1–100 groups with at most 10,000 appearance assignments.")
        }
        guard (request.reviewer?.count ?? 0) <= 200 else {
            throw problem(400, "invalid_reviewer", "Keep the reviewer label within 200 characters.")
        }

        var suppliedIDs = Set<String>()
        var normalized: [ReviewedGroupAssignment] = []
        for entry in request.groups {
            guard let uuid = UUID(uuidString: entry.id) else {
                throw problem(400, "invalid_group_id", "Use a UUID for each group id.")
            }
            let id = uuid.uuidString
            guard suppliedIDs.insert(id).inserted else {
                throw problem(400, "duplicate_group", "Each group id can appear once per import.")
            }
            let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 120, entry.note.count <= 4000,
                  entry.appearanceIDs.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 512 }) else {
                throw problem(400, "invalid_group", "Group names must contain 1–120 characters, notes at most 4,000, and appearance IDs must be exported IDs.")
            }
            normalized.append(ReviewedGroupAssignment(
                id: id, name: name, note: entry.note,
                appearanceIDs: Array(Set(entry.appearanceIDs)).sorted()
            ))
        }
        normalized.sort { $0.id < $1.id }
        let importID = importUUID.uuidString
        let canonical = ReviewedGroupImport(
            importID: importID, libraryID: libraryUUID.uuidString,
            baseRevision: request.baseRevision, reviewer: request.reviewer, groups: normalized
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let digest = SHA256.hash(data: try encoder.encode(canonical))
            .map { String(format: "%02x", $0) }.joined()

        if let previous = state.imports[importID] {
            guard previous.digest == digest else {
                throw problem(409, "import_id_conflict", "This import_id was already used for different assignments.")
            }
            return (state, groups, APIImportResult(
                importID: importID, revision: previous.revision,
                currentRevision: state.revision, groupIDs: previous.groupIDs,
                appearanceCount: previous.appearanceCount, replayed: true
            ))
        }
        guard request.baseRevision == state.revision else {
            throw problem(409, "revision_conflict", "Groups changed after this review was exported. Fetch /v1/groups and reconcile the current revision.")
        }
        let suppliedAppearances = Set(normalized.flatMap(\.appearanceIDs))
        let unknown = suppliedAppearances.subtracting(knownAppearanceIDs)
        guard unknown.isEmpty else {
            throw problem(422, "unknown_appearance", "\(unknown.count) appearance IDs are unavailable in the current library. Fetch a fresh batch before importing.")
        }
        var updated = groups
        for entry in normalized {
            let group = ReviewGroup(id: entry.id, name: entry.name, note: entry.note,
                                    appearanceIDs: Set(entry.appearanceIDs))
            if let index = updated.firstIndex(where: { $0.id == group.id }) {
                updated[index] = group
            } else {
                updated.append(group)
            }
        }
        var names: [String] = []
        for group in updated {
            guard !names.contains(where: { ReviewGroup.namesMatch($0, group.name) }) else {
                throw problem(409, "group_name_conflict", "Two groups would have the same name. Rename the imported group or use the existing group's id.")
            }
            names.append(group.name)
        }

        var next = state
        next.revision += 1
        let ids = normalized.map(\.id)
        next.imports[importID] = ReviewedImportReceipt(
            digest: digest, revision: next.revision, groupIDs: ids,
            appearanceCount: suppliedAppearances.count, reviewer: request.reviewer,
            receivedAt: ISO8601DateFormatter().string(from: Date())
        )
        next.lastImportID = importID
        return (next, updated, APIImportResult(
            importID: importID, revision: next.revision, currentRevision: next.revision,
            groupIDs: ids, appearanceCount: suppliedAppearances.count, replayed: false
        ))
    }

    private static func problem(_ status: Int, _ code: String, _ message: String) -> APIProblem {
        APIProblem(status: status, code: code, message: message)
    }
}
