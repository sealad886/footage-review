import Darwin
import Foundation
import XCTest
@testable import FootageReview

final class NativeClusteringRoundTripTests: XCTestCase {
    /// Opt-in actual-model test. Inputs are public sample crops, never private footage.
    @MainActor
    func testOneClickRunsOwnedBackendAndImportsOnlyReviewedGroups() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let repository = environment["CLUSTER_NATIVE_E2E_REPOSITORY"],
              let assetPath = environment["CLUSTER_NATIVE_E2E_ASSETS"] else {
            throw XCTSkip("Set CLUSTER_NATIVE_E2E_REPOSITORY and CLUSTER_NATIVE_E2E_ASSETS for the actual-model round trip.")
        }
        let assets = URL(fileURLWithPath: assetPath, isDirectory: true)
        let library = FileManager.default.temporaryDirectory
            .appendingPathComponent("footage-native-roundtrip-" + UUID().uuidString, isDirectory: true)
        try Self.writeFixture(library: library, assets: assets)
        if let target = environment["CLUSTER_NATIVE_E2E_GUI_FIXTURE"] {
            try Self.writeFixture(library: URL(fileURLWithPath: target, isDirectory: true), assets: assets)
        }
        let suite = "local.footage.review.roundtrip." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: library)
        }
        let settings = ReviewSettings(defaults: defaults)
        settings.repositoryPath = repository
        settings.apiPort = try Self.availablePort()
        settings.similarityThreshold = 0.55
        settings.minimumClusterSize = 2
        let store = ReviewStore(libraryURL: library)
        let coordinator = ClusteringCoordinator()
        do {
            try await Self.eventually { !store.isLoadingLibrary && store.appearances.count == 2 }
            XCTAssertFalse(store.apiRunning)
            await coordinator.start(store: store, settings: settings)
            XCTAssertNil(coordinator.errorMessage, coordinator.errorMessage ?? "")
            XCTAssertTrue(store.apiRunning, "The native action must start its integration API")
            XCTAssertTrue(coordinator.isBackendRunning, "The native action must own a live tool backend")
            let workspace = try XCTUnwrap(coordinator.workspace)
            XCTAssertTrue(workspace.exportComplete)
            XCTAssertEqual(workspace.appearanceCount, 2)
            XCTAssertTrue(workspace.jobs.contains { $0.kind == "cluster" && $0.status == "completed" })
            let candidate = try XCTUnwrap(coordinator.reviewGroups.first)
            XCTAssertEqual(Set(candidate.appearanceIDs), Set(store.appearances.map(\.id)))
            XCTAssertFalse(candidate.reviewed)
            XCTAssertTrue(store.groups.isEmpty, "Clustering must not silently import suggestions")

            await coordinator.saveReview(group: candidate, name: "Reviewed public-sample fixture",
                                         note: "Actual model validation; not private footage.",
                                         appearanceIDs: candidate.appearanceIDs)
            XCTAssertNil(coordinator.errorMessage, coordinator.errorMessage ?? "")
            await coordinator.prepareImport(reviewer: "Native integration test")
            XCTAssertNil(coordinator.errorMessage, coordinator.errorMessage ?? "")
            let saved = try XCTUnwrap(coordinator.preparedImport)
            XCTAssertEqual(saved.status, "prepared")
            XCTAssertTrue(store.groups.isEmpty, "Preparing a request must not apply it")
            await coordinator.submitPreparedImport()
            XCTAssertNil(coordinator.errorMessage, coordinator.errorMessage ?? "")
            XCTAssertEqual(coordinator.preparedImport?.id, saved.id)
            XCTAssertEqual(coordinator.preparedImport?.status, "submitted")
            XCTAssertEqual(store.groups.count, 1)
            XCTAssertEqual(store.groups.first.flatMap { UUID(uuidString: $0.id) }, UUID(uuidString: candidate.id))
            XCTAssertEqual(store.groups.first?.appearanceIDs, Set(candidate.appearanceIDs))
            await coordinator.shutdown()
            XCTAssertFalse(coordinator.isBackendRunning, "Quit cleanup must stop the owned backend")
            store.stopAPI()
        } catch {
            await coordinator.shutdown()
            store.stopAPI()
            throw error
        }
    }

    @MainActor
    private static func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<300 {
            if condition() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        throw ClusteringFailure("Fixture library did not restore its two detections.")
    }

    private struct FixtureLibrary: Encodable {
        let clips: [ReviewClip]
        let groups: [ReviewGroup] = []
    }

    private static func writeFixture(library: URL, assets: URL) throws {
        let stateURL = library.appendingPathComponent("Library.json")
        guard !FileManager.default.fileExists(atPath: stateURL.path) else {
            throw ClusteringFailure("Refusing to overwrite an existing fixture library.")
        }
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let source = assets.appendingPathComponent("source.mp4")
        let clip = ReviewClip(path: source.path, source: "Public sample", camera: "Validation",
                              date: "2026-11-08", clock: "12:00:00")
        let folder = UUID().uuidString
        let cropFolder = library.appendingPathComponent("Crops").appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: cropFolder, withIntermediateDirectories: true)
        var appearances: [Appearance] = []
        for index in 1...2 {
            let name = "crop-\(index).jpg"
            try FileManager.default.copyItem(at: assets.appendingPathComponent(name), to: cropFolder.appendingPathComponent(name))
            appearances.append(Appearance(id: "public-fixture-\(index)", clipID: clip.id,
                                          seconds: Double(index), confidence: 0.98, cropFile: name))
        }
        let result = ScanResult(clipID: clip.id, stamp: try FileStamp.read(source), duration: 6,
                                sampledFrames: 2, appearances: appearances, warnings: [])
        try ScanArchive(library: library).write(StoredScan(result: result, cropFolder: folder))
        try JSONEncoder().encode(FixtureLibrary(clips: [clip])).write(to: stateURL, options: .atomic)
    }

    private static func availablePort() throws -> Int {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ClusteringFailure("Cannot allocate a test listener") }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw ClusteringFailure("Cannot bind a test listener") }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let read = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &size) }
        }
        guard read == 0 else { throw ClusteringFailure("Cannot read a test listener") }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
