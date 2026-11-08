import CryptoKit
import Foundation

struct ManagedClusteringConnection: Sendable {
    let endpoint: URL
    let bootstrapToken: String
}

private struct ClusteringReadiness: Decodable, Sendable {
    let `protocol`: Int
    let instanceID: String
    let endpoint: String
    enum CodingKeys: String, CodingKey { case `protocol`, endpoint; case instanceID = "instance_id" }
}

private actor ClusteringReadinessMailbox {
    private var bytes = Data()
    private var readiness: ClusteringReadiness?
    private var failed = false

    func receive(_ data: Data) {
        guard readiness == nil, !failed else { return }
        guard !data.isEmpty, bytes.count + data.count <= 8192 else { failed = true; return }
        bytes.append(data)
        if let newline = bytes.firstIndex(of: 10) {
            readiness = try? JSONDecoder().decode(ClusteringReadiness.self, from: bytes.prefix(upTo: newline))
            if readiness == nil { failed = true }
        }
    }

    func result() throws -> ClusteringReadiness? {
        if failed { throw ClusteringFailure("The clustering backend did not complete its startup handshake. Check that the selected repository is prepared.") }
        return readiness
    }
}

/// Owns exactly one child Process. No PID adoption and no shell invocation.
@MainActor
final class ManagedClusteringBackend {
    var onExit: (@MainActor @Sendable () -> Void)?
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var connection: ManagedClusteringConnection?
    private var repository: URL?
    private var dataDirectory: URL?

    var isRunning: Bool { process?.isRunning == true }

    func start(repository: URL, dataDirectory: URL) async throws -> ManagedClusteringConnection {
        if isRunning, self.repository == repository, self.dataDirectory == dataDirectory, let connection {
            return connection
        }
        await stop()
        guard !isRunning else { throw ClusteringFailure("The previous clustering backend is still shutting down. Try again shortly.") }
        let backend = repository.appendingPathComponent("backend", isDirectory: true)
        let python = backend.appendingPathComponent(".venv/bin/python")
        guard FileManager.default.isExecutableFile(atPath: python.path),
              FileManager.default.fileExists(atPath: backend.appendingPathComponent("app/managed.py").path) else {
            throw ClusteringFailure("Prepare Cluster Grouper in the selected folder with make setup and make models, then try again.")
        }
        try FileManager.default.createDirectory(at: dataDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let child = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        let mailbox = ClusteringReadinessMailbox()
        let instance = UUID().uuidString
        let token = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0).base64EncodedString() }
        child.executableURL = python
        child.arguments = ["-m", "app.managed"]
        child.currentDirectoryURL = backend
        var environment = ProcessInfo.processInfo.environment
        // Keep the repository's model selection canonical; native state is private to this library.
        environment.removeValue(forKey: "CLUSTER_DATA_DIR")
        environment.removeValue(forKey: "CLUSTER_MODEL_DIR")
        environment.removeValue(forKey: "PYTHONPATH")
        environment.removeValue(forKey: "PYTHONHOME")
        environment["PYTHONNOUSERSITE"] = "1"
        environment["PYTHONUNBUFFERED"] = "1"
        child.environment = environment
        child.standardInput = stdin
        child.standardOutput = stdout
        child.standardError = FileHandle.nullDevice
        child.terminationHandler = { [weak self] exited in
            let pid = exited.processIdentifier
            Task { @MainActor in
                guard let self, self.process?.processIdentifier == pid,
                      self.process?.isRunning != true else { return }
                self.onExit?()
            }
        }
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            Task { await mailbox.receive(data) }
        }
        do {
            try child.run()
            try stdin.fileHandleForReading.close()
            try stdout.fileHandleForWriting.close()
            process = child
            input = stdin.fileHandleForWriting
            output = stdout.fileHandleForReading
            self.repository = repository
            self.dataDirectory = dataDirectory
            let payload = ClusterJSON.object([
                "protocol": .number(1), "instance_id": .string(instance),
                "bootstrap_token": .string(token), "data_dir": .string(dataDirectory.path),
            ])
            var data = try JSONEncoder().encode(payload)
            data.append(10)
            try input?.write(contentsOf: data)
            let deadline = ContinuousClock.now.advanced(by: .seconds(20))
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                guard child.isRunning else {
                    throw ClusteringFailure("The clustering backend exited during startup. Check its dependencies and model setup in Settings.")
                }
                if let ready = try await mailbox.result() {
                    guard ready.protocol == 1, ready.instanceID == instance,
                          let endpoint = URL(string: ready.endpoint), ClusteringAPIClient.validEndpoint(endpoint) else {
                        throw ClusteringFailure("The clustering backend returned an invalid startup identity.")
                    }
                    let connection = ManagedClusteringConnection(endpoint: endpoint, bootstrapToken: token)
                    self.connection = connection
                    return connection
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            throw ClusteringFailure("The clustering backend took too long to start. Check its setup and try again.")
        } catch {
            await stop()
            throw error
        }
    }

    private static func shutdownDelay() async {
        await Task.detached { try? await Task.sleep(for: .milliseconds(50)) }.value
    }

    func stop() async {
        // EOF is the managed protocol's graceful shutdown signal. The worker checkpoints first.
        try? input?.close()
        input = nil
        if let process {
            let deadline = ContinuousClock.now.advanced(by: .seconds(12))
            while process.isRunning && ContinuousClock.now < deadline {
                await Self.shutdownDelay()
            }
            if process.isRunning {
                process.terminate()
                let terminationDeadline = ContinuousClock.now.advanced(by: .seconds(2))
                while process.isRunning && ContinuousClock.now < terminationDeadline {
                    await Self.shutdownDelay()
                }
            }
        }
        output?.readabilityHandler = nil
        try? output?.close()
        output = nil
        if process?.isRunning != true { process = nil }
        connection = nil
        repository = nil
        dataDirectory = nil
    }
}
