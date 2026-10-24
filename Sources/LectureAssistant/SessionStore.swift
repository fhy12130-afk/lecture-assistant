import Foundation
import Observation
import AppKit

@MainActor
@Observable
final class SessionStore {
    // MARK: 会话数据（拆成多个属性，视图只跟踪用到的那部分）
    var sessionID = UUID()
    var title: String
    var speaker: String
    var startedAt = Date()
    var segments: [Segment] = []
    var summaries: [SummaryBlock] = []
    var overallSummary = ""
    var qas: [QAItem] = []
    var questionSets: [QuestionSet] = []
    var audioFiles: [String] = []
    var myNotes = ""
    var markdownPath: String?
    var lastSummarizedSegmentID: UUID?

    // MARK: 实时状态
    var volatileText = ""
    var level: Float = 0
    var isRecording = false
    var isStarting = false
    var banner: Banner?
    var selected: Set<UUID> = []
    var qaDraft = ""
    var qaWebSearch = false
    var liveSummary: String?
    var isSummarizing = false
    var lastSummaryAt: Date?
    var lastSavedAt: Date?
    var saveError: String?
    var secondaryPending = 0
    var lastAPIError: String?
    var lastAPIOK: Date?
    var vaultDocCount = 0
    var importProgress: Double?
    var recordingSince: Date?
    var recordedSeconds: TimeInterval = 0
    var sideTab: SideTab = .summary
    var language: LectureLanguage

    enum SideTab: String, CaseIterable, Identifiable {
        case summary = "摘要", qa = "疑问", questions = "提问", notes = "笔记"
        var id: String { rawValue }
    }

    struct Banner: Identifiable, Equatable {
        var id = UUID()
        var text: String
        var isError: Bool
        var action: Action?
        enum Action: Equatable { case openMicSettings, openDictationSettings, openSettings, newSession }
    }

    // MARK: 内部
    @ObservationIgnored let settings = AppSettings.shared
    @ObservationIgnored let engine = SpeechEngine()
    @ObservationIgnored let vault = VaultSearch()
    @ObservationIgnored var secondaryQueue: [UUID] = []
    @ObservationIgnored var secondaryWorkerRunning = false
    @ObservationIgnored var pinnedCache: [(path: String, text: String)] = []
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var eventsTask: Task<Void, Never>?
    @ObservationIgnored private var bannerTask: Task<Void, Never>?
    @ObservationIgnored private var sleepActivity: NSObjectProtocol?
    @ObservationIgnored private let saveQueue = DispatchQueue(label: "lecture.save")
    /// 自测时把记录写到别处，不碰真实笔记库
    @ObservationIgnored var notesDirOverride: URL?
    @ObservationIgnored var audioDirOverride: URL?
    /// 演示数据：不写崩溃恢复快照
    @ObservationIgnored var isDemo = false

    static var snapshotURL: URL { AppSettings.appSupportURL.appendingPathComponent("current-session.json") }

    init(restore: Bool = true) {
        let d = AppSettings.shared.data
        title = d.sessionTitle
        speaker = d.speakerName
        language = d.language
        if restore { restoreSnapshot() }
        eventsTask = Task { [weak self] in
            guard let events = self?.engine.events else { return }
            for await ev in events {
                guard let self else { break }
                self.handle(ev)
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.summarizeIfDue() }
        }
        Task { await reindexVault() }
    }

    // MARK: 录音

    var elapsed: TimeInterval {
        recordedSeconds + (recordingSince.map { Date().timeIntervalSince($0) } ?? 0)
    }

    func toggleRecording() {
        Task { isRecording ? await stop() : await start() }
    }

