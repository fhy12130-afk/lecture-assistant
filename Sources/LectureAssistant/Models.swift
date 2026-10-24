import Foundation

enum LectureLanguage: String, Codable, CaseIterable, Identifiable {
    case chinese = "zh-CN"
    case english = "en-US"

    var id: String { rawValue }
    var label: String { self == .chinese ? "中文" : "English" }
    var locale: Locale { Locale(identifier: rawValue) }
}

enum TaskStatus: String, Codable {
    case running, done, failed
}

/// 一句定稿的转写。secondary 在英文讲座里是中文译文，在中文讲座里是 AI 校正后的文本。
struct Segment: Identifiable, Codable, Equatable {
    var id = UUID()
    var time: Date
    var duration: Double
    var text: String
    var language: LectureLanguage
    var secondary: String?
    var secondaryFailed = false

    /// 给 AI 看的一行：时间 + 原文（+ 译文/校正）
    var promptLine: String {
        var s = "[\(Fmt.clock(time))] \(text)"
        if let sec = secondary, !sec.isEmpty, sec != text {
            s += language == .english ? "\n  （译）\(sec)" : "\n  （校正）\(sec)"
        }
        return s
    }

    /// 显示和总结时优先用的中文文本
    var bestChinese: String { secondary?.isEmpty == false ? secondary! : text }
}

struct SummaryBlock: Identifiable, Codable {
    var id = UUID()
    var createdAt: Date
    var from: Date
    var to: Date
    var points: String
}

struct VaultRef: Codable, Hashable {
    var path: String   // 相对 vault 的路径
    var title: String
}

struct WebRef: Codable, Hashable {
    var url: String
    var title: String
}

struct QAItem: Identifiable, Codable {
    var id = UUID()
    var createdAt: Date
    var quotes: [String]
    var question: String
    var answer = ""
    var vaultRefs: [VaultRef] = []
    var webRefs: [WebRef] = []
    var webSearch: Bool
    var status: TaskStatus = .running
    var error: String?
}

struct QuestionSet: Identifiable, Codable {
    enum Kind: String, Codable { case full, quick }
    var id = UUID()
    var createdAt: Date
    var kind: Kind
    var content = ""
    var status: TaskStatus = .running
    var error: String?
}

struct LectureSession: Codable {
    var id = UUID()
    var title: String
    var speaker: String
    var startedAt: Date
    var segments: [Segment] = []
    var summaries: [SummaryBlock] = []
    var overallSummary = ""
    var qas: [QAItem] = []
    var questionSets: [QuestionSet] = []
    var audioFiles: [String] = []
    var markdownPath: String?
    var myNotes = ""
    var lastSummarizedSegmentID: UUID?

    var isEmpty: Bool {
        segments.isEmpty && qas.isEmpty && questionSets.isEmpty && myNotes.isEmpty
    }
}

enum Fmt {
    static let clockFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()
    static let shortClock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()
    static let fileStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HHmm"
        return f
    }()
    static let day: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    static func clock(_ d: Date) -> String { clockFormatter.string(from: d) }
    static func hm(_ d: Date) -> String { shortClock.string(from: d) }

    static func elapsed(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
    }
}
