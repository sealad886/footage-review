import Foundation
import Observation

private struct NativeClusteringRun: Codable {
    var workspaceID: String
    var jobID: String
    var stage: String
    var threshold: Double
    var minimum: Int
    var candidateIDs: [String] = []
}

/// Sequences the existing backend API; it never writes group data directly to the native library.
@Observable
@MainActor
final class ClusteringCoordinator {
    private(set) var statusText = "Ready to cluster detected appearances."
    private(set) var completed = 0
    private(set) var total = 0
    private(set) var errorMessage: String?
    private(set) var isBusy = false
    private(set) var canPause = false
    private(set) var canResume = false
    private(set) var canCancel = false
    private(set) var workspace: ClusterWorkspace?
    private(set) var reviewGroups: [ClusterGroup] = []
    private(set) var preparedImport: ClusterSavedImport?
    private(set) var modelsReady = false
    private(set) var modelMessage = "Checked when clustering starts."
    private(set) var hasSavedRun = false

    private(set) var isBackendRunning = false

    private let backend = ManagedClusteringBackend()
    private var client: ClusteringAPIClient?
    private weak var store: ReviewStore?
    private weak var settings: ReviewSettings?
    private var run: NativeClusteringRun?
    private var activeJob: ClusterJob?
    private var generation = UUID()
    private var shuttingDown = false
    private var stoppingService = false
    private var reviewing = false

    init() {
        backend.onExit = { [weak self] in
            guard let self else { return }
            self.isBackendRunning = false
            if self.isBusy && !self.shuttingDown && !self.stoppingService {
                self.errorMessage = "The clustering backend stopped. Saved work is retained; reconnect to resume."
            }
        }
    }

    private var dataDirectory: URL? { store?.libraryURL.appendingPathComponent("Clustering", isDirectory: true) }
    private var receiptURL: URL? { dataDirectory?.appendingPathComponent("NativeRun.json") }

    /// Restores only non-secret metadata. Opening the app does not launch Python or the API.
    func restore(store: ReviewStore, settings: ReviewSettings) {
        guard !isBusy else { return }
        self.store = store
        self.settings = settings
        do {
            run = try readRun()
            hasSavedRun = run != nil
            canResume = run.map { !["completed", "cancelled", "failed"].contains($0.stage) } ?? false
            if hasSavedRun {
                statusText = canResume ? "A saved clustering run is available to resume." : "Previous clustering results are available."
            }
        } catch { fail(error) }
    }

    func start(store: ReviewStore, settings: ReviewSettings) async {
        guard !isBusy, !shuttingDown else { return }
        self.store = store
        self.settings = settings
        do {
            if run == nil { run = try readRun() }
            if let run {
                if run.stage == "completed" { await openSavedRun(store: store, settings: settings) }
                else if !["failed", "cancelled"].contains(run.stage) {
                    canResume = true
                    await resume()
                } else { await startNewRun(store: store, settings: settings) }
            } else { await startNewRun(store: store, settings: settings) }
        } catch { fail(error) }
    }

