import AppKit
import SwiftUI

@main
@MainActor
struct FootageReviewApp: App {
    @NSApplicationDelegateAdaptor(ReviewAppDelegate.self) private var appDelegate
    @State private var store = ReviewStore(libraryURL: Self.libraryOverride)
    @State private var settings = ReviewSettings()
    @State private var clustering = ClusteringCoordinator()

    var body: some Scene {
        WindowGroup("Footage Review") {
            ContentView(store: store, settings: settings, clustering: clustering)
                .frame(minWidth: 860, minHeight: 560)
                .task {
                    appDelegate.configure(store: store, clustering: clustering)
                    clustering.restore(store: store, settings: settings)
                }
        }
        .defaultSize(width: 1180, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Import Clips…") {
                    let panel = NSOpenPanel()
                    panel.canChooseFiles = true
                    panel.canChooseDirectories = true
                    panel.allowsMultipleSelection = true
                    panel.message = "Choose video files or folders to add to Footage Review."
                    if panel.runModal() == .OK { store.importURLs(panel.urls) }
                }
                .keyboardShortcut("o")
                Divider()
                Button("Show Review Library in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([store.libraryURL])
                }
            }
            CommandMenu("Clustering") {
                Button("Cluster Faces") {
                    Task { await clustering.start(store: store, settings: settings) }
                }
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .disabled(!canCluster)
                Button("Start New Clustering Run") {
                    Task { await clustering.startNewRun(store: store, settings: settings) }
                }
                .disabled(!canCluster || !clustering.hasSavedRun)
                Divider()
                Button("Pause Clustering") { Task { await clustering.pause() } }
                    .disabled(!clustering.canPause)
                Button("Resume Clustering") { Task { await clustering.resume() } }
                    .disabled(!clustering.canResume)
                Button("Cancel Clustering") { Task { await clustering.cancel() } }
                    .disabled(!clustering.canCancel)
            }
        }
        Settings {
            ReviewSettingsView(store: store, settings: settings, clustering: clustering)
        }
    }

    private var canCluster: Bool {
        !clustering.isBusy && !store.isLoadingLibrary && !store.isImporting
            && !store.isScanning && !store.appearances.isEmpty
    }

    private static var libraryOverride: URL? {
        guard let path = ProcessInfo.processInfo.environment["FOOTAGE_REVIEW_LIBRARY"],
              !path.isEmpty else { return nil }
        return URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
    }
}

@MainActor
final class ReviewAppDelegate: NSObject, NSApplicationDelegate {
    private weak var store: ReviewStore?
    private weak var clustering: ClusteringCoordinator?
    private var isTerminating = false

    func configure(store: ReviewStore, clustering: ClusteringCoordinator) {
        self.store = store
        self.clustering = clustering
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminating else { return .terminateLater }
        guard let clustering else { return .terminateNow }
        isTerminating = true
        if store?.isScanning == true { store?.pauseScan() }
        Task { @MainActor in
            await clustering.shutdown()
            let deadline = Date().addingTimeInterval(15)
            while store?.isScanning == true, Date() < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            finishTermination(sender)
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(20))
            finishTermination(sender)
        }
        return .terminateLater
    }

    private func finishTermination(_ sender: NSApplication) {
        guard isTerminating else { return }
        isTerminating = false
        sender.reply(toApplicationShouldTerminate: true)
    }
}
