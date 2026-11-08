import CryptoKit
import Foundation
import Observation

private struct LibraryState: Codable, Sendable {
    var clips: [ReviewClip] = []
    var groups: [ReviewGroup] = []
    var reviewAPI: ReviewAPIState?
}

private enum ScanOutcome: Sendable {
    case complete(StoredScan, adopted: Bool)
    case failed(clipID: String, message: String)
    case cancelled
}

@MainActor
@Observable
final class ReviewStore {
    private(set) var clips: [ReviewClip] = []
    private(set) var appearances: [Appearance] = []
    private(set) var groups: [ReviewGroup] = []
    private(set) var scanProgress: ScanProgress?
    private(set) var isImporting = false
    private(set) var isScanning = false
    private(set) var isLoadingLibrary = false
    private(set) var scannedClipIDs: Set<String> = []
    private(set) var failedClipIDs: Set<String> = []
    private(set) var scanIssues: [String: String] = [:]
    var errorMessage: String?
    private(set) var apiRunning = false
    private(set) var apiEndpoint: String?
    private(set) var apiToken: String?
    private(set) var apiMessage: String?
    private(set) var apiLastImport: String?

    let libraryURL: URL
    private var clipByID: [String: ReviewClip] = [:]
    private var scanByID: [String: StoredScan] = [:]
    private var scanTask: Task<Void, Never>?
    private var persistenceReady = false
    private var runStateReadable = true
    private var run: SavedRun?
    private var lease: LibraryLease?
    private var apiState: ReviewAPIState?
    private var apiServer: ReviewHTTPServer?
    private var apiGeneration = UUID()

    var canResumeScan: Bool { !isLoadingLibrary && !isScanning && run?.phase == .paused }
    var canCancelScan: Bool { run?.phase == .running || run?.phase == .paused }

