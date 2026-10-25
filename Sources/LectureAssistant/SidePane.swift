import SwiftUI
import AppKit

struct SidePane: View {
    @Environment(SessionStore.self) private var store

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            Picker("", selection: $store.sideTab) {
                ForEach(SessionStore.SideTab.allCases) { tab in
                    Text(label(tab)).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(10)
            Divider()
            switch store.sideTab {
            case .summary: SummaryTab()
            case .qa: QATab()
            case .questions: QuestionsTab()
            case .notes: NotesTab()
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func label(_ t: SessionStore.SideTab) -> String {
        switch t {
        case .qa: return store.qas.isEmpty ? "疑问" : "疑问 \(store.qas.count)"
        case .questions: return store.questionSets.isEmpty ? "提问" : "提问 \(store.questionSets.count)"
        default: return t.rawValue
        }
    }
}

private func copyToPasteboard(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

struct Card<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
    }
}

// MARK: 摘要

struct SummaryTab: View {
    @Environment(SessionStore.self) private var store
    @EnvironmentObject private var settings: AppSettings
    @State private var editing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("整场摘要").font(.headline)
                    Spacer()
                    if store.isSummarizing { ProgressView().controlSize(.small) }
                    if !store.overallSummary.isEmpty || editing {
                        Button(editing ? "完成" : "修改") {
                            if editing { store.scheduleSave() }
                            editing.toggle()
                        }
                    }
                    Button("立即总结") { Task { await store.summarize() } }
                        .disabled(store.isSummarizing || store.segments.isEmpty)
                }
                if let live = store.liveSummary {
                    Card {
                        Label("正在总结最新一段…", systemImage: "sparkles").font(.caption).foregroundStyle(.secondary)
                        MarkdownText(text: live.isEmpty ? "…" : live, fontSize: 13)
                    }
                }
                if editing {
                    @Bindable var store = store
                    TextEditor(text: $store.overallSummary)
                        .font(.system(size: 13))
                        .frame(minHeight: 260)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                } else if store.overallSummary.isEmpty {
                    Text("开始录音后每 \(settings.data.summaryIntervalMin) 分钟自动总结一次，也可以随时点「立即总结」。")
                        .foregroundStyle(.secondary)
                        .font(.callout)
                } else {
                    Card { MarkdownText(text: store.overallSummary, fontSize: 14) }
                        .contextMenu { Button("复制") { copyToPasteboard(store.overallSummary) } }
                }
                if !store.summaries.isEmpty {
                    Text("分段小结").font(.headline).padding(.top, 6)
                    ForEach(store.summaries.reversed()) { b in
                        Card {
                            Text("\(Fmt.hm(b.from))–\(Fmt.hm(b.to))")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            MarkdownText(text: b.points, fontSize: 13)
                        }
                        .contextMenu {
                            Button("复制") { copyToPasteboard(b.points) }
                            Button("删除这段小结", role: .destructive) { store.deleteSummary(b.id) }
                        }
                    }
                }
            }
            .padding(14)
        }
    }
}

// MARK: 疑问

struct QATab: View {
    @Environment(SessionStore.self) private var store
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var store = store
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                if store.selected.isEmpty {
                    Text("在左边点选让你困惑的句子（可多选），或者直接在下面写问题。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(store.selectedSegments) { s in
                            Text("“\(s.secondary ?? s.text)”")
                                .lineLimit(2)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxHeight: 110)
                }
                TextField("我的疑问（可不填，比如：他说的算子学习和我做的 GNN 有什么区别？）", text: $store.qaDraft, axis: .vertical)
                    .lineLimit(2...6)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { store.askAboutSelection() }
                HStack {
                    Toggle("联网搜索", isOn: $store.qaWebSearch)
                        .toggleStyle(.checkbox)
                        .help("让 AI 上网核实论文、方法名（慢一些，约多 10–20 秒）")
                    Spacer()
                    if !store.selected.isEmpty {
                        Button("清除选择") { store.selected = [] }
                    }
                    Button {
                        store.askAboutSelection()
                    } label: {
                        Label("问 AI", systemImage: "sparkles")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!store.canAsk)
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.25))
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if store.qas.isEmpty {
                        Text("AI 会结合讲座上下文、你的背景和 Obsidian 里的相关笔记来解释。")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    }
                    ForEach(store.qas) { q in
                        QACard(item: q)
                            .contextMenu {
                                Button("复制回答") { copyToPasteboard(q.answer) }
                                Button("重新回答") { store.retryQA(q.id) }
                                Button("删除这条", role: .destructive) { store.deleteQA(q.id) }
                            }
                    }
                }
                .padding(14)
            }
        }
        .onChange(of: store.selected) {
            if !store.selected.isEmpty, store.sideTab == .qa { focused = true }
        }
    }
}

