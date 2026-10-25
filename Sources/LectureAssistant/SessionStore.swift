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
    var audioParts: [AudioPart] = []
    var myNotes = ""
    var markdownPath: String?
    var lastSummarizedSegmentID: UUID?
    /// 标题 / 汇报人还是自动的（没被手动改过），AI 可以根据内容更新
    var titleIsAuto = true
    var speakerIsAuto = true
    var isProposingTitle = false

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
    var asrKindName: String?
    var localASRNames: [String] = []

    enum SideTab: String, CaseIterable, Identifiable {
        case summary = "摘要", qa = "疑问", questions = "提问", notes = "笔记"
        var id: String { rawValue }
    }

    struct Banner: Identifiable, Equatable {
        var id = UUID()
        var text: String
        var isError: Bool
        var action: Action?
        enum Action: Equatable { case openMicSettings, openDictationSettings, openSettings, newSession, switchEngine }
    }

    // MARK: 内部
    @ObservationIgnored let settings = AppSettings.shared
    @ObservationIgnored let player = AudioPlayback()
    var showLibrary = false
    var editingSegmentID: UUID?
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
    @ObservationIgnored var lastASRActivity: Date?
    @ObservationIgnored var lastLoud: Date?
    @ObservationIgnored var watchdogWarned = false
    @ObservationIgnored var titleRequestCount = 0

    static var snapshotURL: URL { AppSettings.appSupportURL.appendingPathComponent("current-session.json") }

    init(restore: Bool = true) {
        let d = AppSettings.shared.data
        title = d.sessionTitle.trimmingCharacters(in: .whitespaces)
        speaker = d.speakerName
        language = d.language
        titleIsAuto = title.isEmpty
        if restore { restoreSnapshot() }
        eventsTask = Task { [weak self] in
            guard let events = self?.engine.events else { return }
            for await ev in events {
                guard let self else { break }
                self.handle(ev)
            }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.summarizeIfDue()
                self?.checkWatchdog()
            }
        }
        Task { await reindexVault() }
        Task { await startLocalASR() }
    }

    func startLocalASR() async {
        guard settings.data.localASR, LocalASR.isInstalled else { localASRNames = []; return }
        localASRNames = await LocalASR.shared.start()
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
        engine.preferredEngine = d.asrEngine
        do {
            try await engine.start(language: language, contextualStrings: d.glossaryTerms,
                                   recordDir: recordDir, recordBaseName: audioBaseName)
            isRecording = true
            recordingSince = Date()
            lastASRActivity = Date()
            watchdogWarned = false
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
        engine.preferredEngine = d.asrEngine
        do {
            try await engine.startSimulated(file: url, speed: speed, language: language, contextualStrings: d.glossaryTerms,
                                            recordDir: d.recordAudio ? (audioDirOverride ?? d.audioURL) : nil, recordBaseName: audioBaseName)
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
        player.refreshDurations()
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
        case .volatile(let t):
            volatileText = t
            if !t.isEmpty { lastASRActivity = Date() }
        case .final(let r):
            lastASRActivity = Date()
            addFinal(r)
        case .level(let l):
            level = l
            if l > 0.45 { lastLoud = Date() }
        case .engine(let k):
            asrKindName = k.rawValue
        case .error(let msg): show(msg, error: true)
        case .audioFile(let url):
            if !audioFiles.contains(url.lastPathComponent) {
                audioFiles.append(url.lastPathComponent)
                audioParts.append(AudioPart(name: url.lastPathComponent, start: Date()))
                reloadAudio()
            }
            scheduleSave()
        case .sourceEnded:
            Task { await stop() }
        }
    }

    func addFinal(_ r: SpeechEngine.FinalResult) {
        let seg = Segment(time: r.start, duration: r.duration, text: r.text, language: r.language)
        let pcm = settings.data.localASR && !localASRNames.isEmpty ? engine.pcm(for: r) : nil
        if let last = segments.last, last.time > seg.time {
            // 导入的录音时间可能早于已有内容
            let idx = segments.firstIndex { $0.time > seg.time } ?? segments.endIndex
            segments.insert(seg, at: idx)
        } else {
            segments.append(seg)
        }
        if let pcm {
            // 本地引擎复核这一句，拿到结果再交给 AI 综合
            let id = seg.id, lang = r.language
            Task {
                if let res = await LocalASR.shared.recognize(pcm, language: lang) {
                    if let i = segments.firstIndex(where: { $0.id == id }) {
                        segments[i].localText = res.text
                        segments[i].localEngines = res.engines
                    }
                } else if !(await LocalASR.shared.isReady) {
                    localASRNames = []
                }
                if settings.data.autoSecondary { enqueueSecondary([id]) }
                scheduleSave()
            }
        } else if settings.data.autoSecondary {
            enqueueSecondary([seg.id])
        }
        maybeProposeTitle()
        scheduleSave()
    }

    // MARK: 识别看门狗

    /// 有声音却很久没出字：多半是语言选错或者识别模型不适合，提示换一个
    func checkWatchdog() {
        guard isRecording, !watchdogWarned, let since = lastASRActivity ?? recordingSince else { return }
        let now = Date()
        guard now.timeIntervalSince(since) > 25, let loud = lastLoud, now.timeIntervalSince(loud) < 10 else { return }
        watchdogWarned = true
        show("有声音，但 25 秒没识别出文字（当前：\(language.label) · \(asrKindName ?? "识别模型")）。先确认讲座语言选对了；还不行就点右边换一个识别模型。", error: true, action: .switchEngine)
    }

    func switchEngine() {
        let next: ASREngine = engine.currentKind == .dictation ? .transcriber : .dictation
        settings.data.asrEngine = next
        engine.preferredEngine = next
        guard isRecording else { flash("已改用\(next.label)"); return }
        Task {
            await engine.switchLanguage(language, force: true)
            lastASRActivity = Date()
            watchdogWarned = false
            flash("已换成\(asrKindName ?? next.label)")
        }
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
                prefer: settings.data.asrEngine,
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
        flushSaves()        // 等旧记录写完再清状态
        player.stop()
        let d = settings.data
        sessionID = UUID()
        title = d.sessionTitle.trimmingCharacters(in: .whitespaces)
        titleIsAuto = title.isEmpty
        speaker = d.speakerName
        speakerIsAuto = true
        titleRequestCount = 0
        startedAt = Date()
        segments = []
        summaries = []
        overallSummary = ""
        qas = []
        questionSets = []
        audioFiles = []
        audioParts = []
        player.load(parts: [], files: [], resolve: { _ in nil })
        myNotes = ""
        markdownPath = nil
        lastSummarizedSegmentID = nil
        lastSummaryAt = nil
        recordedSeconds = 0
        selected = []
        volatileText = ""
        secondaryQueue = []
        if !isDemo { try? FileManager.default.removeItem(at: Self.snapshotURL) }
        flash("已开始新的记录")
    }

    var displayTitle: String { title.isEmpty ? "未命名讲座" : title }

    var fileBaseName: String {
        let safe = displayTitle.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        return "\(Fmt.fileStamp.string(from: startedAt)) \(String(safe.prefix(60)))"
    }

    /// 录音文件名不带标题（标题可能之后才定）
    var audioBaseName: String { "\(Fmt.fileStamp.string(from: startedAt)) 讲座录音" }

    /// 按当前标题应有的路径；标题改了，保存时会把旧文件改名
    var desiredMarkdownURL: URL {
        let dir = notesDirOverride ?? settings.data.notesURL
        return dir.appendingPathComponent(fileBaseName + ".md")
    }

    var markdownURL: URL {
        if let p = markdownPath { return URL(fileURLWithPath: p) }
        return desiredMarkdownURL
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
        s.titleIsAuto = titleIsAuto
        s.speakerIsAuto = speakerIsAuto
        s.audioParts = audioParts
        return s
    }

    private func restoreSnapshot() {
        guard let data = try? Data(contentsOf: Self.snapshotURL),
              let s = try? JSONDecoder().decode(LectureSession.self, from: data),
              !s.isEmpty, Date().timeIntervalSince(s.startedAt) < 36 * 3600 else { return }
        apply(s)
        banner = Banner(text: "已恢复上次的记录「\(displayTitle)」（\(Fmt.hm(s.startedAt)) 开始，\(s.segments.count) 句）。要记新讲座就点右边新建。", isError: false, action: .newSession)
    }

    /// 把一份记录载入到界面
    func apply(_ s: LectureSession) {
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
        audioParts = s.audioParts ?? []
        markdownPath = s.markdownPath
        myNotes = s.myNotes
        lastSummarizedSegmentID = s.lastSummarizedSegmentID ?? (s.summaries.isEmpty ? nil : s.segments.last?.id)
        titleIsAuto = s.titleIsAuto ?? false
        speakerIsAuto = s.speakerIsAuto ?? false
        lastSummaryAt = s.summaries.last?.createdAt
        recordedSeconds = 0
        recordingSince = nil
        selected = []
        volatileText = ""
        secondaryQueue = []
        titleRequestCount = 2
        reloadAudio()
    }

    // MARK: 回放

    func resolveAudio(_ name: String) -> URL? {
        if name.hasPrefix("/") { return URL(fileURLWithPath: name) }
        let candidates = [audioDirOverride ?? settings.data.audioURL,
                          AppSettings.appSupportURL.appendingPathComponent("讲座录音", isDirectory: true)]
        for d in candidates {
            let u = d.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: u.path) { return u }
        }
        return nil
    }

    func reloadAudio() {
        player.load(parts: audioParts, files: audioFiles, resolve: resolveAudio)
    }

    func playFrom(_ seg: Segment) {
        if player.parts.isEmpty || player.parts.contains(where: { $0.duration == nil }) { reloadAudio() }
        player.play(at: seg.time)
        if let m = player.message { flash(m) }
    }

    // MARK: 修改

    func updateSegment(_ id: UUID, text: String?, secondary: String?) {
        guard let i = segments.firstIndex(where: { $0.id == id }) else { return }
        if let t = text { segments[i].text = t; segments[i].localText = nil; segments[i].localEngines = nil }
        if let s = secondary { segments[i].secondary = s; segments[i].secondaryFailed = false }
        scheduleSave()
    }

    func deleteSegment(_ id: UUID) {
        segments.removeAll { $0.id == id }
        selected.remove(id)
        scheduleSave()
    }

    func deleteQA(_ id: UUID) { qas.removeAll { $0.id == id }; scheduleSave() }
    func deleteQuestionSet(_ id: UUID) { questionSets.removeAll { $0.id == id }; scheduleSave() }
    func deleteSummary(_ id: UUID) { summaries.removeAll { $0.id == id }; scheduleSave() }

    // MARK: 记录列表

    func listRecords() -> [RecordInfo] {
        RecordLibrary.list(folders: [notesDirOverride ?? settings.data.notesURL, Self.fallbackNotesURL])
    }

    // MARK: 记录库

    /// 每场记录的完整数据单独存一份，回看时用（Markdown 只是给人看的）
    static var archiveDir: URL {
        let d = AppSettings.appSupportURL.appendingPathComponent("sessions", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    static func archiveURL(_ id: UUID) -> URL { archiveDir.appendingPathComponent(id.uuidString + ".json") }

    /// 打开一份以前的记录。录音中不能切换。
    func open(_ record: RecordInfo) async -> Bool {
        if isRecording {
            show("正在录音，先停止再打开别的记录。", error: true)
            return false
        }
        guard record.mdURL?.path != markdownURL.path || record.sessionID != sessionID else { return true }
        flushSaves()
        guard let s = RecordLibrary.load(record) else {
            show("打不开这份记录：\(record.title)", error: true)
            return false
        }
        apply(s)
        if !isDemo, let json = try? JSONEncoder().encode(s) { try? json.write(to: Self.snapshotURL, options: .atomic) }
        flash("已打开「\(displayTitle)」（\(s.segments.count) 句）。可以接着提问、修改，或者点开始继续记录。")
        return true
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
        let sid = sessionID
        // 标题改了：写到新文件名，旧文件移到废纸篓。只动属于这场记录的文件
        // （同一文件夹、文件名以这场的开始时间开头），绝不碰别的记录。
        var oldToRemove: URL?
        if let p = markdownPath {
            let old = URL(fileURLWithPath: p), want = desiredMarkdownURL
            let stamp = Fmt.fileStamp.string(from: startedAt) + " "
            if old != want, old.deletingLastPathComponent() == want.deletingLastPathComponent(),
               old.lastPathComponent.hasPrefix(stamp) {
                oldToRemove = old
                markdownPath = nil
            }
        }
        let url = markdownURL
        let md = MarkdownExporter.render(snap, vaultURL: settings.data.vaultURL)
        let json = isDemo ? nil : try? JSONEncoder().encode(snap)
        let snapshotURL = Self.snapshotURL
        let archiveURL = Self.archiveURL(sid)
        let fallback = Self.fallbackNotesURL.appendingPathComponent(url.lastPathComponent)
        // 写文件放后台：首次访问“文稿”目录时系统弹权限框，会卡住调用线程
        saveQueue.async { [weak self] in
            var written: URL?
            var err: String?
            if let json {
                try? json.write(to: snapshotURL, options: .atomic)
                try? json.write(to: archiveURL, options: .atomic)
            }
            do {
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try md.write(to: url, atomically: true, encoding: .utf8)
                written = url
                if let old = oldToRemove, old != url { try? FileManager.default.trashItem(at: old, resultingItemURL: nil) }
            } catch {
                err = error.localizedDescription
                if (try? FileManager.default.createDirectory(at: fallback.deletingLastPathComponent(), withIntermediateDirectories: true)) != nil,
                   (try? md.write(to: fallback, atomically: true, encoding: .utf8)) != nil {
                    written = fallback
                }
            }
            Task { @MainActor [weak self] in
                // 已经新建了别的记录：这次保存的结果不能再写回当前记录的状态
                guard let self, self.sessionID == sid else { return }
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
        openFileInObsidian(settings.data.vaultURL.appendingPathComponent(rel))
    }

    func openFileInObsidian(_ url: URL) {
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
        case .switchEngine:
            switchEngine()
        }
    }
}