    func startNewRun(store: ReviewStore, settings: ReviewSettings) async {
        guard !isBusy, !canResume, !shuttingDown else { return }
        self.store = store
        self.settings = settings
        let operation = begin()
        activeJob = nil
        run = nil
        defer { finish(operation) }
        do {
            guard !store.isLoadingLibrary, !store.isImporting, !store.isScanning else {
                throw ClusteringFailure("Wait for library loading, importing and scanning to finish before clustering.")
            }
            guard !store.appearances.isEmpty else { throw ClusteringFailure("Scan clips to detect appearances before clustering.") }
            try validate(settings)
            let threshold = settings.similarityThreshold
            let minimum = settings.minimumClusterSize
            var exportBody: [String: ClusterJSON] = [:]
            if !settings.scopeDate.isEmpty { exportBody["date"] = .string(settings.scopeDate) }
            if !settings.scopeSource.isEmpty { exportBody["source"] = .string(settings.scopeSource) }
            if !settings.scopeCamera.isEmpty { exportBody["camera"] = .string(settings.scopeCamera) }
            try await ensureServices(connect: true, operation: operation)
            guard let client else { throw ClusteringFailure("The clustering backend is unavailable.") }
            guard modelsReady else { throw ClusteringFailure(modelMessage) }
            try check(operation)
            statusText = "Exporting detected appearances…"
            let name = "Footage Review · \(Date.now.formatted(date: .abbreviated, time: .standard))"
            exportBody["name"] = .string(name)
            let created: ClusterExportCreated = try await client.request("POST", "/api/exports", body: .object(exportBody))
            try check(operation)
            run = NativeClusteringRun(workspaceID: created.workspaceID, jobID: created.jobID, stage: "export",
                                      threshold: threshold, minimum: minimum)
            workspace = nil
            reviewGroups = []
            preparedImport = nil
            hasSavedRun = true
            try persistRun()
            try await drive(operation)
        } catch { handle(error, operation: operation) }
    }

    func openSavedRun(store: ReviewStore, settings: ReviewSettings) async {
        guard !isBusy, !shuttingDown else { return }
        self.store = store
        self.settings = settings
        let operation = begin()
        defer { finish(operation) }
        do {
            if run == nil { run = try readRun() }
            guard let run else { throw ClusteringFailure("There is no saved clustering run for this library.") }
            try await ensureServices(connect: false, operation: operation)
            try await refreshWorkspace(operation)
            try check(operation)
            if run.stage == "completed" {
                statusText = "\(reviewGroups.count.formatted()) suggested groups available for review."
            } else if let saved = workspace?.jobs.first(where: { $0.id == run.jobID }) {
                publish(saved)
            }
        } catch { handle(error, operation: operation) }
    }

    func pause() async {
        guard canPause, let activeJob, let client, !reviewing else { return }
        do {
            let paused = try await client.control(activeJob.id, action: "pause")
            generation = UUID()
            publish(paused)
            isBusy = false
            try persistRun()
        } catch { fail(error) }
    }

    func resume() async {
        guard !isBusy, canResume, !shuttingDown, let store, settings != nil else { return }
        let operation = begin()
        defer { finish(operation) }
        do {
            guard !store.isLoadingLibrary, !store.isImporting, !store.isScanning else {
                throw ClusteringFailure("Wait for the library to finish loading or scanning before resuming.")
            }
            if run == nil { run = try readRun() }
            guard let run else { throw ClusteringFailure("There is no saved clustering job to resume.") }
            try await ensureServices(connect: true, operation: operation)
            guard let client else { throw ClusteringFailure("The clustering backend is unavailable.") }
            let saved = try await client.job(run.jobID)
            try check(operation)
            if saved.status == "paused" {
                _ = try await client.control(saved.id, action: "resume")
            } else if ["cancelled", "failed"].contains(saved.status) {
                publish(saved)
                self.run?.stage = saved.status
                try persistRun()
                throw ClusteringFailure("This saved job is terminal. Start a new clustering run after reviewing its error.")
            }
            try check(operation)
            canResume = false
            try await drive(operation, resumeAdoptedCluster: true)
        } catch { handle(error, operation: operation) }
    }

    func cancel() async {
        guard canCancel, !reviewing, !shuttingDown else { return }
        do {
            if let activeJob, let client, activeJob.isActive {
                let cancelled = try await client.control(activeJob.id, action: "cancel")
                generation = UUID()
                publish(cancelled)
                run?.stage = "cancelled"
                try persistRun()
            } else {
                generation = UUID()
                await backend.stop()
                isBackendRunning = backend.isRunning
                client?.invalidate()
                client = nil
                statusText = "Clustering cancelled. Saved work is retained."
                run?.stage = "cancelled"
                try persistRun()
            }
            canPause = false
            canResume = false
            canCancel = false
            isBusy = false
            errorMessage = nil
        } catch { fail(error) }
    }

