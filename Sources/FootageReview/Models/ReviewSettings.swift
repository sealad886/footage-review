import Foundation
import Observation

enum ReviewSettingsTab: Hashable {
    case general
    case clustering
    case integrations
}

@MainActor
@Observable
final class ReviewSettings {
    @ObservationIgnored private let defaults: UserDefaults

    var repositoryPath: String { didSet { defaults.set(repositoryPath, forKey: Key.repository) } }
    var apiPort: Int { didSet { defaults.set(apiPort, forKey: Key.port) } }
    var apiBrowserOrigin: String { didSet { defaults.set(apiBrowserOrigin, forKey: Key.origin) } }
    var similarityThreshold: Double { didSet { defaults.set(similarityThreshold, forKey: Key.threshold) } }
    var minimumClusterSize: Int { didSet { defaults.set(minimumClusterSize, forKey: Key.minimum) } }
    var scopeDate: String { didSet { defaults.set(scopeDate, forKey: Key.scopeDate) } }
    var scopeSource: String { didSet { defaults.set(scopeSource, forKey: Key.scopeSource) } }
    var scopeCamera: String { didSet { defaults.set(scopeCamera, forKey: Key.scopeCamera) } }
    var selectedTab = ReviewSettingsTab.general

    private enum Key {
        static let repository = "review.clustering.repositoryPath"
        static let repositoryBackup = "review.settings.migration.repositoryPath.v1"
        static let repositoryMigration = "review.settings.migration.repositoryPath.completed.v1"
        static let port = "review.settings.apiPort"
        static let oldPort = "review.api.port"
        static let oldPortBackup = "review.settings.migration.apiPort.v1"
        static let origin = "review.api.browserOrigin"
        static let threshold = "review.clustering.similarityThreshold"
        static let minimum = "review.clustering.minimumClusterSize"
        static let scopeDate = "review.clustering.scope.date"
        static let scopeSource = "review.clustering.scope.source"
        static let scopeCamera = "review.clustering.scope.camera"
    }

    init(defaults: UserDefaults = .standard, repositoryDefault: String? = nil) {
        self.defaults = defaults
        let newDefault = repositoryDefault ?? Self.defaultRepositoryPath
        var savedRepository = defaults.string(forKey: Key.repository)
        if !defaults.bool(forKey: Key.repositoryMigration) {
            let formerDefault = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("zzApps/cluster-grouper").standardizedFileURL.path
            if let saved = savedRepository,
               Self.normalizedPath(saved) == formerDefault,
               Self.normalizedPath(newDefault) != formerDefault {
                if defaults.object(forKey: Key.repositoryBackup) == nil {
                    defaults.set(saved, forKey: Key.repositoryBackup)
                }
                savedRepository = newDefault
                defaults.set(newDefault, forKey: Key.repository)
            }
            defaults.set(true, forKey: Key.repositoryMigration)
        }
        repositoryPath = savedRepository ?? newDefault
        let oldPort = defaults.object(forKey: Key.oldPort)
        let migratedPort = (oldPort as? String).flatMap(Int.init) ?? oldPort as? Int
        let savedPort = defaults.object(forKey: Key.port) as? Int
        let port = savedPort ?? migratedPort ?? 8765
        apiPort = (1024...65535).contains(port) ? port : 8765
        apiBrowserOrigin = defaults.string(forKey: Key.origin) ?? ""
        let savedThreshold = defaults.object(forKey: Key.threshold) as? Double ?? 0.55
        similarityThreshold = savedThreshold.isFinite && (0...1).contains(savedThreshold)
            ? savedThreshold : 0.55
        let savedMinimum = defaults.object(forKey: Key.minimum) as? Int ?? 2
        minimumClusterSize = (2...100).contains(savedMinimum) ? savedMinimum : 2
        scopeDate = defaults.string(forKey: Key.scopeDate) ?? ""
        scopeSource = defaults.string(forKey: Key.scopeSource) ?? ""
        scopeCamera = defaults.string(forKey: Key.scopeCamera) ?? ""

        if savedPort == nil {
            if let oldPort {
                defaults.set(oldPort, forKey: Key.oldPortBackup)
                defaults.removeObject(forKey: Key.oldPort)
            }
            defaults.set(apiPort, forKey: Key.port)
        }
    }

    private static var defaultRepositoryPath: String {
        if let path = Bundle.main.object(forInfoDictionaryKey: "ClusterGrouperRepository") as? String,
           path.hasPrefix("/") {
            return normalizedPath(path)
        }
        // SwiftPM tests and direct development builds have no application Info.plist.
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("External/cluster-grouper", isDirectory: true).path
    }

    private static func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }

    var repositoryURL: URL {
        URL(fileURLWithPath: (repositoryPath as NSString).expandingTildeInPath)
            .standardizedFileURL
    }

    var apiPortValue: UInt16? {
        guard (1024...65535).contains(apiPort) else { return nil }
        return UInt16(apiPort)
    }

    var apiOriginValue: String? {
        let value = apiBrowserOrigin.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    var originValidationMessage: String? {
        guard let value = apiOriginValue else { return nil }
        guard let url = URLComponents(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host != nil, url.user == nil, url.password == nil,
              url.path.isEmpty, url.query == nil, url.fragment == nil else {
            return "Use an exact browser origin, such as http://localhost:3000, without a path."
        }
        return nil
    }
}
