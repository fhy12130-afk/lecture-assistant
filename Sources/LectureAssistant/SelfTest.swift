import Foundation
import SwiftUI
import AppKit

/// 无界面自测：用一段录音走完 识别 → 翻译/校正 → 总结 → 检索解惑 → 提问 → 写 Markdown 全流程。
/// 用法：LectureAssistant --selftest <音频> [--lang en|zh] [--out 目录] [--full] [--web] [--render 目录]
enum SelfTest {
    static func launch() {
        setvbuf(stdout, nil, _IONBF, 0)
        Task { @MainActor in
            let code = await run()
            exit(code)
        }
        RunLoop.main.run()
    }

    private static func arg(_ name: String) -> String? {
        let a = CommandLine.arguments
        guard let i = a.firstIndex(of: name), i + 1 < a.count else { return nil }
        return a[i + 1]
    }

    private static func flag(_ name: String) -> Bool { CommandLine.arguments.contains(name) }

    @MainActor
    private static func waitUntil(_ timeout: TimeInterval, _ cond: () -> Bool) async -> Bool {
        let t0 = Date()
        while !cond() {
            if Date().timeIntervalSince(t0) > timeout { return false }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return true
    }

    @MainActor
    static func run() async -> Int32 {
        if let q = arg("--searchtest") { return await searchTest(q) }
        if let dir = arg("--savetest") { return await saveTest(URL(fileURLWithPath: dir, isDirectory: true)) }
        if flag("--libtest") { return await libTest() }
        if let demo = arg("--renderdemo") {
            let store = SessionStore(restore: false)
            store.loadDemo(URL(fileURLWithPath: demo))
            render(store: store, to: URL(fileURLWithPath: arg("--render") ?? "/tmp/lecture-render", isDirectory: true))
            return 0
        }
        guard let audio = arg("--selftest") else { print("缺少音频路径"); return 2 }
        let lang: LectureLanguage = arg("--lang") == "en" ? .english : .chinese
        let out = URL(fileURLWithPath: arg("--out") ?? "/tmp/lecture-selftest", isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        var failures: [String] = []

        let store = SessionStore(restore: false)
        store.isDemo = true            // 不碰应用真正的崩溃恢复快照
        store.notesDirOverride = out
        store.audioDirOverride = out
        store.title = ""
        store.titleIsAuto = true
        await store.reindexVault()
        print("== 笔记库：\(store.vaultDocCount) 篇，固定笔记 \(store.pinnedCache.count) 篇")
        await store.startLocalASR()
        print("== 本地引擎：\(store.localASRNames.isEmpty ? "没有" : store.localASRNames.joined(separator: ", "))")
        if store.vaultDocCount == 0 { failures.append("vault") }

        store.setLanguage(lang)
        var t0 = Date()
        if let sp = arg("--live") {
            // 按实时速度喂音频，走麦克风同一条路径；同时记录每句的翻译延迟
            var arrived: [UUID: Date] = [:]
            var latency: [Double] = []
            await store.startSimulated(URL(fileURLWithPath: audio), speed: Double(sp) ?? 1)
            while store.isRecording || !store.secondaryIdle {
                for s in store.segments where arrived[s.id] == nil {
                    arrived[s.id] = Date()
                    print(String(format: "  +%5.1fs 定稿 %3d 字：", Date().timeIntervalSince(t0), s.text.count) + s.text.prefix(60))
                }
                for s in store.segments where s.secondary != nil {
                    if let a = arrived[s.id], a != .distantPast {
                        latency.append(Date().timeIntervalSince(a))
                        arrived[s.id] = .distantPast
                    }
                }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            let avg = latency.isEmpty ? 0 : latency.reduce(0, +) / Double(latency.count)
            print(String(format: "== 实时模式：%d 句，翻译/校正平均延迟 %.1fs，最大 %.1fs，录音 %@", store.segments.count, avg, latency.max() ?? 0, store.audioFiles.joined(separator: ",")))
        } else {
            await store.importAudio(URL(fileURLWithPath: audio))
        }
        print("== 识别（\(lang.label)）：\(store.segments.count) 句，用时 \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
        if let b = store.banner, b.isError { print("   提示：\(b.text)") }
        if store.segments.isEmpty { failures.append("asr"); return finish(failures) }

        t0 = Date()
        let idle = await waitUntil(180) { store.secondaryIdle }
        print("== \(lang == .english ? "翻译" : "校正")：\(idle ? "完成" : "超时")，用时 \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
        for s in store.segments {
            print("  [\(Fmt.clock(s.time))] \(s.text)")
            for (k, v) in (s.localEngines ?? [:]).sorted(by: { $0.key < $1.key }) { print("     \(k)：\(v)") }
            print("     → \(s.secondary ?? (s.secondaryFailed ? "（失败）" : "（无）"))")
        }
        if store.segments.contains(where: { $0.secondary == nil }) { failures.append("secondary") }

        _ = await waitUntil(40) { !store.isProposingTitle }
        print("== 识别模型：\(store.asrKindName ?? "（文件模式）")；题目：\(store.displayTitle)（自动=\(store.titleIsAuto)）；汇报人：\(store.speaker)")
        t0 = Date()
        await store.summarize()
        print("== 总结：用时 \(String(format: "%.1f", Date().timeIntervalSince(t0)))s，分段 \(store.summaries.count)")
        print(store.summaries.last?.points ?? "（无）")
        print("-- 累计摘要：\n\(store.overallSummary)")
        if store.overallSummary.isEmpty { failures.append("summary") }

        // 选两句问 AI
        let pick = store.segments.count >= 2 ? Array(store.segments.suffix(2)) : store.segments
        store.selected = Set(pick.map(\.id))
        store.qaDraft = lang == .english ? "他说的 solution operator 是什么意思？和逐步预测的模型有什么区别？" : "神经算子和普通的神经网络代理模型有什么区别？"
        store.qaWebSearch = flag("--web")
        t0 = Date()
        if let id = store.askAboutSelection() {
            _ = await waitUntil(240) { store.qas.first(where: { $0.id == id })?.status != .running }
            let q = store.qas.first { $0.id == id }!
            print("== 解惑：\(q.status)，用时 \(String(format: "%.1f", Date().timeIntervalSince(t0)))s，笔记 \(q.vaultRefs.map(\.title))，网页 \(q.webRefs.count)")
            print(q.answer.isEmpty ? (q.error ?? "") : q.answer)
            if q.status != .done { failures.append("qa") }
        } else { failures.append("qa-start") }

        t0 = Date()
        if let id = store.generateQuestions(.quick) {
            _ = await waitUntil(180) { store.questionSets.first(where: { $0.id == id })?.status != .running }
            let s = store.questionSets.first { $0.id == id }!
            print("== 速答问题：\(s.status)，用时 \(String(format: "%.1f", Date().timeIntervalSince(t0)))s\n\(s.content.isEmpty ? (s.error ?? "") : s.content)")
            if s.status != .done { failures.append("quick") }
        }
        if flag("--full") {
            t0 = Date()
            if let id = store.generateQuestions(.full) {
                _ = await waitUntil(300) { store.questionSets.first(where: { $0.id == id })?.status != .running }
                let s = store.questionSets.first { $0.id == id }!
                print("== 问题清单：\(s.status)，用时 \(String(format: "%.1f", Date().timeIntervalSince(t0)))s\n\(s.content.isEmpty ? (s.error ?? "") : s.content)")
                if s.status != .done { failures.append("full") }
            }
        }

        store.flushSaves()
        if let json = try? JSONEncoder().encode(store.snapshot()) { try? json.write(to: out.appendingPathComponent("session.json")) }
        let md = store.markdownURL
        let size = (try? FileManager.default.attributesOfItem(atPath: md.path)[.size] as? Int) ?? 0
        print("== Markdown：\(md.path)（\(size) 字节）")
        if size == 0 { failures.append("markdown") }

        if let dir = arg("--render") { render(store: store, to: URL(fileURLWithPath: dir, isDirectory: true)) }
        return finish(failures)
    }

    /// 只读：列出真实记录、逐个载入、检查录音能不能对上
    @MainActor
    static func libTest() async -> Int32 {
        let store = SessionStore(restore: false)
        store.isDemo = true
        let recs = store.listRecords()
        print("== 记录 \(recs.count) 份")
        var bad = 0
        for r in recs {
            guard let s = RecordLibrary.load(r) else { print("  ✗ 载入失败 \(r.title)"); bad += 1; continue }
            print("  · \(Fmt.day.string(from: r.date)) \(Fmt.hm(r.date)) \(r.title)｜\(r.speaker)｜存档=\(r.hasArchive) 句=\(s.segments.count) 小结=\(s.summaries.count) 问答=\(s.qas.count) 提问=\(s.questionSets.count) 录音=\(s.audioFiles)")
            store.apply(s)
            let parts = store.player.parts
            for p in parts { print("      录音 \(p.name) 开始 \(Fmt.clock(p.start)) 时长 \(p.duration.map { String(format: "%.0fs", $0) } ?? "打不开")") }
            if let seg = s.segments.dropFirst(s.segments.count / 2).first, !parts.isEmpty {
                store.player.play(at: seg.time)
                let ok = store.player.isPlaying
                print("      从 \(Fmt.clock(seg.time)) 播放：\(ok ? "第\((store.player.current ?? 0) + 1)段 偏移 \(String(format: "%.1f", store.player.time))s" : (store.player.message ?? "失败"))")
                if let w = store.player.wallTime { print("      播放位置对应 \(Fmt.clock(w))") }
                store.player.stop()
            }
        }
        return bad == 0 ? 0 : 1
    }

    /// 回归测试：新建记录、改题目之后，之前的记录文件不能被删
    @MainActor
    static func saveTest(_ dir: URL) async -> Int32 {
        try? FileManager.default.removeItem(at: dir)
        let store = SessionStore(restore: false)
        store.isDemo = true
        store.notesDirOverride = dir
        let oldAuto = store.settings.data.autoSecondary
        defer { store.settings.data.autoSecondary = oldAuto }
        store.settings.data.autoSecondary = false
        func fake(_ t: String) -> SpeechEngine.FinalResult { .init(text: t, start: Date(), duration: 2, language: .chinese) }
        store.title = ""; store.titleIsAuto = true
        store.addFinal(fake("第一场的第一句"))
        store.flushSaves(); try? await Task.sleep(nanoseconds: 300_000_000)
        store.title = "第一场"; store.flushSaves(); try? await Task.sleep(nanoseconds: 300_000_000)
        try? await Task.sleep(nanoseconds: 61_000_000_000)   // 换一分钟，保证第二场的时间戳不同
        await store.newSession()
        store.addFinal(fake("第二场的第一句"))
        store.flushSaves(); try? await Task.sleep(nanoseconds: 300_000_000)
        store.title = "第二场"; store.flushSaves(); try? await Task.sleep(nanoseconds: 500_000_000)
        store.flushSaves(); try? await Task.sleep(nanoseconds: 500_000_000)
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
        print("== 文件：\(files)")
        let ok = files.contains { $0.hasSuffix("第一场.md") } && files.contains { $0.hasSuffix("第二场.md") } && files.count == 2
        print(ok ? "== 全部通过" : "== 失败：之前的记录丢了或多了文件")
        return ok ? 0 : 1
    }

    @MainActor
    static func searchTest(_ q: String) async -> Int32 {
        let store = SessionStore(restore: false)
        await store.reindexVault()
        print("docs:", store.vaultDocCount)
        guard let client = store.makeClient() else { return 1 }
        let kws = await Assistant.keywords(for: q, client: client, model: store.settings.data.fastModel)
        print("keywords:", kws)
        let hits = await store.vault.search(kws)
        for h in hits { print(String(format: "%.2f", h.score), h.path); for s in h.snippets { print("   ", s.prefix(160).replacingOccurrences(of: "\n", with: " ")) } }
        print("local keywords:", VaultSearch.localKeywords(q))
        return 0
    }

    private static func finish(_ failures: [String]) -> Int32 {
        print(failures.isEmpty ? "== 全部通过" : "== 失败项：\(failures.joined(separator: ", "))")
        return failures.isEmpty ? 0 : 1
    }

    /// 把几个主要视图离屏渲染成 PNG，检查排版
    @MainActor
    static func render(store: SessionStore, to dir: URL) {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let settings = AppSettings.shared
        func save<V: View>(_ name: String, _ v: V, width: CGFloat, height: CGFloat) {
            let r = ImageRenderer(content: v.environment(store).environmentObject(settings).frame(width: width, height: height))
            r.scale = 2
            guard let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { print("渲染失败：\(name)"); return }
            try? png.write(to: dir.appendingPathComponent(name + ".png"))
            print("== 渲染：\(dir.appendingPathComponent(name + ".png").path)")
        }
        let rows = VStack(alignment: .leading, spacing: 6) {
            ForEach(store.segments) { seg in
                SegmentRow(segment: seg, isSelected: seg.id == store.segments.first?.id, fontSize: settings.data.fontSize, autoSecondary: true)
            }
            VolatileRow(text: "and the next thing I want to show is", fontSize: settings.data.fontSize)
        }.padding()
        save("transcript", rows.background(Color.white), width: 720, height: 600)
        save("content", ContentView(), width: 1280, height: 800)
        save("side", SidePane(), width: 480, height: 800)
        if let q = store.qas.first { save("qa", QACard(item: q).padding().background(Color.white), width: 460, height: 900) }
        let summary = VStack(alignment: .leading) {
            Card { MarkdownText(text: store.overallSummary, fontSize: 14) }
            ForEach(store.summaries) { b in Card { MarkdownText(text: b.points, fontSize: 13) } }
        }.padding()
        save("summary", summary.background(Color.white), width: 460, height: 800)
        if let s = store.questionSets.first {
            save("questions", Card { MarkdownText(text: s.content, fontSize: 14) }.padding().background(Color.white), width: 460, height: 700)
        }
    }
}
