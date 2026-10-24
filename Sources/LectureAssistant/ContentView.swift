import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(SessionStore.self) private var store
    @EnvironmentObject private var settings: AppSettings
    @State private var importing = false

    var body: some View {
        VStack(spacing: 0) {
            if let b = store.banner { BannerView(banner: b) }
            HSplitView {
                TranscriptPane()
                    .frame(minWidth: 480, idealWidth: 760, maxWidth: .infinity)
                SidePane()
                    .frame(minWidth: 380, idealWidth: 480, maxWidth: 620)
            }
            StatusBar()
        }
        .toolbar { toolbar }
        .navigationTitle(store.title)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio, .mpeg4Audio, .wav, .aiff, .mp3]) { result in
            if case .success(let url) = result {
                let access = url.startAccessingSecurityScopedResource()
                Task {
                    await store.importAudio(url)
                    if access { url.stopAccessingSecurityScopedResource() }
                }
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            RecordButton()
            LevelMeter(level: store.level, active: store.isRecording)
                .frame(width: 70, height: 14)
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(Fmt.elapsed(store.elapsed))
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(store.isRecording ? .primary : .secondary)
            }
        }
        ToolbarItem(placement: .principal) {
            Picker("讲座语言", selection: Binding(get: { store.language }, set: { store.setLanguage($0) })) {
                ForEach(LectureLanguage.allCases) { Text($0 == .english ? "英文 → 中文" : "中文").tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 190)
            .help("讲座用什么语言。英文会自动翻译成中文；录音中途也可以切换")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button {
                Task { await store.summarize() }
            } label: {
                Label("立即总结", systemImage: "text.badge.star")
            }
            .disabled(store.isSummarizing || store.segments.isEmpty)
            .help("马上总结还没总结过的内容（平时每 \(settings.data.summaryIntervalMin) 分钟自动一次）")

            Button {
                store.generateQuestions(.quick)
            } label: {
                Label("被点名了", systemImage: "hand.raised.fill")
            }
            .help("马上给我一个能问的问题（⌘J）")

            Menu {
                Button("打开记录（Obsidian）") { store.openMarkdown() }
                Button("在访达中显示") { store.revealMarkdown() }
                Divider()
                Button("导入录音文件转写…") { importing = true }
                    .disabled(store.importProgress != nil || store.isRecording)
                Button("重试失败的翻译/校正") { store.retryFailedSecondary() }
                Button("重新索引笔记库") { Task { await store.reindexVault(); store.flash("已索引 \(store.vaultDocCount) 篇笔记") } }
                Divider()
                Button("新建一场记录") { Task { await store.newSession() } }
            } label: {
                Label("更多", systemImage: "ellipsis.circle")
            }
            SettingsLink {
                Label("设置", systemImage: "gearshape")
            }
        }
    }
}

struct RecordButton: View {
    @Environment(SessionStore.self) private var store

    var body: some View {
        Button {
            store.toggleRecording()
        } label: {
            HStack(spacing: 6) {
                if store.isStarting {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: store.isRecording ? "stop.fill" : "mic.fill")
                }
                Text(store.isRecording ? "停止" : (store.recordedSeconds > 0 ? "继续" : "开始"))
            }
            .padding(.horizontal, 6)
        }
        .buttonStyle(.borderedProminent)
        .tint(store.isRecording ? .red : .accentColor)
        .help(store.isRecording ? "停止录音（⌘R）" : "开始听讲（⌘R）")
    }
}

struct LevelMeter: View {
    var level: Float
    var active: Bool

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(level > 0.85 ? Color.orange : Color.green)
                    .frame(width: max(4, geo.size.width * CGFloat(active ? level : 0)))
                    .animation(.linear(duration: 0.1), value: level)
            }
        }
        .help("麦克风音量")
    }
}

struct BannerView: View {
    @Environment(SessionStore.self) private var store
    let banner: SessionStore.Banner

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: banner.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .foregroundStyle(banner.isError ? .orange : .green)
            Text(banner.text).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Spacer()
            if let a = banner.action {
                Button(actionTitle(a)) { store.perform(a) }
            }
            Button {
                store.dismissBanner()
            } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(banner.isError ? Color.orange.opacity(0.12) : Color.green.opacity(0.10))
    }

    private func actionTitle(_ a: SessionStore.Banner.Action) -> String {
        switch a {
        case .openMicSettings: return "打开麦克风设置"
        case .openDictationSettings: return "打开键盘设置"
        case .openSettings: return "打开设置"
        case .newSession: return "新建记录"
        }
    }
}

struct StatusBar: View {
    @Environment(SessionStore.self) private var store

    var body: some View {
        HStack(spacing: 12) {
            HStack(spacing: 5) {
                Circle().fill(store.lastAPIError == nil ? Color.green : Color.orange).frame(width: 7, height: 7)
                if let e = store.lastAPIError {
                    Text("AI 出错：\(e)").lineLimit(1).truncationMode(.tail)
                } else {
                    Text(store.lastAPIOK == nil ? "AI 待命" : "AI 正常")
                }
            }
            if store.secondaryPending > 0 {
                Text("\(store.language == .english ? "翻译" : "校正")排队 \(store.secondaryPending)")
            }
            if store.isSummarizing { Text("正在总结…") }
            if let p = store.importProgress {
                ProgressView(value: p).frame(width: 80)
                Text("导入中 \(Int(p * 100))%")
            }
            Spacer()
            Text("笔记库 \(store.vaultDocCount) 篇")
            if let t = store.lastSavedAt {
                Button {
                    store.revealMarkdown()
                } label: {
                    Text("已保存 \(Fmt.clock(t)) · \(store.markdownURL.lastPathComponent)")
                }
                .buttonStyle(.link)
                .help(store.markdownURL.path)
            } else {
                Text("自动保存到 Obsidian")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: 26)
        .background(.bar)
    }
}
