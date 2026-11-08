import AppKit
import SwiftUI

@MainActor
struct ReviewSettingsView: View {
    let store: ReviewStore
    @Bindable var settings: ReviewSettings
    let clustering: ClusteringCoordinator

    var body: some View {
        TabView(selection: $settings.selectedTab) {
            general
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(ReviewSettingsTab.general)
            ClusteringSettingsView(store: store, settings: settings, clustering: clustering)
                .tabItem { Label("Clustering", systemImage: "person.2.crop.square.stack") }
                .tag(ReviewSettingsTab.clustering)
            IntegrationSettingsView(store: store, settings: settings, clustering: clustering)
                .tabItem { Label("Integrations", systemImage: "arrow.left.arrow.right") }
                .tag(ReviewSettingsTab.integrations)
        }
        .frame(width: 660, height: 610)
    }

    private var general: some View {
        Form {
            Section("Review Library") {
                LabeledContent("Location") {
                    Text(store.libraryURL.path)
                        .lineLimit(3)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                Button("Show Library in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([store.libraryURL])
                }
                Text("Clips, scan receipts, reviewed groups, and local clustering work belong to this library.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Local Processing") {
                LabeledContent("Face detection", value: "Apple Vision")
                LabeledContent("Similarity suggestions", value: "YuNet and SFace")
                Text("Clustering compares existing detected appearances on this Mac. Source videos stay unchanged. Suggestions need your review before they are saved as groups.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

@MainActor
private struct ClusteringSettingsView: View {
    let store: ReviewStore
    @Bindable var settings: ReviewSettings
    let clustering: ClusteringCoordinator
    @State private var setupCheck = 0

    private var environmentExists: Bool {
        FileManager.default.isExecutableFile(
            atPath: settings.repositoryURL.appendingPathComponent("backend/.venv/bin/python").path
        )
    }

    private var sourceExists: Bool {
        FileManager.default.fileExists(
            atPath: settings.repositoryURL.appendingPathComponent("backend/app/managed.py").path
        )
    }

    private var scopedAppearances: [Appearance] {
        let clipIDs = Set(store.clips.filter {
            (settings.scopeDate.isEmpty || $0.date == settings.scopeDate)
                && (settings.scopeSource.isEmpty || $0.source == settings.scopeSource)
                && (settings.scopeCamera.isEmpty || $0.camera == settings.scopeCamera)
        }.map(\.id))
        return store.appearances.filter { clipIDs.contains($0.clipID) }
    }

    private var ungroupedCount: Int {
        let grouped = store.groups.reduce(into: Set<String>()) { $0.formUnion($1.appearanceIDs) }
        return scopedAppearances.filter { !grouped.contains($0.id) }.count
    }

    var body: some View {
        Form {
            Section("Clustering Tool") {
                HStack {
                    TextField("Tool folder", text: $settings.repositoryPath)
                        .autocorrectionDisabled()
                        .disabled(clustering.isBackendRunning)
                    Button("Choose…", action: chooseFolder)
                        .disabled(clustering.isBackendRunning)
                }
                Label(
                    environmentExists && sourceExists ? "Tool environment found" : "Tool setup required",
                    systemImage: environmentExists && sourceExists ? "checkmark.circle" : "exclamationmark.triangle"
                )
                .foregroundStyle(environmentExists && sourceExists ? Color.secondary : Color.orange)
                .id(setupCheck)
                HStack {
                    Button("Check Setup") { setupCheck += 1 }
                    Button("Show Tool Folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([settings.repositoryURL])
                    }
                }
                if !environmentExists || !sourceExists {
                    Text("Choose the Cluster Grouper repository. Prepare its environment once with make setup and make models in that folder, then use Cluster Faces in the toolbar.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Appearance Scope") {
                Picker("Date", selection: $settings.scopeDate) {
                    Text("All Dates").tag("")
                    ForEach(options(\.date, selected: settings.scopeDate), id: \.self) { Text($0).tag($0) }
                }
                Picker("Source", selection: $settings.scopeSource) {
                    Text("All Sources").tag("")
                    ForEach(options(\.source, selected: settings.scopeSource), id: \.self) { Text($0).tag($0) }
                }
                Picker("Camera", selection: $settings.scopeCamera) {
                    Text("All Cameras").tag("")
                    ForEach(options(\.camera, selected: settings.scopeCamera), id: \.self) { Text($0).tag($0) }
                }
                LabeledContent("Detected appearances", value: scopedAppearances.count.formatted())
                LabeledContent("Outside reviewed groups", value: ungroupedCount.formatted())
                if scopedAppearances.count > 50000 {
                    Label("Choose a narrower scope. One export supports at most 50,000 appearances.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text("These settings define a new clustering run independently of the main window's filters and selection. Saved runs keep their original scope; start a new run to apply changes. Existing reviewed groups are preserved.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Reviewed imports accept up to 100 groups and 10,000 appearance assignments per request. These import limits are separate from clustering scope.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(clustering.isBusy)

            Section("Suggestions") {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Minimum similarity")
                        Spacer()
                        Text(settings.similarityThreshold, format: .number.precision(.fractionLength(2)))
                            .monospacedDigit()
                    }
                    Slider(value: $settings.similarityThreshold, in: 0...1, step: 0.01)
                        .accessibilityLabel("Minimum cosine similarity")
                    HStack {
                        Text("More suggestions")
                        Spacer()
                        Text("Stricter matches")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Stepper(value: $settings.minimumClusterSize, in: 2...100) {
                    LabeledContent("Minimum appearances per group", value: settings.minimumClusterSize.formatted())
                }
                Text("Similarity is a comparison score, not an identity probability. Every pair in a suggested group must meet the threshold.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .disabled(clustering.isBusy)

            Section("Service and Models") {
                LabeledContent("Clustering backend", value: clustering.isBackendRunning ? "Running for Footage Review" : "Stopped")
                Label(
                    clustering.modelsReady ? "Face models verified" : "Model readiness",
                    systemImage: clustering.modelsReady ? "checkmark.shield" : "info.circle"
                )
                Text(clustering.modelMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if clustering.isBackendRunning {
                    Button("Stop Clustering Service") {
                        Task { await clustering.stopService() }
                    }
                    .disabled(clustering.isBusy)
                }
                Text("Footage Review starts its own local backend when needed and stops it on quit. Closing the app preserves completed work and pauses unfinished jobs.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let error = clustering.errorMessage {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the Cluster Grouper repository containing its backend folder."
        panel.directoryURL = settings.repositoryURL
        if panel.runModal() == .OK, let url = panel.url {
            settings.repositoryPath = url.path
            setupCheck += 1
        }
    }

    private func options(_ keyPath: KeyPath<ReviewClip, String>, selected: String) -> [String] {
        var values = Set(store.clips.map { $0[keyPath: keyPath] }.filter { !$0.isEmpty })
        if !selected.isEmpty { values.insert(selected) }
        return values.sorted()
    }
}
