import AppKit
import SwiftUI

private struct ClusterReviewDraft: Equatable {
    var name: String
    var note: String
    var members: Set<String>

    init(_ group: ClusterGroup) {
        name = group.name
        note = group.note
        members = Set(group.appearanceIDs)
    }

    func differs(from group: ClusterGroup) -> Bool {
        name != group.name || note != group.note || members != Set(group.appearanceIDs)
    }
}

@MainActor
struct ClusteringReviewView: View {
    let store: ReviewStore
    let clustering: ClusteringCoordinator
    @Environment(\.dismiss) private var dismiss
    @State private var selectedID: String?
    @State private var drafts: [String: ClusterReviewDraft] = [:]
    @State private var reviewer = ""
    @State private var working = false
    @State private var requestCopied = false

    private var selectedGroup: ClusterGroup? {
        clustering.reviewGroups.first { $0.id == selectedID } ?? clustering.reviewGroups.first
    }

    private var approvedCount: Int {
        clustering.reviewGroups.filter { $0.reviewed && $0.dirty }.count
    }

    private var approvedAssignments: Int {
        clustering.reviewGroups.filter { $0.reviewed && $0.dirty }
            .reduce(0) { $0 + $1.appearanceIDs.count }
    }

    private var importWithinBounds: Bool { approvedCount <= 100 && approvedAssignments <= 10000 }