    func saveReview(group: ClusterGroup, name: String, note: String, appearanceIDs: [String]) async {
        guard !isBusy, !shuttingDown, let client, let workspace else { return }
        let operation = begin(review: true)
        defer { finish(operation) }
        do {
            guard let store, !store.isLoadingLibrary, !store.isImporting, !store.isScanning else {
                throw ClusteringFailure("Wait for the library to finish loading before approving groups.")
            }
            let currentIDs = Set(store.appearances.map(\.id))
            guard Set(appearanceIDs).isSubset(of: currentIDs) else {
                throw ClusteringFailure("Some appearances are no longer available in the current library. Restore the source or start a fresh clustering run.")
            }
            let _: ClusterGroup = try await client.request("PATCH", "/api/workspaces/\(ClusteringAPIClient.segment(workspace.id))/groups/\(ClusteringAPIClient.segment(group.id))", body: .object([
                "name": .string(name), "note": .string(note),
                "appearance_ids": .array(appearanceIDs.map(ClusterJSON.string)), "reviewed": .bool(true),
            ]))
            try check(operation)
            try await refreshWorkspace(operation)
            statusText = "Group approved locally. Preview an import when review is complete."
        } catch { handle(error, operation: operation) }
    }

    func unapproveReview(group: ClusterGroup) async {
        guard !isBusy, !shuttingDown, group.reviewed, let client, let workspace else { return }
        let operation = begin(review: true)
        defer { finish(operation) }
        do {
            let _: ClusterGroup = try await client.request("PATCH", "/api/workspaces/\(ClusteringAPIClient.segment(workspace.id))/groups/\(ClusteringAPIClient.segment(group.id))", body: .object(["reviewed": .bool(false)]))
            try check(operation)
            try await refreshWorkspace(operation)
            statusText = "Group marked unreviewed. It will be excluded from new imports."
        } catch { handle(error, operation: operation) }
    }

    func prepareImport(reviewer: String) async {
        guard !isBusy, !shuttingDown, let workspace else { return }
        let operation = begin(review: true)
        defer { finish(operation) }
        do {
            try await ensureServices(connect: true, operation: operation)
            guard let client else { throw ClusteringFailure("The clustering backend is unavailable.") }
            preparedImport = try await client.request("POST", "/api/workspaces/\(ClusteringAPIClient.segment(workspace.id))/imports", body: .object(["reviewer": .string(reviewer)]))
            try check(operation)
            try await refreshWorkspace(operation)
            statusText = "Import saved. Inspect it before submitting."
        } catch { handle(error, operation: operation) }
    }

    func submitPreparedImport() async {
        guard !isBusy, !shuttingDown, let workspace, let preparedImport,
              ["prepared", "uncertain"].contains(preparedImport.status) else { return }
        let operation = begin(review: true)
        defer { finish(operation) }
        do {
            try await ensureServices(connect: true, operation: operation)
            guard let client else { throw ClusteringFailure("The clustering backend is unavailable.") }
            self.preparedImport = try await client.request("POST", "/api/workspaces/\(ClusteringAPIClient.segment(workspace.id))/imports/\(ClusteringAPIClient.segment(preparedImport.id))/submit")
            try check(operation)
            try await refreshWorkspace(operation)
            statusText = self.preparedImport?.status == "submitted" ? "Reviewed groups imported into Footage Review." : "Import needs attention. Keep and retry the saved request when appropriate."
        } catch { handle(error, operation: operation) }
    }

    func dismissPreparedImport() { preparedImport = nil }

    /// Settings stop is reusable; only application quit permanently closes this coordinator.
    func stopService() async {
        guard !shuttingDown, !stoppingService else { return }
        stoppingService = true
        defer { stoppingService = false }
        await closeOwnedService()
        modelsReady = false
        modelMessage = "Checked when the clustering backend starts."
        if backend.isRunning {
            errorMessage = "The clustering backend is still stopping. Try again shortly."
            statusText = "Waiting for the owned clustering backend to stop."
        } else {
            errorMessage = nil
            statusText = "Clustering backend stopped. Saved work remains available."
        }
    }

