import SwiftUI

struct ReviewFilters: Equatable {
    var date = ""
    var source = ""
    var camera = ""

    var isEmpty: Bool { date.isEmpty && source.isEmpty && camera.isEmpty }

    func matches(_ clip: ReviewClip, search: String) -> Bool {
        guard date.isEmpty || clip.date == date,
              source.isEmpty || clip.source == source,
              camera.isEmpty || clip.camera == camera else { return false }
        guard !search.isEmpty else { return true }
        let terms = search.split(whereSeparator: \.isWhitespace)
        let metadata = [clip.date, clip.clock, clip.source, clip.camera, clip.path].joined(separator: " ")
        return terms.allSatisfy { metadata.localizedStandardContains(String($0)) }
    }
}

struct ReviewFilterBar: View {
    @Binding var filters: ReviewFilters
    let clips: [ReviewClip]

    var body: some View {
        HStack(spacing: 12) {
            Picker("Date", selection: $filters.date) {
                Text("All Dates").tag("")
                ForEach(options(\.date), id: \.self) { Text($0).tag($0) }
            }
            Picker("Source", selection: $filters.source) {
                Text("All Sources").tag("")
                ForEach(options(\.source), id: \.self) { Text($0).tag($0) }
            }
            Picker("Camera", selection: $filters.camera) {
                Text("All Cameras").tag("")
                ForEach(options(\.camera), id: \.self) { Text($0).tag($0) }
            }
            Spacer(minLength: 0)
            if !filters.isEmpty {
                Button("Clear", systemImage: "xmark.circle") { filters = ReviewFilters() }
                    .labelStyle(.iconOnly)
                    .help("Clear date, source, and camera filters")
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .padding(.horizontal, 20)
        .padding(.bottom, 11)
        .disabled(clips.isEmpty)
    }

    private func options(_ keyPath: KeyPath<ReviewClip, String>) -> [String] {
        Set(clips.map { $0[keyPath: keyPath] }).filter { !$0.isEmpty }.sorted()
    }
}

struct ScanStatusView: View {
    let progress: ScanProgress
    let isScanning: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label(
                    progress.state.title,
                    systemImage: phaseSymbol
                )
                .font(.callout.weight(.semibold))
                Spacer()
                Text("\(progress.completed.formatted()) of \(progress.total.formatted())")
                    .monospacedDigit()
                if progress.failed > 0 {
                    Text("\(progress.failed.formatted()) failed")
                        .foregroundStyle(.orange)
                }
            }
            ProgressView(value: Double(progress.completed), total: Double(max(1, progress.total)))
                .accessibilityLabel("Clip scan progress")
            HStack {
                Text("\(progress.appearances.formatted()) detected appearances · \(progress.adopted.formatted()) clips reused")
                Spacer()
                if progress.state == .cancelled {
                    Text("Completed results kept")
                } else if isScanning, !progress.current.isEmpty {
                    Text(progress.current).lineLimit(1).truncationMode(.middle)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .background(.bar)
    }

    private var phaseSymbol: String {
        switch progress.state {
        case .running: "viewfinder"
        case .paused: "pause.circle"
        case .cancelled: "stop.circle"
        case .completed: "checkmark.circle"
        }
    }
}
