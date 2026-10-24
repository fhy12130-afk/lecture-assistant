import Foundation
import SwiftUI

enum APIFormat: String, Codable, CaseIterable, Identifiable {
    case anthropic, openai
    var id: String { rawValue }
    var label: String { self == .anthropic ? "Anthropic /v1/messages" : "OpenAI 兼容 /v1/chat/completions" }
}

enum KeyMode: String, Codable, CaseIterable, Identifiable {
    case file, inline
    var id: String { rawValue }
}

enum Effort: String, Codable, CaseIterable, Identifiable {
    case low, medium, high
    var id: String { rawValue }
    var label: String {
        switch self {
        case .low: return "快（low）"
        case .medium: return "均衡（medium）"
        case .high: return "深入（high）"
        }
    }
}

struct SettingsData: Codable, Equatable {
    // AI 接口
    var apiBaseURL = "https://api.anthropic.com"
    var apiFormat: APIFormat = .anthropic
    var keyMode: KeyMode = .file
    var keyFilePath = "~/.config/lecture-assistant/key"
    var mainModel = "claude-opus-5-5"
    var fastModel = "claude-opus-5-5"
    var answerEffort: Effort = .medium
    var questionEffort: Effort = .medium

    // 讲座
    var language: LectureLanguage = .chinese
    var sessionTitle = "未命名讲座"
    var speakerName = ""
    var domain = ""                   // 讲座领域，翻译和纠错时参考
    var autoSecondary = true          // 英文自动翻译 / 中文自动校正
    var summaryIntervalMin = 4
    var recordAudio = true
    var fontSize: Double = 15

    // 本地数据
    var vaultPath = "~/Documents/Obsidian Vault"
    var notesFolder = "讲座记录"
    var audioFolder = "讲座记录/录音"
    var pinnedNotes = ""
    var myProfile = ""
    var speakerProfile = ""
    var questionFocus = ""            // 提问时想从哪些角度把主讲人的工作和自己的研究连起来
    var glossary = ""

    var expandedVaultPath: String { (vaultPath as NSString).expandingTildeInPath }
    var vaultURL: URL { URL(fileURLWithPath: expandedVaultPath, isDirectory: true) }
    var notesURL: URL { vaultURL.appendingPathComponent(notesFolder, isDirectory: true) }
    var audioURL: URL { vaultURL.appendingPathComponent(audioFolder, isDirectory: true) }
    var glossaryTerms: [String] {
        glossary.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
    var pinnedNoteList: [String] {
        pinnedNotes.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()
    private let key = "settings.v1"

    @Published var data: SettingsData {
        didSet { if data != oldValue { save() } }
    }

    /// 个人预设：~/Library/Application Support/LectureAssistant/preset.json（可只写部分字段）。
    /// 加载顺序：代码里的通用默认值 → 预设 → 用户在设置里改过的值。
    static var presetURL: URL { appSupportURL.appendingPathComponent("preset.json") }

    /// 通用默认值叠加预设后的结果，也是“恢复默认内容”的目标
    static func baseline() -> SettingsData {
        var base = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(SettingsData()))) as? [String: Any] ?? [:]
        if let raw = try? Data(contentsOf: presetURL),
           let preset = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] {
            base.merge(preset) { _, new in new }
        }
        if let m = try? JSONSerialization.data(withJSONObject: base),
           let d = try? JSONDecoder().decode(SettingsData.self, from: m) {
            return d
        }
        return SettingsData()
    }

    private init() {
        let baseline = Self.baseline()
        // 旧版本存的设置缺字段时，用默认值补上，不整体丢弃
        if let raw = UserDefaults.standard.data(forKey: key),
           let saved = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
           var merged = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(baseline))) as? [String: Any] {
            merged.merge(saved) { _, new in new }
            if let m = try? JSONSerialization.data(withJSONObject: merged),
               let d = try? JSONDecoder().decode(SettingsData.self, from: m) {
                data = d
                return
            }
        }
        data = baseline
    }

    private func save() {
        if let raw = try? JSONEncoder().encode(data) {
            UserDefaults.standard.set(raw, forKey: key)
        }
    }

    func resetProfiles() {
        let b = Self.baseline()
        data.myProfile = b.myProfile
        data.speakerProfile = b.speakerProfile
        data.pinnedNotes = b.pinnedNotes
        data.glossary = b.glossary
        data.questionFocus = b.questionFocus
        data.domain = b.domain
    }

    // MARK: API key

    static var appSupportURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("LectureAssistant", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static var inlineKeyURL: URL { appSupportURL.appendingPathComponent("api_key") }

    /// 手动粘贴的 key 存在应用支持目录，权限 600，不进 UserDefaults
    func saveInlineKey(_ key: String) {
        let url = Self.inlineKeyURL
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        FileManager.default.createFile(atPath: url.path, contents: Data(trimmed.utf8), attributes: [.posixPermissions: 0o600])
    }

    var hasInlineKey: Bool { FileManager.default.fileExists(atPath: Self.inlineKeyURL.path) }

    func resolveKey() -> String? {
        let path: String
        switch data.keyMode {
        case .file: path = (data.keyFilePath as NSString).expandingTildeInPath
        case .inline: path = Self.inlineKeyURL.path
        }
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let k = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return k.isEmpty ? nil : k
    }

    func llmConfig() -> LLMConfig? {
        guard let key = resolveKey() else { return nil }
        return LLMConfig(baseURL: data.apiBaseURL, apiKey: key, format: data.apiFormat)
    }
}
