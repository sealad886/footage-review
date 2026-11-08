import Foundation
import XCTest
@testable import FootageReview

final class ReviewSettingsTests: XCTestCase {
    @MainActor
    func testExistingPortMigratesOnceWithOriginalValuePreserved() throws {
        let domain = "local.footage.review.settings-test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set("8877", forKey: "review.api.port")
        let settings = ReviewSettings(defaults: defaults)
        XCTAssertEqual(settings.apiPortValue, 8877)
        XCTAssertEqual(defaults.string(forKey: "review.settings.migration.apiPort.v1"), "8877")
        XCTAssertNil(defaults.object(forKey: "review.api.port"))

        settings.apiPort = 9988
        XCTAssertEqual(ReviewSettings(defaults: defaults).apiPortValue, 9988)
        XCTAssertEqual(defaults.string(forKey: "review.settings.migration.apiPort.v1"), "8877")
    }

    @MainActor
    func testClusteringPreferencesAndExactScopeSurviveReopening() throws {
        let domain = "local.footage.review.settings-test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = ReviewSettings(defaults: defaults)
        settings.repositoryPath = "/tmp/A tool folder"
        settings.similarityThreshold = 0.72
        settings.minimumClusterSize = 5
        settings.scopeDate = "2026-05-25"
        settings.scopeSource = "Blink"
        settings.scopeCamera = "Front door"
        let restored = ReviewSettings(defaults: defaults)
        XCTAssertEqual(restored.repositoryURL.path, "/tmp/A tool folder")
        XCTAssertEqual(restored.similarityThreshold, 0.72)
        XCTAssertEqual(restored.minimumClusterSize, 5)
        XCTAssertEqual(restored.scopeDate, "2026-05-25")
        XCTAssertEqual(restored.scopeSource, "Blink")
        XCTAssertEqual(restored.scopeCamera, "Front door")
    }

    @MainActor
    func testAPISettingsValidatePortAndExactOrigin() throws {
        let domain = "local.footage.review.settings-test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let settings = ReviewSettings(defaults: defaults)
        XCTAssertEqual(settings.apiPortValue, 8765)
        XCTAssertNil(settings.apiOriginValue)
        settings.apiPort = 80
        XCTAssertNil(settings.apiPortValue)
        settings.apiPort = 65535
        XCTAssertEqual(settings.apiPortValue, 65535)
        settings.apiBrowserOrigin = "http://localhost:3000"
        XCTAssertNil(settings.originValidationMessage)
        settings.apiBrowserOrigin = "http://localhost:3000/path"
        XCTAssertNotNil(settings.originValidationMessage)
        settings.apiBrowserOrigin = "http://user:secret@localhost:3000"
        XCTAssertNotNil(settings.originValidationMessage)
    }

    @MainActor
    func testNewSettingsUsePreparedSubmoduleDefault() throws {
        let domain = "local.footage.review.settings-test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let repository = "/tmp/Footage Review/External/cluster-grouper"

        let settings = ReviewSettings(defaults: defaults, repositoryDefault: repository)

        XCTAssertEqual(settings.repositoryURL.path, repository)
        XCTAssertNil(defaults.object(forKey: "review.settings.migration.repositoryPath.v1"))
    }

    @MainActor
    func testFormerDefaultMigratesOnceAndPreservesOriginalValue() throws {
        let domain = "local.footage.review.settings-test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let oldRepository = "~/zzApps/cluster-grouper"
        let repository = "/tmp/Footage Review/External/cluster-grouper"
        defaults.set(oldRepository, forKey: "review.clustering.repositoryPath")

        let settings = ReviewSettings(defaults: defaults, repositoryDefault: repository)

        XCTAssertEqual(settings.repositoryURL.path, repository)
        XCTAssertEqual(defaults.string(forKey: "review.clustering.repositoryPath"), repository)
        XCTAssertEqual(defaults.string(forKey: "review.settings.migration.repositoryPath.v1"), oldRepository)
        // A later explicit choice is not another migration input.
        settings.repositoryPath = oldRepository
        XCTAssertEqual(ReviewSettings(defaults: defaults, repositoryDefault: repository).repositoryPath, oldRepository)
        XCTAssertEqual(defaults.string(forKey: "review.settings.migration.repositoryPath.v1"), oldRepository)
    }

    @MainActor
    func testCustomRepositorySurvivesSubmoduleDefaultMigration() throws {
        let domain = "local.footage.review.settings-test.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let custom = "/tmp/Custom Clustering Checkout"
        defaults.set(custom, forKey: "review.clustering.repositoryPath")

        let settings = ReviewSettings(
            defaults: defaults,
            repositoryDefault: "/tmp/Footage Review/External/cluster-grouper"
        )

        XCTAssertEqual(settings.repositoryPath, custom)
        XCTAssertNil(defaults.object(forKey: "review.settings.migration.repositoryPath.v1"))
        XCTAssertEqual(
            ReviewSettings(defaults: defaults, repositoryDefault: "/tmp/Another Parent/External/cluster-grouper").repositoryPath,
            custom
        )
    }

}
