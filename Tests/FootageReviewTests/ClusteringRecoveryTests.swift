import Foundation
import XCTest
@testable import FootageReview

final class ClusteringRecoveryTests: XCTestCase {
    @MainActor
    func testResumeAdoptsPausedClusterAfterUncertainHandoff() async throws {
        let fixture = try await RecoveryFixture.make()
        let coordinator = ClusteringCoordinator()
        do {
            coordinator.restore(store: fixture.store, settings: fixture.settings)
            XCTAssertTrue(coordinator.canResume)
            await coordinator.resume()
            XCTAssertNil(coordinator.errorMessage, coordinator.errorMessage ?? "")
            let workspace = try XCTUnwrap(coordinator.workspace)
            let clusters = workspace.jobs.filter { $0.kind == "cluster" }
            XCTAssertEqual(clusters.count, 1, "Recovery must adopt the existing cluster, not create another job")
            XCTAssertEqual(clusters.first?.id, fixture.clusterID)
            XCTAssertEqual(clusters.first?.status, "completed", "Explicit Resume must resume the adopted paused job")
            let metadata = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.receipt)) as? [String: Any]
            XCTAssertEqual(metadata?["jobID"] as? String, fixture.clusterID)
            XCTAssertEqual(metadata?["stage"] as? String, "completed")
            await coordinator.shutdown()
            fixture.clean()
        } catch {
            await coordinator.shutdown()
            fixture.clean()
            throw error
        }
    }

    @MainActor
    func testSettingsStopAllowsReopeningOwnedBackend() async throws {
        let fixture = try await RecoveryFixture.make()
        let coordinator = ClusteringCoordinator()
        coordinator.restore(store: fixture.store, settings: fixture.settings)
        await coordinator.openSavedRun(store: fixture.store, settings: fixture.settings)
        XCTAssertNil(coordinator.errorMessage, coordinator.errorMessage ?? "")
        XCTAssertTrue(coordinator.isBackendRunning)
        await coordinator.stopService()
        XCTAssertFalse(coordinator.isBackendRunning)
        XCTAssertFalse(coordinator.isBusy)
        XCTAssertTrue(coordinator.hasSavedRun)
        await coordinator.openSavedRun(store: fixture.store, settings: fixture.settings)
        XCTAssertNil(coordinator.errorMessage, coordinator.errorMessage ?? "")
        XCTAssertTrue(coordinator.isBackendRunning, "Settings stop must not permanently disable later starts")
        XCTAssertEqual(coordinator.workspace?.id, fixture.workspaceID)
        await coordinator.shutdown()
        fixture.clean()
    }
}

@MainActor
private struct RecoveryFixture {
    let library: URL
    let store: ReviewStore
    let settings: ReviewSettings
    let suite: String
    let workspaceID: String
    let clusterID: String
    let receipt: URL

    static func make() async throws -> Self {
        guard let path = ProcessInfo.processInfo.environment["CLUSTER_NATIVE_E2E_REPOSITORY"] else {
            throw XCTSkip("Set CLUSTER_NATIVE_E2E_REPOSITORY to exercise actual managed-process recovery.")
        }
        let repository = URL(fileURLWithPath: path, isDirectory: true)
        let library = FileManager.default.temporaryDirectory.appendingPathComponent("native-cluster-recovery-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let store = ReviewStore(libraryURL: library)
        let snapshot = try store.apiSnapshot()
        let suite = "local.footage.review.recovery." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let settings = ReviewSettings(defaults: defaults)
        settings.repositoryPath = repository.path
        let dataDirectory = library.appendingPathComponent("Clustering", isDirectory: true)
        let setup = ManagedClusteringBackend()
        do {
            _ = try await setup.start(repository: repository, dataDirectory: dataDirectory)
            await setup.stop()
        } catch {
            await setup.stop()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: library)
            throw error
        }
        let workspaceID = UUID().uuidString
        let exportID = UUID().uuidString
        let clusterID = UUID().uuidString
        // Seed a durable backend state that can occur when the cluster POST reply is lost.
        // This only writes the temporary fixture database, never an operator's library.
        let script = #"""
import sys
from pathlib import Path
from app.config import Settings
from app.database import make_database, Workspace, Job
engine,sessions=make_database(Settings(data_dir=Path(sys.argv[1])))
with sessions.begin() as db:
    db.add(Workspace(id=sys.argv[2],name='Recovery fixture',library_id=sys.argv[3],base_revision=int(sys.argv[6]),export_complete=True))
    db.flush()
    db.add(Job(id=sys.argv[4],workspace_id=sys.argv[2],kind='export',status='completed',phase='Export complete',completed=0,total=0,checkpoint={}))
    db.add(Job(id=sys.argv[5],workspace_id=sys.argv[2],kind='cluster',status='paused',phase='Interrupted after handoff',completed=0,total=0,checkpoint={'threshold':0.55,'min_cluster_size':2}))
engine.dispose()
"""#
        let process = Process()
        process.executableURL = repository.appendingPathComponent("backend/.venv/bin/python")
        process.currentDirectoryURL = repository.appendingPathComponent("backend")
        process.arguments = ["-c", script, dataDirectory.path, workspaceID, snapshot.libraryID, exportID, clusterID, String(snapshot.revision)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw ClusteringFailure("Could not seed the temporary recovery fixture") }
        let receipt = dataDirectory.appendingPathComponent("NativeRun.json")
        let metadata: [String: Any] = ["workspaceID":workspaceID,"jobID":exportID,"stage":"export","threshold":0.55,"minimum":2,"candidateIDs":[]]
        try JSONSerialization.data(withJSONObject: metadata).write(to: receipt, options: .atomic)
        // Native API startup is still driven by the coordinator in the Resume test.
        settings.apiPort = try availablePort()
        return Self(library: library, store: store, settings: settings, suite: suite,
                    workspaceID: workspaceID, clusterID: clusterID, receipt: receipt)
    }

    func clean() {
        store.stopAPI()
        UserDefaults.standard.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: library)
    }

    private static func availablePort() throws -> Int {
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ClusteringFailure("Cannot create a test listener") }
        defer { Darwin.close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { throw ClusteringFailure("Cannot bind a test listener") }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let value = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &size) }
        }
        guard value == 0 else { throw ClusteringFailure("Cannot read a test listener") }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