    init(libraryURL: URL? = nil) {
        self.libraryURL = libraryURL ?? Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("Footage Review Library", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: self.libraryURL, withIntermediateDirectories: true)
            lease = try LibraryLease(self.libraryURL)
            if FileManager.default.fileExists(atPath: workspaceURL.path) {
                let state = try JSONDecoder().decode(LibraryState.self, from: Data(contentsOf: workspaceURL))
                replaceClips(state.clips)
                groups = state.groups
                apiState = state.reviewAPI
                updateImportSummary()
            }
            persistenceReady = true
            restoreRun()
            loadScans()
        } catch {
            errorMessage = "The library could not be opened. \(error.localizedDescription)"
        }
    }

    private var workspaceURL: URL { libraryURL.appendingPathComponent("Library.json") }
    private var archive: ScanArchive { ScanArchive(library: libraryURL) }

    private func restoreRun() {
        do {
            run = try archive.readRun()
        } catch {
            runStateReadable = false
            errorMessage = "The saved run could not be read. Completed clip results remain available."
            return
        }
        if var interrupted = run, interrupted.phase == .running {
            interrupted.phase = .paused
            if !persistRun(interrupted) { run = interrupted }
        }
    }

    private func loadScans() {
        let clips = clips
        let archive = archive
        guard !clips.isEmpty else { return }
        isLoadingLibrary = true
        Task {
            let restored = await Task.detached(priority: .userInitiated) {
                var scans: [StoredScan] = []
                var issues: [String: String] = [:]
                for clip in clips {
                    do {
                        if let scan = try archive.read(clip) { scans.append(scan) }
                    } catch {
                        issues[clip.id] = error.localizedDescription
                    }
                }
                return (scans, issues)
            }.value
            scanIssues = restored.1
            for scan in restored.0 { installScan(scan) }
            if var current = run {
                for (id, message) in current.failures where !scannedClipIDs.contains(id) {
                    failedClipIDs.insert(id)
                    scanIssues[id] = message
                }
                if current.phase == .paused && remainingClips(for: current).isEmpty {
                    var completed = current
                    completed.phase = .completed
                    if persistRun(completed) { current = completed }
                }
                scanProgress = progress(for: current)
            }
            isLoadingLibrary = false
        }
    }

    private func installScan(_ scan: StoredScan) {
        let clipID = scan.result.clipID
        if scanByID[clipID] != nil {
            appearances.removeAll { $0.clipID == clipID }
        }
        scanByID[clipID] = scan
        scannedClipIDs.insert(clipID)
        appearances.append(contentsOf: scan.result.appearances)
        failedClipIDs.remove(clipID)
        scanIssues[clipID] = scan.result.warnings.isEmpty ? nil : scan.result.warnings.joined(separator: " ")
    }

    func clip(for appearance: Appearance) -> ReviewClip? { clipByID[appearance.clipID] }

    func cropURL(for appearance: Appearance) -> URL {
        let folder = scanByID[appearance.clipID]?.cropFolder ?? "unavailable"
        return archive.cropURL(folder: folder, file: appearance.cropFile)
    }

    func importURLs(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        performImport { try ClipImport.discover(urls) }
    }

    private func performImport(_ discover: @escaping @Sendable () throws -> [ReviewClip]) {
        guard !isImporting, !isLoadingLibrary, persistenceReady else { return }
        isImporting = true
        Task {
            defer { isImporting = false }
            do {
                let found = try await Task.detached(priority: .userInitiated, operation: discover).value
                guard !found.isEmpty else {
                    throw ReviewError("No supported video clips were found in the selected files or folders.")
                }
                var merged = clipByID
                for clip in found where merged[clip.id] == nil { merged[clip.id] = clip }
                let updated = merged.values.sorted { ($0.date, $0.clock, $0.path) < ($1.date, $1.clock, $1.path) }
                if save(clips: updated, groups: groups) { replaceClips(updated) }
            } catch {
                errorMessage = "Import failed. \(error.localizedDescription)"
            }
        }
    }

    private func replaceClips(_ newClips: [ReviewClip]) {
        var indexed: [String: ReviewClip] = [:]
        clips = newClips.filter { indexed.updateValue($0, forKey: $0.id) == nil }
        clipByID = indexed
    }

    @discardableResult
    private func save(clips: [ReviewClip], groups: [ReviewGroup]) -> Bool {
        guard persistenceReady else {
            errorMessage = "The library is unavailable. Reopen it after resolving the file error."
            return false
        }
        do {
            var nextAPI = apiState
            if nextAPI != nil { nextAPI!.revision += 1 }
            try writeLibrary(clips: clips, groups: groups, api: nextAPI)
            apiState = nextAPI
            return true
        } catch {
            errorMessage = "The change could not be saved. \(error.localizedDescription)"
            return false
        }
    }

    private func writeLibrary(clips: [ReviewClip], groups: [ReviewGroup], api: ReviewAPIState?) throws {
        if apiState == nil, api != nil, FileManager.default.fileExists(atPath: workspaceURL.path) {
            let backup = libraryURL.appendingPathComponent("Library.before-API.json")
            if !FileManager.default.fileExists(atPath: backup.path) {
                try Data(contentsOf: workspaceURL).write(to: backup, options: .withoutOverwriting)
            }
        }
        let state = LibraryState(clips: clips, groups: groups, reviewAPI: api)
        let data = try JSONEncoder().encode(state)
        try data.write(to: workspaceURL, options: .atomic)
    }

    func createGroup(_ name: String, note: String = "", appearanceIDs: Set<String> = []) -> String? {
        guard let name = validGroupName(name, except: nil) else { return nil }
        let group = ReviewGroup(id: UUID().uuidString, name: name, note: note,
                                appearanceIDs: validAppearanceIDs(appearanceIDs))
        let updated = groups + [group]
        guard save(clips: clips, groups: updated) else { return nil }
        groups = updated
        return group.id
    }

    func editGroup(_ original: ReviewGroup, name: String, note: String) -> Bool {
        guard let index = groups.firstIndex(where: { $0.id == original.id }), groups[index] == original else {
            errorMessage = "This group changed while you were editing it. Reopen the editor to review its current name, note, and members."
            return false
        }
        guard let name = validGroupName(name, except: original.id) else { return false }
        var updated = groups
        updated[index].name = name
        updated[index].note = note
        guard save(clips: clips, groups: updated) else { return false }
        groups = updated
        return true
    }

    func add(_ appearanceIDs: Set<String>, to groupID: String) {
        let verified = validAppearanceIDs(appearanceIDs)
        guard !verified.isEmpty else { return }
        changeGroup(groupID) { $0.appearanceIDs.formUnion(verified) }
    }

    func remove(_ appearanceIDs: Set<String>, from groupID: String) {
        changeGroup(groupID) { $0.appearanceIDs.subtract(appearanceIDs) }
    }

    private func changeGroup(_ id: String, change: (inout ReviewGroup) -> Void) {
        guard let index = groups.firstIndex(where: { $0.id == id }) else { return }
        var updated = groups
        change(&updated[index])
        if save(clips: clips, groups: updated) { groups = updated }
    }

    private func validGroupName(_ name: String, except id: String?) -> String? {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            errorMessage = "Enter a name for the group."
            return nil
        }
        guard !groups.contains(where: { $0.id != id && ReviewGroup.namesMatch($0.name, name) }) else {
            errorMessage = "A group already uses that name."
            return nil
        }
        return name
    }

    private func validAppearanceIDs(_ ids: Set<String>) -> Set<String> {
        Set(appearances.lazy.map(\.id).filter { ids.contains($0) })
    }

    private func ensureAPIState() throws -> ReviewAPIState {
        guard persistenceReady else {
            throw APIProblem(status: 503, code: "library_unavailable", message: "The review library is unavailable.")
        }
        guard !isLoadingLibrary, !isImporting else {
            throw APIProblem(status: 503, code: "library_loading", message: "The library is still loading. Retry shortly.")
        }
        if let state = apiState { return state }
        let state = ReviewAPIState()
        do {
            try writeLibrary(clips: clips, groups: groups, api: state)
        } catch {
            throw APIProblem(status: 503, code: "save_failed", message: "The library could not save its API identity.")
        }
        apiState = state
        return state
    }

    func apiSnapshot() throws -> APILibrarySnapshot {
        let state = try ensureAPIState()
        var memberships: [String: [String]] = [:]
        for group in groups {
            for id in group.appearanceIDs { memberships[id, default: []].append(group.id) }
        }
        let items = appearances.compactMap { item -> APIExportItem? in
            guard let clip = clipByID[item.clipID] else { return nil }
            return APIExportItem(appearance: item, clip: clip, cropURL: cropURL(for: item),
                                 groupIDs: (memberships[item.id] ?? []).sorted())
        }
        return APILibrarySnapshot(libraryID: state.libraryID, revision: state.revision,
                                  groups: groups, items: items)
    }

    func applyReviewedGroups(_ request: ReviewedGroupImport) throws -> APIImportResult {
        let state = try ensureAPIState()
        let (next, updated, result) = try ReviewedGroupPlanner.plan(
            request, state: state, groups: groups,
            knownAppearanceIDs: Set(appearances.map(\.id))
        )
        guard !result.replayed else { return result }
        do {
            try writeLibrary(clips: clips, groups: updated, api: next)
        } catch {
            throw APIProblem(status: 503, code: "save_failed", message: "The reviewed groups could not be saved. Retry the same import_id.")
        }
        groups = updated
        apiState = next
        updateImportSummary()
        return result
    }

    private func updateImportSummary() {
        guard let state = apiState, let id = state.lastImportID,
              let receipt = state.imports[id] else { return }
        let reviewer = receipt.reviewer.map { " by " + $0 } ?? ""
        apiLastImport = "\(receipt.groupIDs.count) reviewed groups, \(receipt.appearanceCount) appearances\(reviewer)"
    }

    func startAPI(port: UInt16 = 8765, allowedOrigin: String? = nil) {
        guard apiServer == nil else { return }
        let origin = allowedOrigin?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let origin, !origin.isEmpty {
            guard let url = URLComponents(string: origin),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host != nil, url.user == nil, url.password == nil,
                  url.query == nil, url.fragment == nil, url.path.isEmpty else {
                apiMessage = "Enter a browser origin such as http://localhost:3000."
                return
            }
        }
        do { _ = try ensureAPIState() }
        catch let issue as APIProblem { apiMessage = issue.message; return }
        catch { apiMessage = "The library is unavailable."; return }

        let token = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString() }
        let generation = UUID()
        apiGeneration = generation
        let router = ReviewAPIRouter(snapshot: { [weak self] in
            guard let self else {
                throw APIProblem(status: 503, code: "library_closed", message: "The review library is closed.")
            }
            return try await self.apiSnapshot()
        }, apply: { [weak self] request in
            guard let self else {
                throw APIProblem(status: 503, code: "library_closed", message: "The review library is closed.")
            }
            return try await self.applyReviewedGroups(request)
        })
        let server = ReviewHTTPServer(token: token, allowedOrigin: origin?.isEmpty == false ? origin : nil) { request in
            await router.handle(request)
        }
        apiServer = server
        apiToken = token
        apiMessage = "Starting…"
        do {
            try server.start(port: port, onReady: { [weak self] actualPort in
                Task { @MainActor in
                    guard let self, self.apiGeneration == generation else { return }
                    self.apiRunning = true
                    self.apiEndpoint = "http://127.0.0.1:\(actualPort)"
                    self.apiMessage = "Ready for external review."
                }
            }, onFailure: { [weak self] message in
                Task { @MainActor in
                    guard let self, self.apiGeneration == generation else { return }
                    self.stopAPI()
                    self.apiMessage = message
                }
            })
        } catch {
            stopAPI()
            apiMessage = "The local API could not start. Check the port and try again."
        }
    }

    func stopAPI() {
        apiGeneration = UUID()
        apiServer?.stop()
        apiServer = nil
        apiRunning = false
        apiEndpoint = nil
        apiToken = nil
        apiMessage = "Stopped."
    }

    func startScan(_ clipIDs: Set<String>) {
        guard !isScanning, !isLoadingLibrary, persistenceReady else { return }
        guard run?.phase != .paused else {
            errorMessage = "Resume or cancel the saved run before starting a new scan."
            return
        }
        let scope = clips.filter { clipIDs.contains($0.id) }.map(\.id)
        guard !scope.isEmpty else { return }
        let next = SavedRun(id: UUID().uuidString, clipIDs: scope, phase: .running)
        guard persistRun(next) else { return }
        scanProgress = progress(for: next)
        execute(next)
    }

    func resumeScan() {
        guard canResumeScan, persistenceReady, var next = run else { return }
        next.phase = .running
        guard persistRun(next) else { return }
        scanProgress = progress(for: next)
        execute(next)
    }

    func pauseScan() {
        guard isScanning, var next = run, next.phase == .running else { return }
        next.phase = .paused
        stop(next)
    }

    func cancelScan() {
        guard canCancelScan, var next = run else { return }
        next.phase = .cancelled
        stop(next)
    }

    private func stop(_ next: SavedRun) {
        guard persistRun(next) else { return }
        scanProgress?.state = next.phase
        scanProgress?.current = ""
        scanTask?.cancel()
    }

    private func remainingClips(for run: SavedRun) -> [ReviewClip] {
        run.clipIDs.compactMap { id in
            guard !scannedClipIDs.contains(id), run.failures[id] == nil else { return nil }
            return clipByID[id]
        }
    }

    private func progress(for run: SavedRun) -> ScanProgress {
        let completed = run.clipIDs.compactMap { scanByID[$0] }
        let failed = run.failures.keys.filter { !scannedClipIDs.contains($0) }.count
        return ScanProgress(completed: completed.count + failed, total: run.clipIDs.count,
                            failed: failed, appearances: completed.reduce(0) { $0 + $1.result.appearances.count },
                            adopted: completed.count, state: run.phase)
    }

    @discardableResult
    private func persistRun(_ next: SavedRun) -> Bool {
        guard runStateReadable else {
            errorMessage = "The saved run is unreadable. Preserve Run.json outside the library and reopen the app before starting another scan."
            return false
        }
        do {
            try archive.writeRun(next)
            run = next
            return true
        } catch {
            errorMessage = "The run state could not be saved. \(error.localizedDescription)"
            return false
        }
    }

    private func execute(_ active: SavedRun) {
        let archive = archive
        isScanning = true
        scanTask = Task {
            defer {
                isScanning = false
                scanTask = nil
                scanProgress?.current = ""
            }
            scanProgress?.current = "Checking saved results…"
            await revalidateCachedResults(in: active)
            guard !Task.isCancelled, let current = run, current.phase == .running else { return }
            scanProgress = progress(for: current)
            let pending = remainingClips(for: current)
            for clip in pending {
                failedClipIDs.remove(clip.id)
                scanIssues.removeValue(forKey: clip.id)
            }
            await withTaskGroup(of: ScanOutcome.self) { tasks in
                var queue = pending.makeIterator()
                for _ in 0..<min(3, pending.count) {
                    guard let clip = queue.next() else { break }
                    tasks.addTask { await Self.process(clip, archive: archive) }
                }
                for await outcome in tasks {
                    switch outcome {
                    case .complete(let scan, let adopted):
                        installScan(scan)
                        scanProgress?.completed += 1
                        scanProgress?.appearances += scan.result.appearances.count
                        if adopted { scanProgress?.adopted += 1 }
                        if run?.phase == .running {
                            scanProgress?.current = clipByID[scan.result.clipID]?.filename ?? ""
                        }
                    case .failed(let clipID, let message):
                        failedClipIDs.insert(clipID)
                        scanIssues[clipID] = message
                        scanProgress?.completed += 1
                        scanProgress?.failed += 1
                        if var next = run, next.id == active.id {
                            next.failures[clipID] = message
                            if !persistRun(next) {
                                next.phase = .paused
                                run = next
                                scanProgress?.state = .paused
                                tasks.cancelAll()
                                continue
                            }
                        }
                    case .cancelled:
                        break
                    }
                    if !Task.isCancelled, run?.phase == .running, let clip = queue.next() {
                        tasks.addTask { await Self.process(clip, archive: archive) }
                    }
                }
            }
            if var next = run, next.id == active.id, next.phase == .running {
                next.phase = .completed
                if persistRun(next) {
                    scanProgress?.state = .completed
                } else {
                    next.phase = .paused
                    run = next
                    scanProgress?.state = .paused
                }
            }
        }
    }

    private func revalidateCachedResults(in run: SavedRun) async {
        let archive = archive
        let cached = run.clipIDs.compactMap { id in
            scannedClipIDs.contains(id) ? clipByID[id] : nil
        }
        guard !cached.isEmpty else { return }
        let invalid = await withTaskGroup(of: [String: String].self) { tasks in
            tasks.addTask {
                var invalid: [String: String] = [:]
                for clip in cached {
                    if Task.isCancelled { break }
                    do {
                        if try archive.read(clip) == nil {
                            invalid[clip.id] = "The saved scan is missing. Scan this clip again."
                        }
                    } catch {
                        invalid[clip.id] = error.localizedDescription
                    }
                }
                return invalid
            }
            return await tasks.next() ?? [:]
        }
        guard !invalid.isEmpty else { return }
        for (id, message) in invalid {
            scanByID.removeValue(forKey: id)
            scannedClipIDs.remove(id)
            scanIssues[id] = message
        }
        appearances.removeAll { invalid[$0.clipID] != nil }
        if let current = self.run {
            scanProgress = progress(for: current)
        }
    }

    private nonisolated static func process(_ clip: ReviewClip, archive: ScanArchive) async -> ScanOutcome {
        let folder = UUID().uuidString
        let crops = archive.crops.appendingPathComponent(folder, isDirectory: true)
        var ownsCrops = false
        do {
            try Task.checkCancellation()
            if let existing = try? archive.read(clip) {
                return .complete(existing, adopted: true)
            }
            try FileManager.default.createDirectory(at: crops, withIntermediateDirectories: true)
            ownsCrops = true
            let result = try await FaceScanner().scan(clip: clip, cropDirectory: crops, interval: 1)
            try Task.checkCancellation()
            let stored = StoredScan(result: result, cropFolder: folder)
            try archive.write(stored)
            return .complete(stored, adopted: false)
        } catch {
            if ownsCrops { try? FileManager.default.removeItem(at: crops) }
            if Task.isCancelled || error is CancellationError { return .cancelled }
            return .failed(clipID: clip.id, message: error.localizedDescription)
        }
    }
}