    private var unsavedDrafts: Bool {
        clustering.reviewGroups.contains { group in drafts[group.id]?.differs(from: group) == true }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if let error = clustering.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
            if let savedImport = clustering.preparedImport {
                importPreview(savedImport)
            } else if clustering.reviewGroups.isEmpty {
                ContentUnavailableView {
                    Label(clustering.canResume ? "Clustering is paused" : "No suggestions available", systemImage: "person.2.crop.square.stack")
                } description: {
                    Text(clustering.statusText)
                    Text(clustering.canResume
                         ? "Resume the saved run to finish comparing appearances. Completed work is retained."
                         : "Crops that do not produce usable face features remain available for manual review in the library.")
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                reviewLayout
            }
            Divider()
            footer
        }
        .frame(minWidth: 900, idealWidth: 1040, minHeight: 650, idealHeight: 760)
        .onAppear { selectedID = clustering.reviewGroups.first?.id }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Label("Review Face Suggestions", systemImage: "person.2.crop.square.stack")
                    .font(.title2.weight(.semibold))
                Spacer()
                if let workspace = clustering.workspace {
                    Text("Revision \(workspace.baseRevision)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            Text("Compare every crop, correct membership, and approve the groups you want to keep. Similarity is not an identity probability.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(20)
    }

    private var reviewLayout: some View {
        HSplitView {
            List(selection: $selectedID) {
                ForEach(clustering.reviewGroups) { group in
                    VStack(alignment: .leading, spacing: 3) {
                        Label(group.name, systemImage: group.reviewed ? "checkmark.circle" : "circle")
                            .lineLimit(1)
                        Text("\(group.appearanceIDs.count.formatted()) appearances · \(groupState(group))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                    .tag(group.id)
                }
            }
            .listStyle(.sidebar)
            .frame(minWidth: 210, idealWidth: 250, maxWidth: 320)
            if let group = selectedGroup {
                ClusterSuggestionEditor(
                    store: store,
                    group: group,
                    draft: draftBinding(group),
                    disabled: working || clustering.isBusy,
                    save: { save(group) },
                    unapprove: { unapprove(group) },
                    discard: { drafts[group.id] = nil }
                )
                .frame(minWidth: 540)
            }
        }
    }

    private func draftBinding(_ group: ClusterGroup) -> Binding<ClusterReviewDraft> {
        Binding(
            get: { drafts[group.id] ?? ClusterReviewDraft(group) },
            set: { drafts[group.id] = $0 }
        )
    }

    private func groupState(_ group: ClusterGroup) -> String {
        if group.origin == "existing" && !group.dirty { return "Imported" }
        if drafts[group.id]?.differs(from: group) == true { return "Unsaved edits" }
        return group.reviewed ? "Approved locally" : "Needs review"
    }

    private func save(_ group: ClusterGroup) {
        let draft = drafts[group.id] ?? ClusterReviewDraft(group)
        let orderedMembers = group.appearanceIDs.filter { draft.members.contains($0) }
        Task {
            working = true
            await clustering.saveReview(
                group: group,
                name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
                note: draft.note,
                appearanceIDs: orderedMembers
            )
            if clustering.errorMessage == nil { drafts[group.id] = nil }
            working = false
        }
    }

    private func unapprove(_ group: ClusterGroup) {
        Task {
            working = true
            await clustering.unapproveReview(group: group)
            working = false
        }
    }

    private func importPreview(_ savedImport: ClusterSavedImport) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(importTitle(savedImport.status), systemImage: savedImport.status == "submitted" ? "checkmark.circle.fill" : "doc.text.magnifyingglass")
                    .font(.headline)
                Spacer()
                Text(savedImport.id)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Text("This saved request contains a fixed group membership and base revision. Later review edits do not change it. Groups absent from the request are preserved.")
                .font(.callout)
                .foregroundStyle(.secondary)
            ScrollView([.horizontal, .vertical]) {
                Text(savedImport.prettyPayload)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(14)
            }
            .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 8))
            .accessibilityLabel("Saved group import request")
            if let error = savedImport.error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
            if savedImport.status == "uncertain" {
                Text("The outcome is uncertain. Retry this saved request with its original import ID; do not prepare a different request to bypass the uncertainty.")
                    .font(.callout)
            } else if savedImport.status == "rejected" {
                Text("The library rejected this request. Start a fresh clustering run and reconcile the current groups before preparing a new import.")
                    .font(.callout)
            } else if savedImport.status == "submitted" {
                Label("Reviewed groups are saved in the library's Groups sidebar. Inspect the source clips there.", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            }
            HStack {
                Button(requestCopied ? "Copied" : "Copy Request") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    requestCopied = pasteboard.setString(savedImport.prettyPayload, forType: .string)
                }
                Spacer()
                Button("Back to Review") { clustering.dismissPreparedImport() }
                    .disabled(working || clustering.isBusy || savedImport.status == "uncertain")
                Button(savedImport.status == "uncertain" ? "Retry Saved Import" : "Import Reviewed Groups") {
                    Task {
                        working = true
                        await clustering.submitPreparedImport()
                        working = false
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(working || clustering.isBusy || !["prepared", "uncertain"].contains(savedImport.status))
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func importTitle(_ status: String) -> String {
        switch status {
        case "submitted": return "Import Accepted"
        case "uncertain": return "Import Outcome Uncertain"
        case "rejected": return "Import Needs Reconciliation"
        default: return "Preview Saved Import"
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if clustering.preparedImport == nil && !clustering.reviewGroups.isEmpty {
                TextField("Reviewer name (optional)", text: $reviewer)
                    .frame(maxWidth: 230)
                Text(!importWithinBounds ? "Approve up to 100 groups and 10,000 assignments per import; mark other groups unreviewed."
                     : unsavedDrafts ? "Save or discard edits before preparing an import."
                     : "\(approvedCount.formatted()) approved changes · \(approvedAssignments.formatted()) assignments")
                    .font(.caption)
                    .foregroundStyle(importWithinBounds ? Color.secondary : Color.orange)
                Spacer()
                Button("Prepare Import") {
                    Task {
                        working = true
                        requestCopied = false
                        await clustering.prepareImport(reviewer: reviewer.trimmingCharacters(in: .whitespacesAndNewlines))
                        working = false
                    }
                }
                .disabled(working || clustering.isBusy || approvedCount == 0 || !importWithinBounds
                          || unsavedDrafts || reviewer.count > 200)
            } else {
                Text("Suggestions stay local until you explicitly review and import them.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .disabled(working)
        }
        .padding(16)
    }
}

@MainActor
private struct ClusterSuggestionEditor: View {
    let store: ReviewStore
    let group: ClusterGroup
    @Binding var draft: ClusterReviewDraft
    let disabled: Bool
    let save: () -> Void
    let unapprove: () -> Void
    let discard: () -> Void

    private var imported: Bool { group.origin == "existing" && !group.dirty }
    private var missingIDs: Set<String> { draft.members.subtracting(store.appearances.map(\.id)) }
    private var validText: Bool {
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && draft.name.count <= 120 && draft.note.count <= 4000
    }

    var body: some View {
        Form {
            Section("Group Review") {
                TextField("Group name", text: $draft.name)
                VStack(alignment: .leading, spacing: 5) {
                    Text("Notes").font(.callout)
                    TextEditor(text: $draft.note).frame(minHeight: 65, maxHeight: 105)
                        .accessibilityLabel("Group review notes")
                }
                LabeledContent("Membership", value: "\(draft.members.count.formatted()) appearances")
                if let score = group.similarity {
                    LabeledContent("Minimum pair similarity", value: score.formatted(.number.precision(.fractionLength(3))))
                }
                if !validText {
                    Text("Use a name of 1–120 characters and notes up to 4,000 characters.")
                        .font(.caption).foregroundStyle(.red)
                }
                if imported {
                    Label("Imported. Further group edits are available in the Groups sidebar.", systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                } else {
                    HStack {
                        Button("Discard Edits", action: discard)
                            .disabled(!draft.differs(from: group))
                        if group.reviewed {
                            Button("Mark Unreviewed", action: unapprove)
                        }
                        Spacer()
                        Button(group.reviewed && !draft.differs(from: group) ? "Approved Locally" : "Save Reviewed Group", action: save)
                            .buttonStyle(.borderedProminent)
                            .disabled(!validText || !missingIDs.isEmpty || (group.reviewed && !draft.differs(from: group)))
                    }
                }
            }
            .disabled(disabled || imported)

            Section("Inspect Appearances") {
                Text("Keep only the appearances you have checked. Remove uncertain matches before approving.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if !missingIDs.isEmpty {
                    Label("\(missingIDs.count.formatted()) appearances are unavailable in the current library. Re-run clustering or remove these memberships before approval.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("Remove Unavailable Memberships") { draft.members.subtract(missingIDs) }
                        .disabled(disabled || imported)
                }
                memberGrid
            }
        }
        .formStyle(.grouped)
    }

    private var memberGrid: some View {
        let byID = Dictionary(uniqueKeysWithValues: store.appearances.map { ($0.id, $0) })
        return ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 145, maximum: 200), spacing: 12)], spacing: 16) {
                ForEach(group.appearanceIDs, id: \.self) { id in
                    if let item = byID[id] {
                        let clip = store.clip(for: item)
                        VStack(alignment: .leading, spacing: 6) {
                            CropThumbnail(url: store.cropURL(for: item))
                                .frame(height: 135)
                                .background(.quaternary.opacity(0.35), in: .rect(cornerRadius: 6))
                            Toggle(isOn: Binding(
                                get: { draft.members.contains(id) },
                                set: { if $0 { draft.members.insert(id) } else { draft.members.remove(id) } }
                            )) {
                                Text(clip?.camera ?? "Appearance").lineLimit(1)
                            }
                            .toggleStyle(.checkbox)
                            .accessibilityLabel("Include appearance \(id), \(clip?.camera ?? "video clip"), \(formatOffset(item.seconds)) into clip")
                            .disabled(disabled || imported)
                            Text("\(clip?.date ?? "") \(clip?.clock ?? "") · +\(formatOffset(item.seconds))")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .opacity(draft.members.contains(id) ? 1 : 0.5)
                    }
                }
            }
            .padding(.vertical, 8)
        }
        .frame(minHeight: 170, idealHeight: 300, maxHeight: 380)
    }
}
