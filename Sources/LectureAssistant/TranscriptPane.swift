import SwiftUI
import AppKit

struct TranscriptPane: View {
    @Environment(SessionStore.self) private var store
    @EnvironmentObject private var settings: AppSettings
    @State private var followTail = true

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
        if !store.audioFiles.isEmpty {
            PlayerBar()
            Divider()
        }
        ZStack(alignment: .bottom) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        header
                        if store.segments.isEmpty && store.volatileText.isEmpty {
                            emptyHint
                        }
                        let playingID = playingSegmentID
                        ForEach(store.segments) { seg in
                            SegmentRow(segment: seg,
                                       isSelected: store.selected.contains(seg.id),
                                       isPlaying: seg.id == playingID,
                                       fontSize: settings.data.fontSize,
                                       autoSecondary: settings.data.autoSecondary)
                                .id(seg.id)
                        }
                        if !store.volatileText.isEmpty {
                            VolatileRow(text: store.volatileText, fontSize: settings.data.fontSize)
                        }
                        Color.clear.frame(height: store.selected.isEmpty ? 30 : 80).id("bottom")
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                }
                .onScrollGeometryChange(for: Bool.self) { geo in
                    geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 60
                } action: { _, atBottom in
                    followTail = atBottom
                }
                .onChange(of: store.segments.count) {
                    if followTail { withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo("bottom", anchor: .bottom) } }
                }
                .onChange(of: store.volatileText) {
                    if followTail { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                .overlay(alignment: .bottomTrailing) {
                    if !followTail {
                        Button {
                            followTail = true
                            withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                        } label: {
                            Label("回到最新", systemImage: "arrow.down.circle.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .padding(.trailing, 16)
                        .padding(.bottom, store.selected.isEmpty ? 12 : 64)
                    }
                }
            }
            if !store.selected.isEmpty {
                selectionBar
            }
        }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .sheet(item: Binding(get: { store.editingSegmentID.flatMap { id in store.segments.first { $0.id == id } } },
                             set: { store.editingSegmentID = $0?.id })) { seg in
            SegmentEditor(segment: seg)
        }
    }

    /// 正在回放到哪一句
    private var playingSegmentID: UUID? {
        guard let t = store.player.wallTime else { return nil }
        return store.segments.last(where: { $0.time <= t.addingTimeInterval(0.3) })?.id
    }

    private var header: some View {
        let titleBinding = Binding<String>(get: { store.title }, set: { store.title = $0; store.titleIsAuto = false })
        let speakerBinding = Binding<String>(get: { store.speaker }, set: { store.speaker = $0; store.speakerIsAuto = false })
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("未命名讲座（开讲后 AI 会根据内容自动拟题，也可以直接在这里写）", text: titleBinding)
                    .textFieldStyle(.plain)
                    .font(.system(size: 20, weight: .semibold))
                    .onSubmit { store.scheduleSave() }
                    .help("点这里直接改题目；改过之后 AI 就不会再自动改")
                if store.titleIsAuto && !store.title.isEmpty {
                    Text("AI 拟").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }
                Button {
                    Task { await store.proposeTitle(force: true) }
                } label: {
                    if store.isProposingTitle { ProgressView().controlSize(.small) } else { Label("AI 拟题", systemImage: "sparkles") }
                }
                .controlSize(.small)
                .disabled(store.segments.isEmpty || store.isProposingTitle)
                .help("根据目前的内容重新拟题目和汇报人")
            }
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
                TextField("汇报人", text: speakerBinding)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
                    .onSubmit { store.scheduleSave() }
                    .help("随时可以改；改过之后 AI 就不会再自动改")
                Text("\(Fmt.day.string(from: store.startedAt)) \(Fmt.hm(store.startedAt))")
                Spacer()
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
        .padding(.bottom, 8)
        .onChange(of: store.title) { store.scheduleSave() }
        .onChange(of: store.speaker) { store.scheduleSave() }
    }

    private var emptyHint: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("点左上角「开始」，讲座的话会实时出现在这里。", systemImage: "mic")
            Label("英文讲座先在顶部选「英文 → 中文」，每句下面会出中文翻译；中文讲座会自动校正识别错字。", systemImage: "character.bubble")
            Label("听不懂的句子直接点一下（可多选），再点下面的「问 AI」，它会结合你的笔记解释。", systemImage: "hand.tap")
            Label("右边「提问」帮你准备问题；被点名时按工具栏的「被点名了」。", systemImage: "hand.raised")
            Label("所有内容自动保存到 Obsidian：\(settings.data.notesFolder)", systemImage: "square.and.arrow.down")
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        .padding(.vertical, 20)
    }

    private var selectionBar: some View {
        HStack(spacing: 10) {
            Text("已选 \(store.selected.count) 句").font(.callout.weight(.medium))
            Spacer()
            Button("清除") { store.selected = [] }
            Button {
                store.sideTab = .qa
            } label: {
                Label("写下疑问", systemImage: "square.and.pencil")
            }
            Button {
                store.askAboutSelection()
            } label: {
                Label("直接问 AI", systemImage: "sparkles")
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.return, modifiers: .command)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        .padding(.horizontal, 16)
        .padding(.bottom, 12)
    }
}

