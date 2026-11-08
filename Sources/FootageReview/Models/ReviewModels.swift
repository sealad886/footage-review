import CryptoKit
import Darwin
import Foundation

struct ReviewClip: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let path: String
    let source: String
    let camera: String
    let date: String
    let clock: String

    init(path: String, source: String, camera: String, date: String, clock: String) {
        let standardizedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        self.id = stableKey(standardizedPath)
        self.path = standardizedPath
        self.source = source
        self.camera = camera
        self.date = date
        self.clock = clock
    }

    var filename: String { URL(fileURLWithPath: path).lastPathComponent }
}

struct FileStamp: Codable, Hashable, Sendable {
    let device: Int32
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int
    let modifiedNanos: Int
    let changedSeconds: Int
    let changedNanos: Int

    static func read(_ url: URL) throws -> Self {
        var entry = stat()
        let result = url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return Int32(-1) }
            return lstat(path, &entry)
        }
        guard result == 0 else {
            throw ReviewError("The clip is unavailable. Check that its volume is mounted.")
        }
        guard entry.st_mode & S_IFMT == S_IFREG else {
            throw ReviewError("Choose a regular video file.")
        }
        return Self(device: entry.st_dev, inode: entry.st_ino, size: entry.st_size,
                    modifiedSeconds: entry.st_mtimespec.tv_sec,
                    modifiedNanos: entry.st_mtimespec.tv_nsec,
                    changedSeconds: entry.st_ctimespec.tv_sec,
                    changedNanos: entry.st_ctimespec.tv_nsec)
    }

    var generation: String {
        stableKey("\(device):\(inode):\(size):\(modifiedSeconds):\(modifiedNanos):\(changedSeconds):\(changedNanos)")
    }
}

struct Appearance: Codable, Hashable, Identifiable, Sendable {
    let id: String
    let clipID: String
    let seconds: Double
    let confidence: Double
    let cropFile: String
}

struct ScanResult: Codable, Sendable {
    let clipID: String
    let stamp: FileStamp
    let duration: Double
    let sampledFrames: Int
    let appearances: [Appearance]
    let warnings: [String]
}

struct ReviewGroup: Codable, Equatable, Identifiable, Sendable {
    var id: String
    var name: String
    var note: String
    var appearanceIDs: Set<String>

    static func namesMatch(_ first: String, _ second: String) -> Bool {
        first.localizedCaseInsensitiveCompare(second) == .orderedSame
    }
}

struct ScanProgress: Sendable {
    var completed = 0
    var total: Int
    var failed = 0
    var appearances = 0
    var adopted = 0
    var state = ScanPhase.running
    var current = ""
}

struct ReviewError: LocalizedError, Sendable {
    let errorDescription: String?

    init(_ message: String) { errorDescription = message }
}

private func stableKey(_ value: String) -> String {
    SHA256.hash(data: Data(value.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
}

enum ScanPhase: String, Codable, Sendable {
    case running, paused, cancelled, completed

    var title: String {
        switch self {
        case .running: return "Scanning"
        case .paused: return "Paused"
        case .cancelled: return "Cancelled"
        case .completed: return "Finished"
        }
    }
}

struct SavedRun: Codable, Sendable {
    let id: String
    let clipIDs: [String]
    var phase: ScanPhase
    var failures: [String: String] = [:]
}
