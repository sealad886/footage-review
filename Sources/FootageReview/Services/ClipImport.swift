import Foundation

enum ClipImport {
    private struct ImportError: LocalizedError {
        let path: String
        let reason: String

        var errorDescription: String? {
            "Could not import \(path). \(reason)"
        }
    }

    private static let videoExtensions: Set<String> = ["mp4", "mov", "m4v", "avi"]
    private static let fileKeys: Set<URLResourceKey> = [
        .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
    ]
    private static let unknown = "Unknown"
    private static let blinkName = try! NSRegularExpression(
        pattern: #"^([0-9]{2})-([0-9]{2})-([0-9]{2})_([A-Za-z0-9][A-Za-z0-9 _-]*?)G8T[A-Za-z0-9]+_[0-9]+$"#,
        options: .caseInsensitive
    )
    private static let blinkDate = try! NSRegularExpression(
        pattern: #"^([0-9]{2})-([0-9]{2})-([0-9]{2})$"#
    )
    private static let wallName = try! NSRegularExpression(
        pattern: #"^([0-9]{4})([0-9]{2})([0-9]{2})([0-9]{2})([0-9]{2})([0-9]{2})_[0-9]+_([A-Za-z0-9]+)$"#
    )

    static func discover(_ urls: [URL]) throws -> [ReviewClip] {
        var pending = urls.sorted(by: { $0.path > $1.path })
        var visited = Set<String>()
        var files: [URL] = []
        let manager = FileManager.default

        while let url = pending.popLast() {
            guard url.isFileURL else {
                throw ImportError(path: url.absoluteString, reason: "Select a local file or folder.")
            }
            guard !isFinderMetadata(url) else { continue }

            do {
                let properties = try url.resourceValues(forKeys: fileKeys)
                guard properties.isSymbolicLink != true else { continue }
                let canonical = url.standardizedFileURL
                guard visited.insert(canonical.path).inserted else { continue }
                if properties.isDirectory == true {
                    let children = try manager.contentsOfDirectory(
                        at: canonical, includingPropertiesForKeys: nil, options: []
                    )
                    pending.append(contentsOf: children.sorted(by: { $0.path > $1.path }))
                } else if properties.isRegularFile == true,
                          videoExtensions.contains(canonical.pathExtension.lowercased()) {
                    files.append(canonical)
                }
            } catch {
                throw ImportError(path: url.path, reason: error.localizedDescription)
            }
        }

        return files.sorted(by: { $0.path < $1.path }).map(clip(from:))
    }

    private static func isFinderMetadata(_ url: URL) -> Bool {
        url.pathComponents.contains { $0.caseInsensitiveCompare(".DS_Store") == .orderedSame }
    }

    private static func clip(from url: URL) -> ReviewClip {
        let name = url.deletingPathExtension().lastPathComponent
        if let parts = captures(wallName, in: name) {
            return ReviewClip(
                path: url.path, source: "Wall", camera: "Wall \(parts[6])",
                date: date(year: parts[0], month: parts[1], day: parts[2]),
                clock: clock(hour: parts[3], minute: parts[4], second: parts[5])
            )
        }
        if let parts = captures(blinkName, in: name) {
            let day = url.pathComponents.dropLast().reversed().compactMap {
                captures(blinkDate, in: $0)
            }.first
            let captureDate = day.map { date(year: "20" + $0[0], month: $0[1], day: $0[2]) } ?? unknown
            return ReviewClip(
                path: url.path, source: "Blink", camera: parts[3], date: captureDate,
                clock: clock(hour: parts[0], minute: parts[1], second: parts[2])
            )
        }
        return ReviewClip(
            path: url.path, source: "Imported", camera: unknown, date: unknown, clock: unknown
        )
    }

    private static func captures(_ expression: NSRegularExpression, in text: String) -> [String]? {
        guard let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else {
            return nil
        }
        return (1..<match.numberOfRanges).compactMap { index in
            Range(match.range(at: index), in: text).map { String(text[$0]) }
        }
    }

    private static func date(year: String, month: String, day: String) -> String {
        let components = DateComponents(year: Int(year), month: Int(month), day: Int(day))
        return components.isValidDate(in: Calendar(identifier: .gregorian))
            ? "\(year)-\(month)-\(day)" : unknown
    }

    private static func clock(hour: String, minute: String, second: String) -> String {
        guard let hours = Int(hour), let minutes = Int(minute), let seconds = Int(second),
              (0..<24).contains(hours), (0..<60).contains(minutes), (0..<60).contains(seconds) else {
            return unknown
        }
        return "\(hour):\(minute):\(second)"
    }
}