struct SegmentRow: View {
    @Environment(SessionStore.self) private var store
    let segment: Segment
    let isSelected: Bool
    var isPlaying = false
    let fontSize: Double
    let autoSecondary: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                store.playFrom(segment)
            } label: {
                HStack(spacing: 2) {
                    Text(Fmt.clock(segment.time))
                    if isPlaying { Image(systemName: "speaker.wave.2.fill").font(.system(size: 9)) }
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(isPlaying ? Color.accentColor : Color.secondary.opacity(0.6))
            }
            .buttonStyle(.plain)
            .frame(width: 66, alignment: .leading)
            .padding(.top, 3)
            .help("从这句开始播放录音")
            VStack(alignment: .leading, spacing: 4) {
                if segment.language == .english {
                    Text(segment.bestRaw)
                        .font(.system(size: fontSize * 0.93))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(rawHelp)
                    secondaryLine
                } else {
                    Text(segment.secondary ?? segment.bestRaw)
                        .font(.system(size: fontSize))
                        .fixedSize(horizontal: false, vertical: true)
                    if let s = segment.secondary, s != segment.bestRaw {
                        Text("识别原文：\(segment.bestRaw)")
                            .font(.system(size: fontSize * 0.75))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .help(rawHelp)
                    } else if segment.secondaryFailed {
                        Text("校正失败").font(.caption2).foregroundStyle(.orange)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : Color.secondary.opacity(0.35))
                .font(.system(size: 15))
                .padding(.top, 2)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(isSelected ? Color.accentColor.opacity(0.13) : (isPlaying ? Color.yellow.opacity(0.16) : Color.clear), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { store.editingSegmentID = segment.id }
        .onTapGesture { store.toggleSelect(segment.id) }
        .contextMenu {
            Button("从这里播放录音") { store.playFrom(segment) }
            Button("修改这句…") { store.editingSegmentID = segment.id }
            Divider()
            Button("复制原文") { copy(segment.bestRaw) }
            if let s = segment.secondary { Button(segment.language == .english ? "复制译文" : "复制校正文本") { copy(s) } }
            Divider()
            Button("问 AI 这一句") {
                store.selected = [segment.id]
                store.askAboutSelection()
            }
            Button("重新翻译/校正") { store.enqueueSecondary([segment.id]) }
            Divider()
            Button("删除这句", role: .destructive) { store.deleteSegment(segment.id) }
        }

    }

    private var rawHelp: String {
        var lines = ["系统识别：\(segment.text)"]
        for (k, v) in (segment.localEngines ?? [:]).sorted(by: { $0.key < $1.key }) { lines.append("\(k)：\(v)") }
        return lines.joined(separator: "\n")
    }

    @ViewBuilder
    private var secondaryLine: some View {
        if let zh = segment.secondary {
            Text(zh).font(.system(size: fontSize * 1.05)).fixedSize(horizontal: false, vertical: true)
        } else if segment.secondaryFailed {
            HStack(spacing: 6) {
                Text("翻译失败").foregroundStyle(.orange)
                Button("重试") { store.enqueueSecondary([segment.id]) }.buttonStyle(.link)
            }
            .font(.caption)
        } else if autoSecondary {
            Text("翻译中…").font(.system(size: fontSize * 0.85)).foregroundStyle(.tertiary)
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

struct VolatileRow: View {
    let text: String
    let fontSize: Double
    @State private var pulse = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(Color.red)
                .frame(width: 7, height: 7)
                .opacity(pulse ? 0.25 : 1)
                .animation(.easeInOut(duration: 0.8).repeatForever(), value: pulse)
                .frame(width: 58, alignment: .leading)
                .padding(.top, 6)
            Text(text)
                .font(.system(size: fontSize))
                .foregroundStyle(.secondary)
                .italic()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .onAppear { pulse = true }
    }
}