struct QACard: View {
    @Environment(SessionStore.self) private var store
    let item: QAItem

    var body: some View {
        Card {
            HStack {
                Text(Fmt.hm(item.createdAt)).font(.caption).foregroundStyle(.secondary)
                if item.webSearch { Label("联网", systemImage: "globe").font(.caption2).foregroundStyle(.secondary) }
                Spacer()
                switch item.status {
                case .running: ProgressView().controlSize(.small)
                case .failed:
                    Button("重试") { store.retryQA(item.id) }.controlSize(.small)
                case .done:
                    Button {
                        copyToPasteboard(item.answer)
                    } label: { Image(systemName: "doc.on.doc") }
                        .buttonStyle(.borderless)
                        .help("复制回答")
                }
            }
            ForEach(Array(item.quotes.enumerated()), id: \.offset) { _, q in
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 1).fill(Color.accentColor.opacity(0.6)).frame(width: 3)
                    Text(q).font(.callout).foregroundStyle(.secondary).lineLimit(4)
                }
            }
            if !item.question.isEmpty {
                Text(item.question).font(.callout.weight(.medium))
            }
            if item.answer.isEmpty {
                Text(item.status == .failed ? (item.error ?? "失败") : (item.error ?? (item.vaultRefs.isEmpty ? "检索笔记中…" : "思考中…")))
                    .font(.callout)
                    .foregroundStyle(item.status == .failed ? .orange : .secondary)
            } else {
                if item.status == .running, let e = item.error {
                    Text(e).font(.caption).foregroundStyle(.secondary)
                }
                MarkdownText(text: item.answer, fontSize: 13.5)
                if item.status == .failed, let e = item.error {
                    Text(e).font(.caption).foregroundStyle(.orange)
                }
            }
            if !item.vaultRefs.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("检索到的笔记").font(.caption).foregroundStyle(.secondary)
                    ForEach(item.vaultRefs, id: \.self) { r in
                        Button {
                            store.openVaultNote(r.path)
                        } label: {
                            Label(r.title, systemImage: "doc.text").lineLimit(1)
                        }
                        .buttonStyle(.link)
                        .font(.caption)
                        .help(r.path)
                    }
                }
            }
            if !item.webRefs.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("网页来源").font(.caption).foregroundStyle(.secondary)
                    ForEach(item.webRefs.prefix(6), id: \.self) { r in
                        if let u = URL(string: r.url) {
                            Link(destination: u) { Label(r.title, systemImage: "link").lineLimit(1) }
                                .font(.caption)
                        }
                    }
                }
            }
        }
    }
}

// MARK: 提问

struct QuestionsTab: View {
    @Environment(SessionStore.self) private var store

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Button {
                        store.generateQuestions(.full)
                    } label: {
                        Label("生成问题清单", systemImage: "list.bullet.rectangle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button {
                        store.generateQuestions(.quick)
                    } label: {
                        Label("被点名了！马上给一个", systemImage: "hand.raised.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
                .controlSize(.large)
                Text("问题会结合讲座摘要、他最近讲的内容、你的研究和发展方向。讲到一半和快结束时各生成一次比较好。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(.quaternary.opacity(0.25))
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    ForEach(store.questionSets) { set in
                        Card {
                            HStack {
                                Text(set.kind == .quick ? "速答 · \(Fmt.hm(set.createdAt))" : "问题清单 · \(Fmt.hm(set.createdAt))")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(set.kind == .quick ? .red : .secondary)
                                Spacer()
                                if set.status == .running { ProgressView().controlSize(.small) }
                                Button {
                                    copyToPasteboard(set.content)
                                } label: { Image(systemName: "doc.on.doc") }
                                    .buttonStyle(.borderless)
                                    .help("复制")
                            }
                            if set.content.isEmpty {
                                Text(set.status == .failed ? (set.error ?? "失败") : "生成中…")
                                    .foregroundStyle(set.status == .failed ? .orange : .secondary)
                            } else {
                                MarkdownText(text: set.content, fontSize: set.kind == .quick ? 15 : 13.5)
                            }
                            if set.status == .failed, !set.content.isEmpty, let e = set.error {
                                Text(e).font(.caption).foregroundStyle(.orange)
                            }
                        }
                        .contextMenu {
                            Button("复制") { copyToPasteboard(set.content) }
                            Button("删除", role: .destructive) { store.deleteQuestionSet(set.id) }
                        }
                    }
                }
                .padding(14)
            }
        }
    }
}

// MARK: 笔记

struct NotesTab: View {
    @Environment(SessionStore.self) private var store

    var body: some View {
        @Bindable var store = store
        VStack(alignment: .leading, spacing: 6) {
            Text("随手记（会一起存进 Obsidian 记录）").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $store.myNotes)
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        }
        .padding(12)
        .onChange(of: store.myNotes) { store.scheduleSave() }
    }
}
