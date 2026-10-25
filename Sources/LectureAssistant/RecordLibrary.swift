import Foundation

/// 记录列表里的一项：笔记库里的一份讲座 Markdown（可能还有一份完整的 JSON 存档）
struct RecordInfo: Identifiable, Hashable {
    var id: String { mdURL?.path ?? sessionID.uuidString }
    var title: String
    var speaker: String
    var date: Date
    var mdURL: URL?
    var sessionID: UUID
    var hasArchive: Bool
    var modified: Date
    var segmentCount: Int?
}

enum RecordLibrary {
    /// 扫描讲座记录文件夹（和写不进笔记库时的备用文件夹）
    static func list(folders: [URL]) -> [RecordInfo] {
        var out: [RecordInfo] = []
        var seen = Set<UUID>()
        let fm = FileManager.default
        for dir in folders {
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { continue }
            for name in names where name.hasSuffix(".md") {
                let url = dir.appendingPathComponent(name)
                guard let head = readHead(url) else { continue }
                let fm0 = frontmatter(head)
                guard fm0["type"] == "讲座记录" || fm0["generated_by"] == "讲座助手" else { continue }
                let sid = fm0["session_id"].flatMap(UUID.init(uuidString:)) ?? UUID(namespace: url.path)
                if seen.contains(sid) { continue }
                seen.insert(sid)
                let title = head.split(separator: "\n").first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)) } ?? (name as NSString).deletingPathExtension
                let mod = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                out.append(RecordInfo(title: title, speaker: fm0["speaker"] ?? "", date: parseDate(fm0["date"], fileName: name) ?? mod,
                                      mdURL: url, sessionID: sid,
                                      hasArchive: fm.fileExists(atPath: SessionStoreArchive.url(sid).path), modified: mod))
            }
        }
        return out.sorted { $0.date > $1.date }
    }

    /// 载入一份记录。Markdown 比 JSON 新（在 Obsidian 里改过）就按 Markdown 解析
    static func load(_ r: RecordInfo) -> LectureSession? {
        let archive = SessionStoreArchive.url(r.sessionID)
        let jsonDate = (try? archive.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        if r.hasArchive, r.modified.timeIntervalSince(jsonDate) < 5,
           let data = try? Data(contentsOf: archive),
           var s = try? JSONDecoder().decode(LectureSession.self, from: data) {
            if let u = r.mdURL { s.markdownPath = u.path }
            return s
        }
        guard let u = r.mdURL, let text = try? String(contentsOf: u, encoding: .utf8) else { return nil }
        var s = MarkdownImporter.parse(text, fallbackDate: r.date)
        s.id = r.sessionID
        s.markdownPath = u.path
        return s
    }

    private static func readHead(_ url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        let d = (try? h.read(upToCount: 4000)) ?? Data()
        return String(decoding: d, as: UTF8.self)
    }

    static func frontmatter(_ text: String) -> [String: String] {
        guard text.hasPrefix("---") else { return [:] }
        var out: [String: String] = [:]
        for line in text.split(separator: "\n").dropFirst() {
            if line.hasPrefix("---") { break }
            if let r = line.range(of: ": ") {
                out[String(line[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)] = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            }
        }
        return out
    }

    static func parseDate(_ day: String?, fileName: String) -> Date? {
        // 文件名开头是 “yyyy-MM-dd HHmm”
        let stamp = String(fileName.prefix(15))
        if let d = Fmt.fileStamp.date(from: stamp) { return d }
        return day.flatMap { Fmt.day.date(from: $0) }
    }
}

/// 存档路径（SessionStore 是 MainActor，这里给非隔离代码用）
enum SessionStoreArchive {
    static func url(_ id: UUID) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LectureAssistant/sessions", isDirectory: true)
            .appendingPathComponent(id.uuidString + ".json")
    }
}

