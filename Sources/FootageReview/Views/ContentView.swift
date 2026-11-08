import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct ContentView: View {
    let store: ReviewStore
    let settings: ReviewSettings
    let clustering: ClusteringCoordinator

    @State private var section: ReviewSection? = .appearances
    @State private var filters = ReviewFilters()
    @State private var search = ""
    @State private var selectedAppearances: Set<String> = []
    @State private var selectedClips: Set<String> = []
    @State private var selectionAnchor: String?
    @State private var preview: ClipPreview?
    @State private var showInspector = false
    @State private var showImporter = false
    @State private var showClusteringReview = false
    @State private var groupDraft: GroupDraft?
    @State private var displayedError: String?

    var body: some View {
        let matchingClips = store.clips.filter { filters.matches($0, search: search) }
        let clipIDs = Set(matchingClips.map(\.id))
        let matchingAppearances = visibleAppearances(clipIDs)
        let selectedInScope = clipIDs.intersection(selectedClips)
        let requested = section == .clips && !selectedInScope.isEmpty ? selectedInScope : clipIDs
        let visibleSelection = selectedAppearances.intersection(matchingAppearances.map(\.id))

        NavigationSplitView {
            ReviewSidebar(
                store: store,
                section: $section,
                createGroup: { presentNewGroup(visibleSelection) },
                editGroup: { groupDraft = GroupDraft(group: $0) }
            )
            .navigationSplitViewColumnWidth(min: 175, ideal: 205, max: 280)
        } detail: {
            VStack(spacing: 0) {
                header(clipCount: matchingClips.count, appearanceCount: matchingAppearances.count)
                ReviewFilterBar(filters: $filters, clips: store.clips)
                if store.isLoadingLibrary {
                    ProgressView("Restoring scan library…")
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 9)
                } else if let progress = store.scanProgress {
                    ScanStatusView(progress: progress, isScanning: store.isScanning)
                }
                if clustering.isBusy || clustering.hasSavedRun || clustering.errorMessage != nil {
                    ClusteringStatusView(clustering: clustering) {
                        Task {
                            if clustering.workspace == nil {
                                await clustering.openSavedRun(store: store, settings: settings)
                            }
                            if clustering.workspace != nil { showClusteringReview = true }
                        }
                    }
                }
                Divider()
                if store.clips.isEmpty {
                    importEmptyState
                } else if section == .clips {
                    ClipTable(
                        clips: matchingClips,
                        selection: $selectedClips,
                        scanned: store.scannedClipIDs,
                        failed: store.failedClipIDs,
                        issues: store.scanIssues,
                        preview: { openPreview($0, seconds: 0) }
                    )
                    if !matchingClips.isEmpty {
                        clipScanBar(selected: selectedInScope, filtered: clipIDs)
                    }
                } else if matchingAppearances.isEmpty {
                    appearanceEmptyState(requested: requested)
                } else {
                    AppearanceGrid(
                        store: store,
                        items: matchingAppearances,
                        selected: visibleSelection,
                        onSelect: { select($0, in: matchingAppearances) },
                        onOpen: { openPreview($0) },
                        newGroup: { presentNewGroup($0) },
                        currentGroupID: currentGroup?.id
                    )
                }
                if !visibleSelection.isEmpty, section != .clips {
                    selectionBar(visibleSelection)
                }
            }
            .searchable(text: $search, placement: .toolbar, prompt: "Find a camera, date, or clip")
            .inspector(isPresented: $showInspector) {
                ClipInspector(preview: preview)
                    .inspectorColumnWidth(min: 265, ideal: 320, max: 460)
            }
            .toolbar {
                ToolbarItemGroup {
                    Button {
                        showImporter = true
                    } label: {
                        Label("Import Clips", systemImage: "plus")
                    }
                    .help("Import video files or folders")
                    .disabled(store.isImporting)

                    if store.isScanning && store.scanProgress?.state == .running {
                        Button(action: store.pauseScan) {
                            Label("Pause Scan", systemImage: "pause.circle")
                        }
                        .help("Save the queue and pause scanning")
                    }
                    if store.canResumeScan {
                        Button(action: store.resumeScan) {
                            Label("Resume Scan", systemImage: "play.circle")
                        }
                        .help("Continue the saved scan queue")
                    }
                    if store.canCancelScan {
                        Button(action: store.cancelScan) {
                            Label("Cancel Scan", systemImage: "stop.circle")
                        }
                        .help("End this scan queue. Completed results stay in the library.")
                    }
                    if !store.isScanning && !store.canResumeScan && !store.canCancelScan {
                        Button {
                            store.startScan(requested)
                        } label: {
                            Label("Scan Clips (\(pendingCount(requested)) pending)", systemImage: "viewfinder")
                        }
                        .disabled(!canStartScan || requested.isEmpty)
                        .help("Review the current scope and reuse available scan results")
                    }
                    Menu {
                        Button("Cluster Faces") {
                            Task { await clustering.start(store: store, settings: settings) }
                        }
                        if clustering.hasSavedRun {
                            Button("Start New Clustering Run") {
                                Task { await clustering.startNewRun(store: store, settings: settings) }
                            }
                        }
                    } label: {
                        Label("Cluster Faces", systemImage: "person.2.crop.square.stack")
                    } primaryAction: {
                        Task { await clustering.start(store: store, settings: settings) }
                    }
                    .disabled(clustering.isBusy || store.isLoadingLibrary || store.isImporting
                              || store.isScanning || store.appearances.isEmpty)
                    .help("Cluster detected faces across the library, or reopen saved clustering work")
                    SettingsLink {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .help("Clustering preferences and local API settings")
                    Button {
                        showInspector.toggle()
                    } label: {
                        Label("Clip Inspector", systemImage: "sidebar.right")
                    }
                    .help("Show or hide clip playback")
                }
            }
        }
        .navigationTitle("Footage Review")
        .onChange(of: section) { _, _ in
            selectedAppearances.removeAll()
            selectedClips.removeAll()
            selectionAnchor = nil
        }
        .onChange(of: store.errorMessage, initial: true) { _, message in
            displayedError = message
        }
        .alert("Footage Review", isPresented: Binding(
            get: { displayedError != nil },
            set: { if !$0 { dismissError() } }
        )) {
            Button("OK", role: .cancel, action: dismissError)
        } message: {
            Text(displayedError ?? "")
        }
        .fileImporter(
            isPresented: $showImporter,
            allowedContentTypes: [.movie, .folder],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls): store.importURLs(urls)
            case .failure(let error): displayedError = error.localizedDescription
            }
        }
        .sheet(item: $groupDraft) { draft in
            GroupEditor(draft: draft) { name, note in
                if let original = draft.originalGroup {
                    return store.editGroup(original, name: name, note: note)
                }
                guard let id = store.createGroup(name, note: note, appearanceIDs: draft.appearanceIDs) else { return false }
                section = .group(id)
                return true
            }
        }
        .sheet(isPresented: $showClusteringReview) {
            ClusteringReviewView(store: store, clustering: clustering)
        }
    }

    private var currentGroup: ReviewGroup? {
        guard case .group(let id) = section else { return nil }
        return store.groups.first { $0.id == id }
    }

    private var canStartScan: Bool {
        !store.isLoadingLibrary && !store.isImporting && !store.isScanning
            && !store.canResumeScan && !store.canCancelScan
    }

    private func pendingCount(_ scope: Set<String>) -> String {
        scope.subtracting(store.scannedClipIDs).count.formatted()
    }

    private func dismissError() {
        displayedError = nil
        store.errorMessage = nil
    }

    private func visibleAppearances(_ clipIDs: Set<String>) -> [Appearance] {
        switch section {
        case .clips:
            return []
        case .ungrouped:
            let grouped = store.groups.reduce(into: Set<String>()) { ids, group in
                ids.formUnion(group.appearanceIDs)
            }
            return store.appearances.filter { clipIDs.contains($0.clipID) && !grouped.contains($0.id) }
        case .group:
            let members = currentGroup?.appearanceIDs ?? []
            return store.appearances.filter { clipIDs.contains($0.clipID) && members.contains($0.id) }
        default:
            return store.appearances.filter { clipIDs.contains($0.clipID) }
        }
    }

    private func header(clipCount: Int, appearanceCount: Int) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 5) {
                Text(currentGroup?.name ?? section?.title ?? "Appearances")
                    .font(.system(size: 28, weight: .semibold))
                    .lineLimit(1)
                Text(section == .clips
                     ? "\(clipCount.formatted()) clips · \(store.scannedClipIDs.count.formatted()) scanned in library"
                     : "\(appearanceCount.formatted()) appearances · \(clipCount.formatted()) clips in scope")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let note = currentGroup?.note, !note.isEmpty {
                    Text(note)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            if let group = currentGroup {
                Button("Edit Group", systemImage: "pencil") {
                    groupDraft = GroupDraft(group: group)
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 17)
        .padding(.bottom, 13)
    }

    private var importEmptyState: some View {
        ContentUnavailableView {
            Label("Add footage to review", systemImage: "film.stack")
        } description: {
            Text("Choose video files or folders to start a local review library.")
        } actions: {
            Button("Import Clips…") { showImporter = true }
                .buttonStyle(.borderedProminent)
                .disabled(store.isImporting)
            if store.isImporting {
                ProgressView().controlSize(.small)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func appearanceEmptyState(requested: Set<String>) -> some View {
        ContentUnavailableView {
            Label("No appearances in this view", systemImage: "person.crop.rectangle")
        } description: {
            if let group = currentGroup, group.appearanceIDs.isEmpty {
                Text("Select appearances in the library, then add them to this group.")
            } else if store.isLoadingLibrary {
                Text("Saved results are loading.")
            } else if store.canResumeScan {
                Text("Use Resume Scan to continue the saved queue.")
            } else if store.isScanning {
                Text("Appearances will show here as clips finish scanning.")
            } else if !requested.isEmpty {
                Text("Scan clips in this view to detect face appearances.")
            } else {
                Text("Change the filters or choose a different library view.")
            }
        } actions: {
            if !requested.isEmpty, canStartScan {
                Button("Scan Clips (\(pendingCount(requested)) pending)") {
                    store.startScan(requested)
                }
                .buttonStyle(.borderedProminent)
            }
            if !filters.isEmpty || !search.isEmpty {
                Button("Clear Filters") {
                    filters = ReviewFilters()
                    search = ""
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func selectionBar(_ selection: Set<String>) -> some View {
        HStack {
            Text("\(selection.count.formatted()) selected")
                .font(.callout.weight(.medium))
            Spacer()
            Button("Clear") {
                selectedAppearances.removeAll()
                selectionAnchor = nil
            }
            Menu("Add to Group", systemImage: "folder.badge.plus") {
                Button("New Group…") { presentNewGroup(selection) }
                if !store.groups.isEmpty { Divider() }
                ForEach(store.groups) { group in
                    Button(group.name) { store.add(selection, to: group.id) }
                }
            }
            if let group = currentGroup {
                Button("Remove from Group") { store.remove(selection, from: group.id) }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(.bar)
    }

    private func clipScanBar(selected: Set<String>, filtered: Set<String>) -> some View {
        HStack {
            Text("\(selected.count.formatted()) selected")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Scan Filtered (\(pendingCount(filtered)) pending)") { store.startScan(filtered) }
                .disabled(filtered.isEmpty || !canStartScan)
            Button("Scan Selected (\(pendingCount(selected)) pending)") { store.startScan(selected) }
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty || !canStartScan)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .background(.bar)
    }

    private func select(_ item: Appearance, in visible: [Appearance]) {
        let flags = NSEvent.modifierFlags
        if flags.contains(.shift), let anchor = selectionAnchor,
           let start = visible.firstIndex(where: { $0.id == anchor }),
           let end = visible.firstIndex(where: { $0.id == item.id }) {
            selectedAppearances.formUnion(visible[min(start, end)...max(start, end)].map(\.id))
        } else if flags.contains(.command) {
            if !selectedAppearances.insert(item.id).inserted {
                selectedAppearances.remove(item.id)
            }
            selectionAnchor = item.id
        } else {
            selectedAppearances = [item.id]
            selectionAnchor = item.id
        }
        if selectedAppearances.count == 1, showInspector,
           let clip = store.clip(for: item) {
            preview = ClipPreview(clip: clip, seconds: item.seconds)
        }
    }

    private func presentNewGroup(_ ids: Set<String>) {
        groupDraft = GroupDraft(appearanceIDs: ids)
    }

    private func openPreview(_ appearance: Appearance) {
        guard let clip = store.clip(for: appearance) else { return }
        openPreview(clip, seconds: appearance.seconds)
    }

    private func openPreview(_ clip: ReviewClip, seconds: Double) {
        preview = ClipPreview(clip: clip, seconds: seconds)
        showInspector = true
    }
}
