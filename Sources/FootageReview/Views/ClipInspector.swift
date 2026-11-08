import AppKit
import AVFoundation
import AVKit
import SwiftUI

struct ClipPreview: Identifiable {
    let clip: ReviewClip
    let seconds: Double

    var id: String { "\(clip.id):\(seconds)" }
}

@MainActor
struct ClipInspector: View {
    let preview: ClipPreview?
    @State private var player: AVPlayer?
    @State private var playbackError: String?

    var body: some View {
        Group {
            if let preview {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Source Clip").font(.headline)
                        playerSurface
                        clipDetails(preview)
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ContentUnavailableView(
                    "Select a clip",
                    systemImage: "film",
                    description: Text("Double-click a clip or an appearance to play it here.")
                )
            }
        }
        .task(id: preview?.id) { await load(preview) }
        .onDisappear {
            player?.pause()
            player = nil
        }
    }

    private var playerSurface: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
            } else if let playbackError {
                VStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle")
                    Text(playbackError).font(.caption)
                }
                .multilineTextAlignment(.center)
                .padding(10)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.quaternary)
            } else {
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(.quaternary)
            }
        }
        .aspectRatio(16.0 / 9.0, contentMode: .fit)
        .clipShape(.rect(cornerRadius: 8))
    }

    private func clipDetails(_ preview: ClipPreview) -> some View {
        let url = URL(fileURLWithPath: preview.clip.path)
        return VStack(alignment: .leading, spacing: 8) {
            Text(preview.clip.camera)
                .font(.title3.weight(.semibold))
            Text("\(preview.clip.date)  \(preview.clip.clock) · \(preview.clip.source)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(url.lastPathComponent)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Button("Jump to \(formatOffset(preview.seconds))", systemImage: "backward.end") {
                jump(preview.seconds)
            }
            .disabled(player == nil)
            Button("Reveal in Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([url])
            }
        }
    }

    private func load(_ preview: ClipPreview?) async {
        player?.pause()
        player = nil
        playbackError = nil
        guard let preview else { return }
        let url = URL(fileURLWithPath: preview.clip.path)
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            playbackError = "The source file is unavailable. Reconnect its drive to play it."
            return
        }
        let asset = AVURLAsset(url: url)
        do {
            let playable = try await asset.load(.isPlayable)
            guard !Task.isCancelled else { return }
            guard playable else {
                playbackError = "This clip cannot be played by the Mac video player."
                return
            }
            player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            jump(preview.seconds)
        } catch {
            guard !Task.isCancelled else { return }
            playbackError = error.localizedDescription
        }
    }

    private func jump(_ seconds: Double) {
        guard seconds.isFinite, seconds >= 0 else { return }
        player?.pause()
        player?.seek(
            to: CMTime(seconds: seconds, preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
    }
}

struct ClipTable: View {
    let clips: [ReviewClip]
    @Binding var selection: Set<String>
    let scanned: Set<String>
    let failed: Set<String>
    let issues: [String: String]
    let preview: (ReviewClip) -> Void
    @State private var issue: String?

    var body: some View {
        if clips.isEmpty {
            ContentUnavailableView(
                "No clips in this view",
                systemImage: "line.3.horizontal.decrease.circle",
                description: Text("Change the filters to browse other clips.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Table(clips, selection: $selection) {
                TableColumn("Camera", value: \.camera).width(min: 90, ideal: 125)
                TableColumn("Date", value: \.date).width(min: 83, ideal: 90)
                TableColumn("Start", value: \.clock).width(min: 64, ideal: 76)
                TableColumn("Source", value: \.source).width(min: 55, ideal: 75)
                TableColumn("Filename", value: \.filename).width(min: 105, ideal: 210)
                TableColumn("Scan") { clip in
                    if failed.contains(clip.id) {
                        Label("Failed", systemImage: "exclamationmark.circle")
                            .foregroundStyle(.orange)
                            .help(issues[clip.id] ?? "Scan failed")
                    } else if scanned.contains(clip.id), let warning = issues[clip.id] {
                        Label("Partial", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                            .help(warning)
                    } else if scanned.contains(clip.id) {
                        Label("Scanned", systemImage: "checkmark.circle")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Pending").foregroundStyle(.secondary)
                    }
                }
                .width(min: 75, ideal: 105)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if let clip = clips.first(where: { ids.contains($0.id) }) {
                    Button("Open Source Clip") { preview(clip) }
                    if let message = issues[clip.id] {
                        Button("Show Scan Issue") { issue = message }
                    }
                    Button("Reveal in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: clip.path)])
                    }
                }
            } primaryAction: { ids in
                if let clip = clips.first(where: { ids.contains($0.id) }) {
                    preview(clip)
                }
            }
            .alert("Clip Scan Issue", isPresented: Binding(
                get: { issue != nil },
                set: { if !$0 { issue = nil } }
            )) {
                Button("OK", role: .cancel) { issue = nil }
            } message: {
                Text(issue ?? "")
            }
        }
    }
}
