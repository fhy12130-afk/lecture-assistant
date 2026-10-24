import Foundation
import NaturalLanguage

/// Obsidian 笔记的本地全文检索：启动时把 .md 读进内存，按关键词打分取片段。
actor VaultSearch {
    struct Doc {
        var path: String      // 相对 vault
        var title: String
        var text: String
        var lower: String
    }

    struct Hit: Sendable {
        var path: String
        var title: String
        var score: Double
        var snippets: [String]
    }

    private var docs: [Doc] = []
    private var root: URL?
    private(set) var indexedAt: Date?

    private static let skipDirs: Set<String> = [".obsidian", ".trash", ".git", "node_modules"]
    private static let maxFileBytes = 400_000

    func index(root: URL, excluding exclude: String? = nil) -> Int {
        self.root = root
        var out: [Doc] = []
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return 0 }
        for case let url as URL in en {
            let name = url.lastPathComponent
            let vals = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if vals?.isDirectory == true {
                if Self.skipDirs.contains(name) { en.skipDescendants() }
                continue
            }
            guard url.pathExtension.lowercased() == "md", (vals?.fileSize ?? 0) < Self.maxFileBytes else { continue }
            let rel = String(url.path.dropFirst(root.path.count + 1))
            if let ex = exclude, rel.hasPrefix(ex) { continue }   // 不检索讲座记录自己
            guard let text = try? String(contentsOf: url, encoding: .utf8), !text.isEmpty else { continue }
            out.append(Doc(path: rel, title: (name as NSString).deletingPathExtension, text: text, lower: text.lowercased()))
        }
        docs = out
        indexedAt = Date()
        return out.count
    }

    var count: Int { docs.count }

    func read(_ rel: String, limit: Int) -> String? {
        if let d = docs.first(where: { $0.path == rel }) { return String(d.text.prefix(limit)) }
        guard let root, let t = try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8) else { return nil }
        return String(t.prefix(limit))
    }

    func search(_ keywords: [String], limit: Int = 6, snippetChars: Int = 360) -> [Hit] {
        let terms = Array(Set(keywords.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }.filter { $0.count >= 2 }))
        guard !terms.isEmpty, !docs.isEmpty else { return [] }
        // 文档频率 → idf
        var df: [String: Int] = [:]
        for t in terms { df[t] = docs.reduce(0) { $0 + ($1.lower.contains(t) ? 1 : 0) } }
        let n = Double(docs.count)
        var scored: [(Int, Double, [String])] = []
        for (i, d) in docs.enumerated() {
            var s = 0.0
            var matched: [String] = []
            for t in terms {
                guard let f = df[t], f > 0 else { continue }
                let c = Self.count(of: t, in: d.lower, cap: 30)
                guard c > 0 else { continue }
                let idf = log(1 + n / Double(f))
                s += (1 + log(Double(c))) * idf
                if d.title.lowercased().contains(t) { s += 2 * idf }
                matched.append(t)
            }
            guard s > 0 else { continue }
            // 命中的不同关键词越多越好
            s *= 1 + 0.35 * Double(matched.count - 1)
            if d.path.hasPrefix("03-项目") { s *= 1.25 }
            if d.path.hasPrefix("05-归档") { s *= 0.8 }
            scored.append((i, s, matched))
        }
        scored.sort { $0.1 > $1.1 }
        // 同名笔记（归档里的副本）只留分最高的一篇
        var seenTitles = Set<String>()
        scored = scored.filter { seenTitles.insert(docs[$0.0].title).inserted }
        return scored.prefix(limit).map { (i, s, matched) in
            let d = docs[i]
            return Hit(path: d.path, title: d.title, score: s, snippets: Self.snippets(d.text, terms: matched, chars: snippetChars, max: 2))
        }
    }

    private static func count(of needle: String, in hay: String, cap: Int) -> Int {
        var c = 0
        var range = hay.startIndex..<hay.endIndex
        while c < cap, let r = hay.range(of: needle, range: range) {
            c += 1
            range = r.upperBound..<hay.endIndex
        }
        return c
    }

    /// 找关键词最密集的位置，截取前后文
    private static func snippets(_ text: String, terms: [String], chars: Int, max: Int) -> [String] {
        let lower = text.lowercased()
        var positions: [String.Index] = []
        for t in terms {
            var range = lower.startIndex..<lower.endIndex
            var k = 0
            while k < 8, let r = lower.range(of: t, range: range) {
                positions.append(r.lowerBound)
                range = r.upperBound..<lower.endIndex
                k += 1
            }
        }
        guard !positions.isEmpty else { return [String(text.prefix(chars))] }
        let offsets = positions.map { lower.distance(from: lower.startIndex, to: $0) }.sorted()
        // 每个位置附近 chars 范围内的命中数
        var best: [(Int, Int)] = offsets.map { o in (o, offsets.filter { abs($0 - o) < chars / 2 }.count) }
        best.sort { $0.1 > $1.1 }
        var picked: [Int] = []
        for (o, _) in best where picked.allSatisfy({ abs($0 - o) > chars }) {
            picked.append(o)
            if picked.count >= max { break }
        }
        let chars0 = Array(text)
        return picked.sorted().map { o in
            let s = Swift.max(0, o - chars / 3)
            let e = Swift.min(chars0.count, s + chars)
            var piece = String(chars0[s..<e]).replacingOccurrences(of: "\n\n", with: "\n")
            if s > 0 { piece = "…" + piece }
            if e < chars0.count { piece += "…" }
            return piece
        }
    }

    /// AI 不可用时的兜底：用系统分词取名词类关键词
    static func localKeywords(_ text: String, max: Int = 10) -> [String] {
        var freq: [String: Int] = [:]
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass, options: [.omitPunctuation, .omitWhitespace]) { tag, r in
            let w = String(text[r])
            if (tag == .noun || tag == .otherWord || tag == nil), w.count >= 2 { freq[w, default: 0] += 1 }
            return true
        }
        let ascii = text.split { !$0.isLetter && !$0.isNumber && $0 != "-" }.map(String.init).filter { $0.count >= 3 && $0.allSatisfy(\.isASCII) }
        for w in ascii { freq[w, default: 0] += 1 }
        return freq.sorted { $0.value > $1.value }.prefix(max).map(\.key)
    }
}