    func start() async {
        guard !isRecording, !isStarting else { return }
        isStarting = true
        defer { isStarting = false }
        guard await SpeechEngine.requestMicAccess() else {
            show("没有麦克风权限：到 系统设置 › 隐私与安全性 › 麦克风 里打开「讲座助手」，然后重开应用。", error: true, action: .openMicSettings)
            return
        }
        if let msg = await SpeechEngine.ensureModel(for: language) {
            show(msg, error: true, action: .openDictationSettings)
            return
        }
        let d = settings.data
        var recordDir: URL? = d.recordAudio ? (audioDirOverride ?? d.audioURL) : nil
        if let dir = recordDir, (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) == nil {
            recordDir = AppSettings.appSupportURL.appendingPathComponent("讲座录音", isDirectory: true)
        }
        do {
            try await engine.start(language: language, contextualStrings: d.glossaryTerms,
                                   recordDir: recordDir, recordBaseName: fileBaseName)
            isRecording = true
            recordingSince = Date()
            if lastSummaryAt == nil { lastSummaryAt = Date() }
            // 录音期间不让系统睡眠、不进 App Nap（合盖仍会睡）
            sleepActivity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason: "正在记录讲座")
            dismissBanner()
        } catch {
            show("开始失败：\(error.localizedDescription)", error: true)
        }
    }

    /// 自测用：把音频文件按 speed 倍速当成麦克风输入
    func startSimulated(_ url: URL, speed: Double) async {
        guard !isRecording else { return }
        let d = settings.data
        do {
            try await engine.startSimulated(file: url, speed: speed, language: language, contextualStrings: d.glossaryTerms,
                                            recordDir: d.recordAudio ? (audioDirOverride ?? d.audioURL) : nil, recordBaseName: fileBaseName)
            isRecording = true
            recordingSince = Date()
            if lastSummaryAt == nil { lastSummaryAt = Date() }
        } catch {
            show("开始失败：\(error.localizedDescription)", error: true)
        }
    }

    func stop() async {
        guard isRecording else { return }
        await engine.stop()
        isRecording = false
        if let a = sleepActivity { ProcessInfo.processInfo.endActivity(a); sleepActivity = nil }
        if let s = recordingSince { recordedSeconds += Date().timeIntervalSince(s) }
        recordingSince = nil
        level = 0
        saveNow()
    }

    func setLanguage(_ lang: LectureLanguage) {
        guard lang != language else { return }
        language = lang
        settings.data.language = lang
        if isRecording {
            Task {
                if let msg = await SpeechEngine.ensureModel(for: lang) {
                    show(msg, error: true, action: .openDictationSettings)
                    return
                }
                await engine.switchLanguage(lang)
                flash("已切换到 \(lang.label) 识别")
            }
        }
    }

    private func handle(_ ev: SpeechEngine.Event) {
        switch ev {
        case .volatile(let t): volatileText = t
        case .final(let r): addFinal(r)
        case .level(let l): level = l
        case .error(let msg): show(msg, error: true)
        case .audioFile(let url):
            if !audioFiles.contains(url.lastPathComponent) { audioFiles.append(url.lastPathComponent) }
            scheduleSave()
        case .sourceEnded:
            Task { await stop() }
        }
    }

    func addFinal(_ r: SpeechEngine.FinalResult) {
        let seg = Segment(time: r.start, duration: r.duration, text: r.text, language: r.language)
        if let last = segments.last, last.time > seg.time {
            // 导入的录音时间可能早于已有内容
            let idx = segments.firstIndex { $0.time > seg.time } ?? segments.endIndex
            segments.insert(seg, at: idx)
        } else {
            segments.append(seg)
        }
        if settings.data.autoSecondary { enqueueSecondary([seg.id]) }
        scheduleSave()
    }

    // MARK: 导入录音

    func importAudio(_ url: URL) async {
        guard importProgress == nil else { return }
        if let msg = await SpeechEngine.ensureModel(for: language) {
            show(msg, error: true, action: .openDictationSettings)
            return
        }
        importProgress = 0
        let base = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
        do {
            try await SpeechEngine.transcribeFile(url, language: language, contextualStrings: settings.data.glossaryTerms, startDate: base,
                onFinal: { [weak self] r in await self?.addFinal(r) },
                onProgress: { [weak self] p in await self?.setImportProgress(p) })
            flash("导入完成：\(url.lastPathComponent)")
        } catch {
            show("导入失败：\(error.localizedDescription)", error: true)
        }
        importProgress = nil
    }

    private func setImportProgress(_ p: Double) { importProgress = p }

    // MARK: 选择

    func toggleSelect(_ id: UUID) {
        if selected.contains(id) { selected.remove(id) } else { selected.insert(id) }
    }

    var selectedSegments: [Segment] { segments.filter { selected.contains($0.id) } }

    // MARK: 会话

    func newSession() async {
        if isRecording { await stop() }
        saveNow()
        let d = settings.data
        sessionID = UUID()
        title = d.sessionTitle
        speaker = d.speakerName
        startedAt = Date()
        segments = []
        summaries = []
        overallSummary = ""
        qas = []
        questionSets = []
        audioFiles = []
        myNotes = ""
        markdownPath = nil
        lastSummarizedSegmentID = nil
        lastSummaryAt = nil
        recordedSeconds = 0
        selected = []
        volatileText = ""
        secondaryQueue = []
        try? FileManager.default.removeItem(at: Self.snapshotURL)
        flash("已开始新的记录")
    }

    var fileBaseName: String {
        let safe = title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return "\(Fmt.fileStamp.string(from: startedAt)) \(safe)"
    }

    var markdownURL: URL {
        if let p = markdownPath { return URL(fileURLWithPath: p) }
        let dir = notesDirOverride ?? settings.data.notesURL
        return dir.appendingPathComponent(fileBaseName + ".md")
    }

    func snapshot() -> LectureSession {
        var s = LectureSession(id: sessionID, title: title, speaker: speaker, startedAt: startedAt)
        s.segments = segments
        s.summaries = summaries
        s.overallSummary = overallSummary
        s.qas = qas
        s.questionSets = questionSets
        s.audioFiles = audioFiles
        s.markdownPath = markdownPath
        s.myNotes = myNotes
        s.lastSummarizedSegmentID = lastSummarizedSegmentID
        return s
    }

    private func restoreSnapshot() {
        guard let data = try? Data(contentsOf: Self.snapshotURL),
              let s = try? JSONDecoder().decode(LectureSession.self, from: data),
              !s.isEmpty, Date().timeIntervalSince(s.startedAt) < 36 * 3600 else { return }
        sessionID = s.id
        title = s.title
        speaker = s.speaker
        startedAt = s.startedAt
        segments = s.segments
        summaries = s.summaries
        overallSummary = s.overallSummary
        // 上次没跑完的 AI 任务标成失败
        qas = s.qas.map { var q = $0; if q.status == .running { q.status = .failed; q.error = q.error ?? "应用重启，回答中断" }; return q }
        questionSets = s.questionSets.map { var q = $0; if q.status == .running { q.status = .failed; q.error = q.error ?? "应用重启，生成中断" }; return q }
        audioFiles = s.audioFiles
        markdownPath = s.markdownPath
        myNotes = s.myNotes
        lastSummarizedSegmentID = s.lastSummarizedSegmentID
        lastSummaryAt = s.summaries.last?.createdAt
        banner = Banner(text: "已恢复上次的记录「\(s.title)」（\(Fmt.hm(s.startedAt)) 开始，\(s.segments.count) 句）。要记新讲座就点右边新建。", isError: false, action: .newSession)
    }

    // MARK: 保存

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    /// 笔记库写不进去（比如拒绝了文稿目录权限）时的备用位置
    static var fallbackNotesURL: URL { AppSettings.appSupportURL.appendingPathComponent("讲座记录", isDirectory: true) }

    func saveNow() {
        let snap = snapshot()
        guard !snap.isEmpty else { return }
        let url = markdownURL
        let md = MarkdownExporter.render(snap, vaultURL: settings.data.vaultURL)
        let json = isDemo ? nil : try? JSONEncoder().encode(snap)
        let snapshotURL = Self.snapshotURL
        let fallback = Self.fallbackNotesURL.appendingPathComponent(url.lastPathComponent)
        // 写文件放后台：首次访问“文稿”目录时系统弹权限框，会卡住调用线程
        saveQueue.async { [weak self] in
            var written: URL?
            var err: String?
            if let json { try? json.write(to: snapshotURL, options: .atomic) }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try md.write(to: url, atomically: true, encoding: .utf8)
                written = url
            } catch {
                err = error.localizedDescription
                if (try? FileManager.default.createDirectory(at: fallback.deletingLastPathComponent(), withIntermediateDirectories: true)) != nil,
                   (try? md.write(to: fallback, atomically: true, encoding: .utf8)) != nil {
                    written = fallback
                }
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                if let w = written {
                    if self.markdownPath == nil || w == fallback { self.markdownPath = w.path }
                    self.lastSavedAt = Date()
                }
                if let err, written == fallback, self.saveError == nil {
                    self.show("写不进笔记库（\(err)），记录先存在：\(fallback.path)", error: true)
                } else if let err, written == nil {
                    self.show("保存失败：\(err)", error: true)
                }
                self.saveError = written == url ? nil : err
            }
        }
    }

    /// 退出前同步等写完
    func flushSaves() {
        saveNow()
        saveQueue.sync {}
    }

    func openMarkdown() {
        saveNow()
        let url = markdownURL
        guard FileManager.default.fileExists(atPath: url.path) else { flash("还没有内容，记录文件尚未生成"); return }
        var comps = URLComponents()
        comps.scheme = "obsidian"
        comps.host = "open"
        comps.queryItems = [URLQueryItem(name: "path", value: url.path)]
        if url.path.hasPrefix(settings.data.vaultURL.path),
           let obs = comps.url, NSWorkspace.shared.urlForApplication(toOpen: obs) != nil {
            NSWorkspace.shared.open(obs)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    func revealMarkdown() {
        saveNow()
        NSWorkspace.shared.activateFileViewerSelecting([markdownURL])
    }

    func openVaultNote(_ rel: String) {
        let url = settings.data.vaultURL.appendingPathComponent(rel)
        var comps = URLComponents()
        comps.scheme = "obsidian"
        comps.host = "open"
        comps.queryItems = [URLQueryItem(name: "path", value: url.path)]
        if let obs = comps.url, NSWorkspace.shared.urlForApplication(toOpen: obs) != nil {
            NSWorkspace.shared.open(obs)
        } else {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: 笔记库

    func reindexVault() async {
        let d = settings.data
        let exclude = d.notesFolder
        let n = await vault.index(root: d.vaultURL, excluding: exclude)
        vaultDocCount = n
        var pinned: [(String, String)] = []
        for p in d.pinnedNoteList {
            if let t = await vault.read(p, limit: 7000) { pinned.append((p, t)) }
        }
        pinnedCache = pinned
        if n == 0 {
            show("没读到笔记库（\(d.vaultPath)）：解惑时就只能靠讲座内容和你的背景介绍。可以在设置 › 存储 里改路径。", error: true)
        }
    }

    // MARK: 提示条

    func show(_ text: String, error: Bool, action: Banner.Action? = nil) {
        bannerTask?.cancel()
        banner = Banner(text: text, isError: error, action: action)
    }

    func flash(_ text: String) {
        let b = Banner(text: text, isError: false)
        banner = b
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            guard !Task.isCancelled, self?.banner?.id == b.id else { return }
            self?.banner = nil
        }
    }

    func dismissBanner() { banner = nil }

    func perform(_ action: Banner.Action) {
        switch action {
        case .openMicSettings:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
        case .openDictationSettings:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
        case .openSettings:
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        case .newSession:
            Task { await newSession() }
        }
    }
}
