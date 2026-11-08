import AppKit
import SwiftUI

@MainActor
struct AppearanceGrid: View {
    let store: ReviewStore
    let items: [Appearance]
    let selected: Set<String>
    let onSelect: (Appearance) -> Void
    let onOpen: (Appearance) -> Void
    let newGroup: (Set<String>) -> Void
    let currentGroupID: String?

    private let columns = [GridItem(.adaptive(minimum: 134, maximum: 195), spacing: 13)]

    var body: some View {
        let clipsByID = Dictionary(uniqueKeysWithValues: store.clips.map { ($0.id, $0) })
        ScrollView {
            LazyVGrid(columns: columns, spacing: 13) {
                ForEach(items) { item in
                    let dragIDs: Set<String> = selected.contains(item.id) ? selected : [item.id]
                    AppearanceCard(
                        appearance: item,
                        clip: clipsByID[item.clipID],
                        cropURL: store.cropURL(for: item),
                        selected: selected.contains(item.id),
                        onSelect: { onSelect(item) },
                        onOpen: { onOpen(item) }
                    )
                    .draggable(AppearanceTransfer.payload(dragIDs))
                    .contextMenu {
                        Button("Open at Appearance") { onOpen(item) }
                        Menu("Add to Group") {
                            Button("New Group…") { newGroup(dragIDs) }
                            if !store.groups.isEmpty { Divider() }
                            ForEach(store.groups) { group in
                                Button(group.name) { store.add(dragIDs, to: group.id) }
                            }
                        }
                        if let currentGroupID {
                            Button("Remove from Group") { store.remove(dragIDs, from: currentGroupID) }
                        }
                    }
                }
            }
            .padding(20)
        }
    }
}

private struct AppearanceCard: View {
    let appearance: Appearance
    let clip: ReviewClip?
    let cropURL: URL
    let selected: Bool
    let onSelect: () -> Void
    let onOpen: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 0) {
                Color.secondary.opacity(0.08)
                    .aspectRatio(1, contentMode: .fit)
                    .overlay {
                        CropThumbnail(url: cropURL)
                    }
                    .clipped()
                    .overlay(alignment: .bottomTrailing) {
                        Text(formatOffset(appearance.seconds))
                            .font(.caption2.monospacedDigit().weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .foregroundStyle(.white)
                            .background(.black.opacity(0.7), in: .capsule)
                            .padding(7)
                    }
                    .overlay(alignment: .topLeading) {
                        if selected {
                            Image(systemName: "checkmark.circle.fill")
                                .symbolRenderingMode(.palette)
                                .foregroundStyle(.white, Color.accentColor)
                                .font(.system(size: 18))
                                .padding(7)
                        }
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text(clip?.camera ?? "Video clip")
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                    Text(clip.map { "\($0.date)  \($0.clock)" } ?? "Capture time unavailable")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(selected ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.07))
            .clipShape(.rect(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(
                        selected ? Color.accentColor : Color.secondary.opacity(0.22),
                        lineWidth: selected ? 2 : 1
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded { onOpen() })
        .accessibilityLabel(
            "Appearance in \(clip?.camera ?? "video clip"), \(clip?.date ?? ""), \(clip?.clock ?? ""), \(formatOffset(appearance.seconds)) into clip"
        )
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityAction(named: Text("Open at Appearance"), onOpen)
        .help("Click to select. Command-click to add, Shift-click for a range, or double-click to play.")
    }
}

struct CropThumbnail: View {
    let url: URL
    @State private var thumbnail: NSImage?

    var body: some View {
        GeometryReader { geometry in
            if let thumbnail {
                Image(nsImage: thumbnail)
                    .resizable()
                    .scaledToFit()
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .accessibilityHidden(true)
            } else {
                Image(systemName: "person.crop.square")
                    .font(.title)
                    .foregroundStyle(.tertiary)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .accessibilityHidden(true)
            }
        }
        .task(id: url) {
            thumbnail = nil
            let imageURL = url
            let bytes = await Task.detached(priority: .utility) {
                try? Data(contentsOf: imageURL)
            }.value
            guard !Task.isCancelled else { return }
            thumbnail = bytes.flatMap { NSImage(data: $0) }
        }
    }
}

func formatOffset(_ seconds: Double) -> String {
    guard seconds.isFinite, seconds >= 0, seconds < Double(Int.max / 100) else { return "—" }
    let hundredths = Int(seconds * 100)
    return String(
        format: "%02lld:%02lld.%02lld",
        hundredths / 6000,
        (hundredths / 100) % 60,
        hundredths % 100
    )
}
