import AppKit
import Darwin
import Foundation

struct StoredScan: Codable, Sendable {
    var result: ScanResult
    var cropFolder: String
    var formatVersion = 1
}

struct ScanArchive: Sendable {
    let library: URL

    var scans: URL { library.appendingPathComponent("Scans", isDirectory: true) }
    var crops: URL { library.appendingPathComponent("Crops", isDirectory: true) }
    var runURL: URL { library.appendingPathComponent("Run.json") }

    func cropURL(folder: String, file: String) -> URL {
        crops.appendingPathComponent(folder, isDirectory: true).appendingPathComponent(file)
    }

    func read(_ clip: ReviewClip) throws -> StoredScan? {
        let url = receiptURL(for: clip.id)
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
        let receipt = try JSONDecoder().decode(StoredScan.self, from: data)
        guard receipt.formatVersion == 1, receipt.result.clipID == clip.id,
              receipt.result.sampledFrames > 0, UUID(uuidString: receipt.cropFolder) != nil else {
            throw ReviewError("The saved scan is invalid. Scan this clip again.")
        }
        let source = URL(fileURLWithPath: clip.path)
        if let current = try? FileStamp.read(source), current != receipt.result.stamp {
            throw ReviewError("The source changed. Scan this clip again to refresh its appearances.")
        }
        for item in receipt.result.appearances {
            guard item.clipID == clip.id, item.seconds.isFinite, item.seconds >= 0,
                  !item.cropFile.isEmpty, !item.cropFile.contains("/"),
                  item.cropFile != ".", item.cropFile != "..",
                  FileManager.default.fileExists(atPath: cropURL(folder: receipt.cropFolder, file: item.cropFile).path) else {
                throw ReviewError("A saved thumbnail is missing or invalid. Scan this clip again.")
            }
        }
        return receipt
    }

    func write(_ receipt: StoredScan) throws {
        try FileManager.default.createDirectory(at: scans, withIntermediateDirectories: true)
        try JSONEncoder().encode(receipt).write(to: receiptURL(for: receipt.result.clipID), options: .atomic)
    }

    func readRun() throws -> SavedRun? {
        do {
            return try JSONDecoder().decode(SavedRun.self, from: Data(contentsOf: runURL))
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    func writeRun(_ run: SavedRun) throws {
        try JSONEncoder().encode(run).write(to: runURL, options: .atomic)
    }

    private func receiptURL(for clipID: String) -> URL {
        scans.appendingPathComponent(clipID + ".json")
    }
}

final class LibraryLease {
    private let descriptor: Int32

    init(_ library: URL) throws {
        // Releases before the lease was introduced still own their adjacent library.
        if let identifier = Bundle.main.bundleIdentifier {
            let root = library.resolvingSymlinksInPath().standardizedFileURL
            let currentPID = ProcessInfo.processInfo.processIdentifier
            let alreadyOpen = NSRunningApplication.runningApplications(withBundleIdentifier: identifier).contains { app in
                guard app.processIdentifier != currentPID, !app.isTerminated,
                      let parent = app.bundleURL?.deletingLastPathComponent() else { return false }
                return parent.appendingPathComponent("Footage Review Library").resolvingSymlinksInPath().standardizedFileURL.path == root.path
            }
            guard !alreadyOpen else {
                throw ReviewError("This library is open in another copy of Footage Review. Quit that copy and reopen this app.")
            }
        }

        let path = library.appendingPathComponent("Library.lock").path
        let fd = open(path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw ReviewError("The library lock could not be opened.") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw ReviewError("This library is open in another copy of Footage Review.")
        }
        descriptor = fd
    }

    deinit { close(descriptor) }
}
