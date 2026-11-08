import SwiftUI

enum ReviewSection: Hashable {
    case appearances
    case ungrouped
    case clips
    case group(String)

    var title: String {
        switch self {
        case .appearances: "Appearances"
        case .ungrouped: "Ungrouped"
        case .clips: "Clips"
        case .group: "Group"
        }
    }
}

@MainActor
struct ReviewSidebar: View {
    let store: ReviewStore
    @Binding var section: ReviewSection?
    let createGroup: () -> Void
    let editGroup: (ReviewGroup) -> Void

    var body: some View {
        List(selection: $section) {
            Section("Library") {
                Label("Appearances", systemImage: "person.crop.rectangle")
                    .tag(ReviewSection.appearances)
                Label("Ungrouped", systemImage: "tray")
                    .tag(ReviewSection.ungrouped)
                Label("Clips", systemImage: "film.stack")
                    .tag(ReviewSection.clips)
            }
            Section {
                ForEach(store.groups) { group in
                    GroupSidebarRow(group: group) { ids in
                        store.add(ids, to: group.id)
                    }
                    .tag(ReviewSection.group(group.id))
                    .contextMenu {
                        Button("Edit Name and Note…") { editGroup(group) }
                    }
                }
                Button(action: createGroup) {
                    Label("New Group…", systemImage: "plus")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .keyboardShortcut("g", modifiers: [.command, .shift])
            } header: {
                Text("Groups")
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Divider()
                Label("On this Mac", systemImage: "internaldrive")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 12)
                Text("\(store.clips.count.formatted()) clips")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 9)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.bar)
        }
    }
}

enum AppearanceTransfer {
    static let prefix = "footage-review/appearances\n"

    static func payload(_ ids: Set<String>) -> String {
        prefix + ids.sorted().joined(separator: "\n")
    }

    static func IDs(from payloads: [String]) -> Set<String> {
        Set(payloads.flatMap { payload -> [String] in
            guard payload.hasPrefix(prefix) else { return [] }
            return payload.dropFirst(prefix.count).split(separator: "\n").map(String.init)
        })
    }
}

private struct GroupSidebarRow: View {
    let group: ReviewGroup
    let onDrop: (Set<String>) -> Void
    @State private var isTargeted = false

    var body: some View {
        HStack {
            Label(group.name, systemImage: "folder")
                .lineLimit(1)
            Spacer(minLength: 5)
            Text(group.appearanceIDs.count.formatted())
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
        .background {
            if isTargeted {
                RoundedRectangle(cornerRadius: 5).fill(Color.accentColor.opacity(0.18))
            }
        }
        .dropDestination(for: String.self) { payloads, _ in
            let ids = AppearanceTransfer.IDs(from: payloads)
            guard !ids.isEmpty else { return false }
            onDrop(ids)
            return true
        } isTargeted: { isTargeted = $0 }
    }
}

struct GroupDraft: Identifiable {
    let id = UUID()
    var originalGroup: ReviewGroup?
    var groupID: String? { originalGroup?.id }
    var name = ""
    var note = ""
    var appearanceIDs: Set<String> = []

    init(appearanceIDs: Set<String>) {
        self.appearanceIDs = appearanceIDs
    }

    init(group: ReviewGroup) {
        originalGroup = group
        name = group.name
        note = group.note
        appearanceIDs = group.appearanceIDs
    }
}

struct GroupEditor: View {
    let draft: GroupDraft
    let onSave: (String, String) -> Bool
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focusName: Bool
    @State private var name: String
    @State private var note: String

    init(draft: GroupDraft, onSave: @escaping (String, String) -> Bool) {
        self.draft = draft
        self.onSave = onSave
        _name = State(initialValue: draft.name)
        _note = State(initialValue: draft.note)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Text(draft.groupID == nil ? "New Group" : "Edit Group")
                .font(.title2.bold())
            if !draft.appearanceIDs.isEmpty {
                Text("\(draft.appearanceIDs.count.formatted()) appearances")
                    .foregroundStyle(.secondary)
            }
            TextField("Group name", text: $name)
                .focused($focusName)
            TextField("Notes", text: $note, axis: .vertical)
                .lineLimit(3...6)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(draft.groupID == nil ? "Create" : "Save") {
                    if onSave(trimmedName, note) { dismiss() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(trimmedName.isEmpty)
            }
        }
        .padding(22)
        .frame(width: 400)
        .onAppear { focusName = true }
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