    func shutdown() async {
        guard !shuttingDown else { return }
        shuttingDown = true
        await closeOwnedService()
    }

    private func closeOwnedService() async {
        generation = UUID()
        isBusy = true
        if let activeJob, let client, ["queued", "running"].contains(activeJob.status) {
            if let paused = try? await client.control(activeJob.id, action: "pause") {
                publish(paused)
                try? persistRun()
            }
        }
        await backend.stop()
        isBackendRunning = backend.isRunning
        client?.invalidate()
        client = nil
        isBusy = false
        reviewing = false
        canPause = false
        canCancel = false
        canResume = run.map { !["completed", "cancelled", "failed"].contains($0.stage) } ?? false
    }

    private func begin(review: Bool = false) -> UUID {
        generation = UUID()
        isBusy = true
        reviewing = review
        errorMessage = nil
        if !review { canCancel = true }
        return generation
    }

    private func finish(_ operation: UUID) {
        guard generation == operation else { return }
        isBusy = false
        reviewing = false
        if activeJob?.status != "paused" { canCancel = false }
    }

    private func check(_ operation: UUID) throws {
        guard operation == generation, !shuttingDown else { throw CancellationError() }
        try Task.checkCancellation()
    }

    private func validate(_ settings: ReviewSettings) throws {
        guard (1024...65535).contains(settings.apiPort), settings.similarityThreshold.isFinite,
              (0...1).contains(settings.similarityThreshold), (2...100).contains(settings.minimumClusterSize) else {
            throw ClusteringFailure("Check the API port, similarity threshold and minimum group size in Settings.")
        }
    }

