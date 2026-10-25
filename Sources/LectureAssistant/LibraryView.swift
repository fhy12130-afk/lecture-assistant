import SwiftUI
import AppKit

/// 所有讲座记录：点一份打开，回看、提问、修改，或者接着记
struct LibraryView: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @State private var records: [RecordInfo] = []
    @State private var query = ""
    @State private var picked: RecordInfo.ID?

    private var filtered: [RecordInfo] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return records }
        return records.filter { $0.title.localizedCaseInsensitiveContains(q) || $0.speaker.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("讲座记录").font(.title3.weight(.semibold))
                Spacer()
                TextField("搜索题目或汇报人", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
            }
            .padding(14)
            Divider()
            if records.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray").font(.largeTitle).foregroundStyle(.tertiary)
                    Text("还没有记录。记录会自动存到 \(store.settings.data.notesFolder)。").foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filtered, selection: $picked) { r in
                    row(r)
                        .tag(r.id)
                        .contentShape(Rectangle())
                        .onTapGesture(count: 2) { open(r) }
                        .contextMenu {
                            Button("打开") { open(r) }
                            if let u = r.mdURL {
                                Button("在 Obsidian 中打开") { store.openFileInObsidian(u) }
                                Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([u]) }
                            }
                        }
                }
                .listStyle(.inset)
            }
            Divider()
            HStack {
                Button("新建一场记录") {
                    Task { await store.newSession(); dismiss() }
                }
                .disabled(store.isRecording)
                Spacer()
                Button("取消") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("打开") {
                    if let id = picked, let r = records.first(where: { $0.id == id }) { open(r) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(picked == nil || store.isRecording)
            }
            .padding(12)
        }
        .frame(width: 640, height: 520)
        .onAppear { records = store.listRecords() }
    }

    private func row(_ r: RecordInfo) -> some View {
        let isCurrent = r.sessionID == store.sessionID || r.mdURL?.path == store.markdownPath
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: isCurrent ? "record.circle" : "doc.text")
                .foregroundStyle(isCurrent ? Color.red : Color.secondary)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Text(r.title).font(.body.weight(.medium)).lineLimit(2)
                HStack(spacing: 8) {
                    Text("\(Fmt.day.string(from: r.date)) \(Fmt.hm(r.date))")
                    if !r.speaker.isEmpty { Text("· \(r.speaker)") }
                    if isCurrent { Text("· 当前").foregroundStyle(.red) }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    private func open(_ r: RecordInfo) {
        Task {
            if await store.open(r) { dismiss() }
        }
    }
}

/// 回放条：放录音、拖进度、调速度
struct PlayerBar: View {
    @Environment(SessionStore.self) private var store
    @State private var scrubbing: Double?

    var body: some View {
        let p = store.player
        HStack(spacing: 10) {
            Button { p.skip(-10) } label: { Image(systemName: "gobackward.10") }
                .buttonStyle(.borderless).help("后退 10 秒")
            Button { p.toggle() } label: {
                Image(systemName: p.isPlaying ? "pause.circle.fill" : "play.circle.fill").font(.title2)
            }
            .buttonStyle(.borderless)
            .help(p.isPlaying ? "暂停" : "播放录音")
            .disabled(p.parts.isEmpty)
            Button { p.skip(10) } label: { Image(systemName: "goforward.10") }
                .buttonStyle(.borderless).help("前进 10 秒")
            if p.parts.count > 1 {
                Menu(partLabel(p)) {
                    ForEach(Array(p.parts.enumerated()), id: \.offset) { i, part in
                        Button("\(Fmt.hm(part.start)) 开始\(part.duration == nil ? "（录音中）" : "")") { p.play(part: i) }
                            .disabled(part.duration == nil)
                    }
                }
                .fixedSize()
            }
            Slider(value: Binding(get: { scrubbing ?? p.time }, set: { scrubbing = $0 }),
                   in: 0...max(1, p.duration)) { editing in
                if !editing, let v = scrubbing { p.seek(v); scrubbing = nil }
            }
            .disabled(p.parts.isEmpty || p.duration <= 0)
            Text("\(clock(scrubbing ?? p.time)) / \(clock(p.duration))")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Menu("\(String(format: "%.2g", p.rate))×") {
                ForEach([0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { r in
                    Button("\(String(format: "%.2g", r))×") { p.setRate(Float(r)) }
                }
            }
            .fixedSize()
            .help("播放速度")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(.bar)
        .onAppear { if p.parts.isEmpty { store.reloadAudio() } }
    }

    private func partLabel(_ p: AudioPlayback) -> String {
        guard let i = p.current, p.parts.indices.contains(i) else { return "录音" }
        return "第 \(i + 1)/\(p.parts.count) 段"
    }

    private func clock(_ t: TimeInterval) -> String {
        let s = Int(max(0, t))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

/// 改一句转写
struct SegmentEditor: View {
    @Environment(SessionStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    let segment: Segment
    @State private var original = ""
    @State private var shown = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("修改 \(Fmt.clock(segment.time)) 这句").font(.headline)
            if segment.language == .english {
                Text("英文原文").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $original).frame(height: 90).border(.quaternary)
                Text("中文译文").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $shown).frame(height: 90).border(.quaternary)
            } else {
                TextEditor(text: $shown).frame(height: 140).border(.quaternary)
                Text("识别原文：\(segment.bestRaw)").font(.caption).foregroundStyle(.tertiary).lineLimit(3)
            }
            HStack {
                Button("删除这句", role: .destructive) {
                    store.deleteSegment(segment.id)
                    dismiss()
                }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存") {
                    if segment.language == .english {
                        store.updateSegment(segment.id, text: original == segment.bestRaw ? nil : original, secondary: shown)
                    } else {
                        store.updateSegment(segment.id, text: nil, secondary: shown)
                    }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 520)
        .onAppear {
            original = segment.bestRaw
            shown = segment.language == .english ? (segment.secondary ?? "") : (segment.secondary ?? segment.bestRaw)
        }
    }
}