/// 把讲座助手导出的 Markdown 解析回一份记录（给没有 JSON 存档的旧记录用）
enum MarkdownImporter {
    static func parse(_ text: String, fallbackDate: Date) -> LectureSession {
        let fmv = RecordLibrary.frontmatter(text)
        let lines = text.components(separatedBy: "\n")
        let title = lines.first { $0.hasPrefix("# ") }.map { String($0.dropFirst(2)) } ?? "未命名讲座"
        let day = fmv["date"] ?? Fmt.day.string(from: fallbackDate)
        var s = LectureSession(title: title == "未命名讲座" ? "" : title, speaker: fmv["speaker"] ?? "", startedAt: fallbackDate)

        // 按 “## ” 切节
        var sections: [String: [String]] = [:]
        var current = ""
        for l in lines {
            if l.hasPrefix("## ") { current = String(l.dropFirst(3)).trimmingCharacters(in: .whitespaces); sections[current] = []; continue }
            if !current.isEmpty { sections[current, default: []].append(l) }
        }
        func body(_ name: String) -> String {
            (sections[name] ?? []).joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func time(_ hms: String) -> Date? {
            let f = DateFormatter()
            f.dateFormat = hms.count > 5 ? "yyyy-MM-dd HH:mm:ss" : "yyyy-MM-dd HH:mm"
            return f.date(from: "\(day) \(hms)")
        }

        let overall = body("累计摘要")
        s.overallSummary = overall == "（还没有生成）" ? "" : overall
        s.myNotes = body("我的笔记")

        for l in sections["录音"] ?? [] {
            if let a = l.range(of: "![["), let b = l.range(of: "]]") {
                s.audioFiles.append(String(l[a.upperBound..<b.lowerBound]))
            }
        }

        // 分段小结：### HH:MM–HH:MM
        for block in blocks(sections["分段小结"] ?? []) {
            let head = block.head
            let parts = head.components(separatedBy: "–")
            let from = time(parts.first?.trimmingCharacters(in: .whitespaces) ?? "") ?? fallbackDate
            let to = time(parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : "") ?? from
            s.summaries.append(SummaryBlock(createdAt: to, from: from, to: to, points: block.body))
        }

        // 疑问与解答：### Qn（HH:MM） 问题
        for block in blocks(sections["疑问与解答"] ?? []) {
            var quotes: [String] = []
            var question = ""
            var answer: [String] = []
            var refs: [VaultRef] = []
            var web: [WebRef] = []
            var inAnswer = false
            for l in block.body.components(separatedBy: "\n") {
                if !inAnswer, l.hasPrefix("> ") { quotes.append(String(l.dropFirst(2))); continue }
                if l.hasPrefix("**我的问题**：") { question = String(l.dropFirst("**我的问题**：".count)); continue }
                if l.hasPrefix("检索到的笔记：") {
                    for m in l.matches(of: #/\[\[([^\]|]+)(?:\|([^\]]+))?\]\]/#) {
                        refs.append(VaultRef(path: String(m.1) + ".md", title: m.2.map(String.init) ?? String(m.1)))
                    }
                    continue
                }
                if l.hasPrefix("- ["), let m = l.firstMatch(of: #/- \[(.*)\]\((.*)\)/#) { web.append(WebRef(url: String(m.2), title: String(m.1))); continue }
                if l == "网页来源：" { continue }
                if !l.trimmingCharacters(in: .whitespaces).isEmpty || inAnswer { inAnswer = true; answer.append(l) }
            }
            let hm = block.head.firstMatch(of: #/（(\d{1,2}:\d{2})）/#).map { String($0.1) }
            var q = QAItem(createdAt: hm.flatMap(time) ?? fallbackDate, quotes: quotes, question: question, webSearch: !web.isEmpty)
            q.answer = answer.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            q.vaultRefs = refs
            q.webRefs = web
            q.status = q.answer.isEmpty ? .failed : .done
            s.qas.insert(q, at: 0)
        }

        // 备选提问：### HH:MM （被点名速答）
        for block in blocks(sections["备选提问"] ?? []) {
            let hm = block.head.firstMatch(of: #/(\d{1,2}:\d{2})/#).map { String($0.1) }
            var q = QuestionSet(createdAt: hm.flatMap(time) ?? fallbackDate, kind: block.head.contains("速答") ? .quick : .full)
            q.content = block.body
            q.status = .done
            s.questionSets.insert(q, at: 0)
        }

        // 完整转写：**[HH:MM:SS]** 文本，后面可能跟 “> 识别原文：…”“> 校正：…” 或英文的 “> 译文”
        var segs: [Segment] = []
        for l in sections["完整转写"] ?? [] {
            if let m = l.firstMatch(of: #/^\*\*\[(\d{2}:\d{2}:\d{2})\]\*\* (.*)$/#) {
                let t = time(String(m.1)) ?? fallbackDate
                let txt = String(m.2)
                let english = txt.unicodeScalars.filter { $0.value > 0x2E80 }.count * 4 < txt.count
                segs.append(Segment(time: t, duration: 0, text: txt, language: english ? .english : .chinese))
            } else if l.hasPrefix("> "), var last = segs.popLast() {
                let q = String(l.dropFirst(2))
                if q.hasPrefix("识别原文：") {
                    last.secondary = last.text
                    last.text = String(q.dropFirst("识别原文：".count))
                } else if q.hasPrefix("校正：") {
                    last.secondary = String(q.dropFirst("校正：".count))
                } else {
                    last.secondary = q
                }
                segs.append(last)
            }
        }
        for i in segs.indices where i + 1 < segs.count {
            segs[i].duration = max(0, segs[i + 1].time.timeIntervalSince(segs[i].time))
        }
        s.segments = segs
        if let first = segs.first { s.startedAt = min(s.startedAt, first.time) }
        s.lastSummarizedSegmentID = s.summaries.isEmpty ? nil : segs.last?.id
        s.titleIsAuto = false
        s.speakerIsAuto = false
        return s
    }

    private struct Block { var head: String; var body: String }

    private static func blocks(_ lines: [String]) -> [Block] {
        var out: [Block] = []
        var head: String?
        var body: [String] = []
        for l in lines {
            if l.hasPrefix("### ") {
                if let h = head { out.append(Block(head: h, body: body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))) }
                head = String(l.dropFirst(4))
                body = []
            } else if head != nil {
                body.append(l)
            }
        }
        if let h = head { out.append(Block(head: h, body: body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines))) }
        return out
    }
}

extension UUID {
    /// 没有 session_id 的旧记录：按文件路径生成一个固定的 id
    init(namespace path: String) {
        var bytes = [UInt8](repeating: 0, count: 16)
        for (i, b) in path.utf8.enumerated() { bytes[i % 16] = bytes[i % 16] &* 31 &+ b }
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        self = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
