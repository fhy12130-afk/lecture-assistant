import Foundation

enum MarkdownExporter {
    static func render(_ s: LectureSession, vaultURL: URL) -> String {
        let begin = min(s.startedAt, s.segments.first?.time ?? s.startedAt)
        var md = """
        ---
        type: 讲座记录
        date: \(Fmt.day.string(from: begin))
        speaker: \(s.speaker)
        tags: [type/讲座, context/research]
        generated_by: 讲座助手
        ---
        # \(s.title)

        - 时间：\(Fmt.day.string(from: begin)) \(Fmt.hm(begin))\(s.segments.last.map { "–" + Fmt.hm($0.time.addingTimeInterval($0.duration)) } ?? "")
        - 主讲：\(s.speaker)

        """
        if !s.audioFiles.isEmpty {
            md += "\n## 录音\n\n"
            for a in s.audioFiles { md += "![[\(a)]]\n" }
        }

        md += "\n## 累计摘要\n\n"
        md += s.overallSummary.isEmpty ? "（还没有生成）\n" : s.overallSummary + "\n"

        if !s.summaries.isEmpty {
            md += "\n## 分段小结\n"
            for b in s.summaries {
                md += "\n### \(Fmt.hm(b.from))–\(Fmt.hm(b.to))\n\n\(b.points)\n"
            }
        }

        if !s.myNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            md += "\n## 我的笔记\n\n\(s.myNotes)\n"
        }

        let qas = s.qas.filter { $0.status != .running || !$0.answer.isEmpty }.reversed()
        if !qas.isEmpty {
            md += "\n## 疑问与解答\n"
            for (i, q) in qas.enumerated() {
                md += "\n### Q\(i + 1)（\(Fmt.hm(q.createdAt))）\(q.question.isEmpty ? "" : " " + oneLine(q.question))\n\n"
                for quote in q.quotes { md += "> " + quote.replacingOccurrences(of: "\n", with: "\n> ") + "\n" }
                md += "\n"
                if !q.question.isEmpty { md += "**我的问题**：\(q.question)\n\n" }
                md += q.answer.isEmpty ? "（\(q.error ?? "没有回答")）\n" : q.answer + "\n"
                if !q.vaultRefs.isEmpty {
                    md += "\n检索到的笔记：" + q.vaultRefs.map { "[[\(($0.path as NSString).deletingPathExtension)|\($0.title)]]" }.joined(separator: "、") + "\n"
                }
                if !q.webRefs.isEmpty {
                    md += "\n网页来源：\n" + q.webRefs.prefix(8).map { "- [\($0.title)](\($0.url))" }.joined(separator: "\n") + "\n"
                }
            }
        }

        let sets = s.questionSets.filter { !$0.content.isEmpty }.reversed()
        if !sets.isEmpty {
            md += "\n## 备选提问\n"
            for q in sets {
                md += "\n### \(Fmt.hm(q.createdAt)) \(q.kind == .quick ? "（被点名速答）" : "")\n\n\(q.content)\n"
            }
        }

        md += "\n## 完整转写\n\n"
        for seg in s.segments {
            md += "**[\(Fmt.clock(seg.time))]** \(seg.text)\n"
            if let sec = seg.secondary, !sec.isEmpty, sec != seg.text {
                md += seg.language == .english ? "> \(sec)\n" : "> 校正：\(sec)\n"
            }
            md += "\n"
        }
        return md
    }

    private static func oneLine(_ s: String) -> String {
        let t = s.replacingOccurrences(of: "\n", with: " ")
        return t.count > 40 ? String(t.prefix(40)) + "…" : t
    }
}