    private func ensureServices(connect: Bool, operation: UUID) async throws {
        guard let store, let settings, let dataDirectory else { throw ClusteringFailure("The review library is unavailable.") }
        try validate(settings)
        if connect {
            statusText = "Starting Footage Review's integration API…"
            if !store.apiRunning, store.apiToken == nil {
                let origin = settings.apiBrowserOrigin.trimmingCharacters(in: .whitespacesAndNewlines)
                store.startAPI(port: UInt16(settings.apiPort), allowedOrigin: origin.isEmpty ? nil : origin)
            }
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            while !store.apiRunning {
                try check(operation)
                if store.apiToken == nil { throw ClusteringFailure(store.apiMessage ?? "Footage Review's integration API could not start.") }
                guard ContinuousClock.now < deadline else { throw ClusteringFailure("Footage Review's API took too long to start. Check its port in Settings.") }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        statusText = "Starting the clustering backend…"
        let root = settings.repositoryURL
        let connection = try await backend.start(repository: root, dataDirectory: dataDirectory)
        isBackendRunning = backend.isRunning
        try check(operation)
        if client?.endpoint != connection.endpoint {
            client?.invalidate()
            client = try ClusteringAPIClient(endpoint: connection.endpoint)
        }
        guard let client else { throw ClusteringFailure("The clustering backend is unavailable.") }
        let status = try await client.bootstrap(token: connection.bootstrapToken)
        try check(operation)
        modelsReady = status.modelsReady
        modelMessage = status.modelMessage
        guard connect else { return }
        guard let endpoint = store.apiEndpoint, let token = store.apiToken else { throw ClusteringFailure("Footage Review's API is not ready.") }
        _ = try await client.connect(endpoint: endpoint, token: token)
        try check(operation)
    }

    private func drive(_ operation: UUID, resumeAdoptedCluster: Bool = false) async throws {
        guard let client else { throw ClusteringFailure("The clustering backend is unavailable.") }
        while let saved = run {
            try check(operation)
            let job = try await client.job(saved.jobID)
            try check(operation)
            publish(job)
            switch job.status {
            case "completed":
                try await refreshWorkspace(operation)
                if job.kind == "export" {
                    // A prior POST may have succeeded before its reply/receipt was saved.
                    // Adopt durable work before deciding whether any new job is needed.
                    if let existing = workspace?.jobs.last(where: { $0.kind == "cluster" }) {
                        run?.jobID = existing.id
                        run?.stage = "cluster"
                        try persistRun()
                        if existing.status == "paused", resumeAdoptedCluster {
                            _ = try await client.control(existing.id, action: "resume")
                            try check(operation)
                        }
                        continue
                    }
                    statusText = "Starting local face clustering…"
                    let created: ClusterJobCreated = try await client.request("POST", "/api/workspaces/\(ClusteringAPIClient.segment(saved.workspaceID))/cluster", body: .object([
                        "threshold": .number(saved.threshold), "min_cluster_size": .number(Double(saved.minimum)),
                    ]))
                    try check(operation)
                    run?.jobID = created.jobID
                    run?.stage = "cluster"
                    try persistRun()
                    continue
                }
                run?.stage = "completed"
                run?.candidateIDs = workspace?.groups.filter { $0.origin != "existing" }.map(\.id) ?? []
                updateReviewGroups()
                try persistRun()
                statusText = reviewGroups.isEmpty ? "Clustering finished with no new suggestions. Review crop quality or try a different threshold." : "\(reviewGroups.count.formatted()) suggested groups ready for review."
                canPause = false
                canResume = false
                canCancel = false
                return
            case "paused":
                try persistRun()
                return
            case "failed", "cancelled":
                run?.stage = job.status
                try persistRun()
                try await refreshWorkspace(operation)
                if job.status == "failed" { throw ClusteringFailure(job.error ?? "The clustering job failed.") }
                return
            default:
                try await Task.sleep(for: .milliseconds(400))
            }
        }
    }

    private func refreshWorkspace(_ operation: UUID) async throws {
        guard let client, let run else { return }
        let value = try await client.workspace(run.workspaceID)
        try check(operation)
        workspace = value
        updateReviewGroups()
        if preparedImport == nil { preparedImport = value.imports.first { ["prepared", "uncertain", "rejected"].contains($0.status) } }
    }

    private func updateReviewGroups() {
        let ids = Set(run?.candidateIDs ?? [])
        reviewGroups = workspace?.groups.filter { ids.contains($0.id) || $0.origin != "existing" } ?? []
    }

    private func publish(_ job: ClusterJob) {
        activeJob = job
        completed = job.completed
        total = job.total
        statusText = job.error ?? job.phase
        canPause = ["queued", "running"].contains(job.status)
        canResume = job.status == "paused"
        canCancel = job.isActive
    }

    private func handle(_ error: any Error, operation: UUID) {
        guard operation == generation, !(error is CancellationError) else { return }
        if activeJob?.isActive == true || run?.stage == "export" || run?.stage == "cluster" {
            canPause = false
            canResume = true
            canCancel = true
        }
        fail(error)
    }

    private func fail(_ error: any Error) {
        errorMessage = (error as? LocalizedError)?.errorDescription ?? "The clustering operation could not finish. Retry after checking Settings."
        statusText = "Clustering needs attention."
    }

    private func readRun() throws -> NativeClusteringRun? {
        guard let receiptURL, FileManager.default.fileExists(atPath: receiptURL.path) else { return nil }
        let data = try Data(contentsOf: receiptURL)
        guard data.count <= 64 * 1024 else { throw ClusteringFailure("Saved clustering state is too large. Preserve NativeRun.json and check the library.") }
        do { return try JSONDecoder().decode(NativeClusteringRun.self, from: data) }
        catch { throw ClusteringFailure("Saved clustering state could not be read. Preserve NativeRun.json before starting a fresh run.") }
    }

    private func persistRun() throws {
        guard let run, let dataDirectory, let receiptURL else { return }
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(run)
        try data.write(to: receiptURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: receiptURL.path)
    }
}
