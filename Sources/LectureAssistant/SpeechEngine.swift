import Foundation
@preconcurrency import AVFoundation
import Speech
import CoreMedia

/// 麦克风 → 格式转换 → SpeechAnalyzer（系统离线听写模型），同时把音频写成 m4a。
/// 结果按顺序从 `events` 流出来。
final class SpeechEngine: @unchecked Sendable {
    struct FinalResult: Sendable {
        var text: String
        var start: Date
        var duration: Double
        var language: LectureLanguage
        /// 在识别器时间轴上的位置（秒）和识别器编号，用来取这一句的原始音频给本地引擎复核
        var audioStart: Double = 0
        var audioEnd: Double = 0
        var epoch: Int = -1
    }

    /// 最近 2 分钟的 16 kHz 16 位音频（识别器时间轴），环形存放
    struct PCMRing {
        var capacity: Int
        var buf: [Int16]
        var written: Int64 = 0
        init(seconds: Double, rate: Double) {
            capacity = Int(seconds * rate)
            buf = [Int16](repeating: 0, count: capacity)
        }
        mutating func reset() { written = 0 }
        mutating func append(_ p: UnsafePointer<Int16>, _ n: Int) {
            for i in 0..<n {
                buf[Int((written + Int64(i)) % Int64(capacity))] = p[i]
            }
            written += Int64(n)
        }
        func slice(from a: Int64, to b: Int64) -> Data? {
            let lo = max(a, written - Int64(capacity), 0), hi = min(b, written)
            guard hi > lo else { return nil }
            var out = [Int16](repeating: 0, count: Int(hi - lo))
            for i in 0..<out.count { out[i] = buf[Int((lo + Int64(i)) % Int64(capacity))] }
            return out.withUnsafeBufferPointer { Data(buffer: $0) }
        }
    }

    enum Event: Sendable {
        case volatile(String)
        case final(FinalResult)
        case level(Float)
        case error(String)
        case audioFile(URL)
        case sourceEnded
        case engine(Kind)
    }

    let events: AsyncStream<Event>
    private let eventSink: AsyncStream<Event>.Continuation

    private let engine = AVAudioEngine()
    private let lock = NSLock()
    private let writeQueue = DispatchQueue(label: "lecture.audio.write")

    // 以下状态由 lock 保护
    private var continuation: AsyncStream<AnalyzerInput>.Continuation?
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private var analyzerFormat: AVAudioFormat?
    private var streamStartDate: Date?
    private var audioFile: AVAudioFile?
    private var audioFileStarted = Date()
    private var recordingActive = false
    private var writeFailed = false
    private var lastLevelTime = Date.distantPast
    private var vad = PauseDetector()
    private var currentAnalyzer: SpeechAnalyzer?
    private var ring = PCMRing(seconds: 120, rate: 16000)
    private var epoch = 0

    private var analyzer: SpeechAnalyzer?
    private var resultsTask: Task<Void, Never>?
    private var feedTask: Task<Void, Never>?
    private var language: LectureLanguage = .chinese
    private var contextualStrings: [String] = []
    private var recordDir: URL?
    private var recordBaseName = "录音"
    private var recordPart = 0
    private var usingMic = false
    /// 用户在设置里选的识别模型
    var preferredEngine: ASREngine = .auto
    private(set) var currentKind: Kind?
    private(set) var isRunning = false

    static let rotateSeconds: TimeInterval = 15 * 60
    static let debug = ProcessInfo.processInfo.environment["LECTURE_DEBUG"] != nil

    init() {
        (events, eventSink) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    // MARK: 权限

    static func requestMicAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    // MARK: 模型

    enum Kind: String, Sendable {
        case transcriber = "长语音模型"
        case dictation = "听写模型"
    }

    /// 识别模块。优先用 SpeechTranscriber（长语音模型）：实测听写模型对真实会场的远场讲话完全不出字，
    /// 只对贴近麦克风的清晰语音有效。长语音模型没装好的语言才退回听写模型。
    static func makeModule(for lang: LectureLanguage, prefer: ASREngine = .auto) async -> (module: any SpeechModule, kind: Kind)? {
        let id = lang.rawValue
        let stInstalled = Set(await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })
        let canST = SpeechTranscriber.isAvailable && stInstalled.contains(id)
        if prefer != .dictation, canST, let loc = await SpeechTranscriber.supportedLocale(equivalentTo: lang.locale) {
            let m = SpeechTranscriber(locale: loc, transcriptionOptions: [],
                                      reportingOptions: [.volatileResults, .fastResults],
                                      attributeOptions: [.audioTimeRange])
            return (m, .transcriber)
        }
        guard let loc = await DictationTranscriber.supportedLocale(equivalentTo: lang.locale) else { return nil }
        let m = DictationTranscriber(locale: loc,
                                     contentHints: [.farField],
                                     transcriptionOptions: [.punctuation],
                                     reportingOptions: [.volatileResults, .frequentFinalization],
                                     attributeOptions: [.audioTimeRange])
        return (m, .dictation)
    }

    /// 检查该语言有没有能用的识别模型。返回 nil 表示可用，否则是给用户看的提示。
    /// 注意：模型系统里已经装了时，AssetInventory.status 对新应用仍报 supported（没预留），但实际能直接用；
    /// 所以看 installedLocales。下载请求可能永远不返回，只在两种模型都没装时才试。
    static func ensureModel(for lang: LectureLanguage) async -> String? {
        let id = lang.rawValue
        let st = Set(await SpeechTranscriber.installedLocales.map { $0.identifier(.bcp47) })
        let dict = Set(await DictationTranscriber.installedLocales.map { $0.identifier(.bcp47) })
        if st.contains(id) || dict.contains(id) { return nil }
        if let loc = await SpeechTranscriber.supportedLocale(equivalentTo: lang.locale) {
            let m = SpeechTranscriber(locale: loc, preset: .progressiveTranscription)
            if let req = try? await AssetInventory.assetInstallationRequest(supporting: [m]) {
                let ok = await race(timeout: 120) { (try? await req.downloadAndInstall()) != nil }
                if ok { return nil }
            }
        }
        return "\(lang.label) 识别模型还没装好：打开 系统设置 › 键盘 › 听写，把「\(lang.label)」加进语言列表，等下载完再点开始。"
    }

    /// 带超时地等一个异步操作；超时后不等它结束（TaskGroup 会等，所以不用它）
    static func race(timeout: TimeInterval, _ op: @escaping @Sendable () async -> Bool) async -> Bool {
        final class Once: @unchecked Sendable {
            private let lock = NSLock()
            private var done = false
            func fire() -> Bool { lock.withLock { defer { done = true }; return !done } }
        }
        let once = Once()
        return await withCheckedContinuation { cont in
            Task {
                let r = await op()
                if once.fire() { cont.resume(returning: r) }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                if once.fire() { cont.resume(returning: false) }
            }
        }
    }

    // MARK: 开始 / 停止

    /// 用麦克风实时识别
    func start(language: LectureLanguage, contextualStrings: [String], recordDir: URL?, recordBaseName: String) async throws {
        guard !isRunning else { return }
        try await prepare(language: language, contextualStrings: contextualStrings, recordDir: recordDir, recordBaseName: recordBaseName)
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            await finishAnalyzer()
            throw NSError(domain: "Lecture", code: 1, userInfo: [NSLocalizedDescriptionKey: "没有可用的麦克风输入"])
        }
        setInputFormat(inFormat)
        if recordDir != nil { writeQueue.sync { openAudioFile() } }
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            self?.handle(buffer: buffer)
        }
        engine.prepare()
        try engine.start()
        usingMic = true
        isRunning = true
        NotificationCenter.default.addObserver(self, selector: #selector(configChanged), name: .AVAudioEngineConfigurationChange, object: engine)
    }

    /// 把音频文件按实时速度（或 speed 倍速）喂进去，走和麦克风完全一样的流程。用于自测。
    func startSimulated(file url: URL, speed: Double, language: LectureLanguage, contextualStrings: [String], recordDir: URL?, recordBaseName: String) async throws {
        guard !isRunning else { return }
        let file = try AVAudioFile(forReading: url)
        try await prepare(language: language, contextualStrings: contextualStrings, recordDir: recordDir, recordBaseName: recordBaseName)
        let fmt = file.processingFormat
        setInputFormat(fmt)
        if recordDir != nil { writeQueue.sync { openAudioFile() } }
        usingMic = false
        isRunning = true
        let chunk: AVAudioFrameCount = 4096
        feedTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk) else { break }
                do { try file.read(into: buf, frameCount: chunk) } catch { break }
                if buf.frameLength == 0 { break }
                self?.handle(buffer: buf)
                let secs = Double(buf.frameLength) / fmt.sampleRate / max(speed, 0.1)
                try? await Task.sleep(nanoseconds: UInt64(secs * 1_000_000_000))
            }
            self?.eventSink.yield(.sourceEnded)
        }
    }

    private func prepare(language: LectureLanguage, contextualStrings: [String], recordDir: URL?, recordBaseName: String) async throws {
        self.language = language
        self.contextualStrings = contextualStrings
        self.recordDir = recordDir
        self.recordBaseName = recordBaseName
        lock.withLock {
            recordingActive = recordDir != nil
            writeFailed = false
        }
        try await startAnalyzer(language: language)
    }

    private func setInputFormat(_ f: AVAudioFormat) {
        lock.withLock {
            inputFormat = f
            if let af = analyzerFormat { converter = AVAudioConverter(from: f, to: af) }
        }
    }

    @objc private func configChanged(_ note: Notification) {
        // 换了输入设备（插拔耳机等）：重新装 tap 和转换器
        guard isRunning, usingMic else { return }
        let input = engine.inputNode
        let inFormat = input.outputFormat(forBus: 0)
        setInputFormat(inFormat)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: inFormat) { [weak self] buffer, _ in
            self?.handle(buffer: buffer)
        }
        do { try engine.start() } catch {
            eventSink.yield(.error("音频设备变化后重启失败：\(error.localizedDescription)"))
        }
    }

    /// 讲座中途切换语言：音频和录音不停，只换识别器
    func switchLanguage(_ lang: LectureLanguage, force: Bool = false) async {
        guard isRunning, lang != language || force else { language = lang; return }
        language = lang
        await finishAnalyzer()
        do {
            try await startAnalyzer(language: lang)
            if let f = lock.withLock({ inputFormat }) { setInputFormat(f) }
        } catch {
            eventSink.yield(.error("切换语言失败：\(error.localizedDescription)"))
        }
    }

    /// 取一句话的原始音频（16 kHz 16 位 PCM），前后各多留 pad 秒
    func pcm(for r: FinalResult, pad: Double = 0.3) -> Data? {
        lock.withLock {
            guard r.epoch == epoch else { return nil }
            let rate = 16000.0
            return ring.slice(from: Int64(max(0, r.audioStart - pad) * rate), to: Int64((r.audioEnd + pad) * rate))
        }
    }

    func stop() async {
        guard isRunning else { return }
        isRunning = false
        feedTask?.cancel()
        feedTask = nil
        if usingMic {
            NotificationCenter.default.removeObserver(self, name: .AVAudioEngineConfigurationChange, object: engine)
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        await finishAnalyzer()
        writeQueue.sync {
            lock.withLock { recordingActive = false }
            closeAudioFile()
        }
        eventSink.yield(.level(0))
    }

    // MARK: 识别器

    private func startAnalyzer(language: LectureLanguage) async throws {
        guard let (module, kind) = await Self.makeModule(for: language, prefer: preferredEngine) else {
            throw NSError(domain: "Lecture", code: 2, userInfo: [NSLocalizedDescriptionKey: "系统不支持 \(language.label) 识别"])
        }
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else {
            throw NSError(domain: "Lecture", code: 3, userInfo: [NSLocalizedDescriptionKey: "\(language.label) 识别模型没装好"])
        }
        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream(bufferingPolicy: .unbounded)
        let analyzer = SpeechAnalyzer(modules: [module], options: .init(priority: .userInitiated, modelRetention: .processLifetime))
        if !contextualStrings.isEmpty {
            let ctx = AnalysisContext()
            ctx.contextualStrings[.general] = contextualStrings
            try? await analyzer.setContext(ctx)
        }
        try await analyzer.prepareToAnalyze(in: format)
        try await analyzer.start(inputSequence: stream)
        self.analyzer = analyzer
        lock.withLock {
            self.analyzerFormat = format
            self.continuation = cont
            self.streamStartDate = nil
            self.currentAnalyzer = analyzer
            self.vad.reset(rate: format.sampleRate, language: language)
            self.ring = PCMRing(seconds: 120, rate: format.sampleRate)
            self.epoch += 1
        }
        resultsTask = consume(module, analyzer: analyzer, language: language, epoch: lock.withLock { epoch })
        currentKind = kind
        eventSink.yield(.engine(kind))
    }

    private func finishAnalyzer() async {
        let cont: AsyncStream<AnalyzerInput>.Continuation? = lock.withLock {
            let c = continuation
            continuation = nil
            return c
        }
        cont?.finish()
        if let analyzer {
            try? await analyzer.finalizeAndFinishThroughEndOfInput()
        }
        _ = await resultsTask?.value
        resultsTask = nil
        analyzer = nil
        lock.withLock { currentAnalyzer = nil }
        eventSink.yield(.volatile(""))
    }

    private func consume(_ module: any SpeechModule, analyzer: SpeechAnalyzer, language: LectureLanguage, epoch: Int) -> Task<Void, Never> {
        Task { [weak self] in
            func handle(_ text: AttributedString, _ range: CMTimeRange, _ isFinal: Bool) {
                let txt = String(text.characters)
                if Self.debug {
                    print("[asr] final=\(isFinal) len=\(txt.count) range=\(String(format: "%.1f-%.1f", range.start.seconds, range.end.seconds)) tail=\(txt.suffix(40))")
                }
                self?.lock.withLock { self?.vad.pendingChars = isFinal ? 0 : txt.count }
                self?.deliver(text: txt, range: range, isFinal: isFinal, language: language, epoch: epoch)
            }
            do {
                if let m = module as? SpeechTranscriber {
                    for try await r in m.results { handle(r.text, r.range, r.isFinal) }
                } else if let m = module as? DictationTranscriber {
                    for try await r in m.results { handle(r.text, r.range, r.isFinal) }
                }
            } catch {
                if !(error is CancellationError) { self?.eventSink.yield(.error("识别出错：\(error.localizedDescription)")) }
            }
        }
    }

    /// 听写模型要停顿很久才定稿（实测 30–50 秒一段），翻译会跟不上。
    /// 这里按音量找说话间隙，主动让识别器在间隙处定稿。
    struct PauseDetector {
        var rate: Double = 16000
        var fedFrames: Int64 = 0
        var history: [Float] = []          // 最近约 12 秒的分贝
        var silentSince: Double?
        var lastCut: Double = 0
        var pendingChars = 0
        var language: LectureLanguage = .chinese

        mutating func reset(rate: Double, language: LectureLanguage) {
            self = PauseDetector()
            self.rate = rate
            self.language = language
        }

        /// 喂一块音频，返回需要定稿的时间点（秒）
        mutating func feed(db: Float, frames: AVAudioFrameCount) -> Double? {
            let start = Double(fedFrames) / rate
            fedFrames += Int64(frames)
            let end = Double(fedFrames) / rate
            history.append(db)
            if history.count > 140 { history.removeFirst(history.count - 140) }
            guard history.count >= 12 else { return nil }
            let sorted = history.sorted()
            let floor = sorted[sorted.count / 10]
            let speech = sorted[sorted.count * 9 / 10]
            guard speech - floor > 8 else { return nil }      // 动态范围太小，分不出停顿
            let threshold = floor + (speech - floor) * 0.3
            if db < threshold {
                if silentSince == nil { silentSince = start }
            } else {
                silentSince = nil
            }
            let minChars = language == .english ? 40 : 14
            let sinceCut = end - lastCut
            if let s = silentSince, end - s >= 0.28, sinceCut >= 4, pendingChars >= minChars {
                lastCut = s + 0.12
                silentSince = nil
                return lastCut
            }
            // 一直没有停顿：太长了就在当前位置切
            if sinceCut >= 28, pendingChars >= minChars * 3 {
                lastCut = end
                return lastCut
            }
            return nil
        }
    }

    private func deliver(text: String, range: CMTimeRange, isFinal: Bool, language: LectureLanguage, epoch: Int) {
        guard isFinal else {
            eventSink.yield(.volatile(text))
            return
        }
        let base = lock.withLock { streamStartDate } ?? Date()
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let start = range.start.isNumeric ? base.addingTimeInterval(range.start.seconds) : Date()
        let dur = range.duration.isNumeric ? range.duration.seconds : 0
        eventSink.yield(.volatile(""))
        if !t.isEmpty, t.contains(where: { $0.isLetter || $0.isNumber }) {
            let a = range.start.isNumeric ? range.start.seconds : 0
            eventSink.yield(.final(FinalResult(text: t, start: start, duration: dur, language: language,
                                               audioStart: a, audioEnd: a + dur, epoch: epoch)))
        }
    }

    // MARK: 音频线程

    private func handle(buffer: AVAudioPCMBuffer) {
        let now = Date()
        let (conv, fmt, cont, sendLevel) = lock.withLock { () -> (AVAudioConverter?, AVAudioFormat?, AsyncStream<AnalyzerInput>.Continuation?, Bool) in
            var send = false
            if now.timeIntervalSince(lastLevelTime) > 0.1 { lastLevelTime = now; send = true }
            if streamStartDate == nil, continuation != nil { streamStartDate = now }
            return (converter, analyzerFormat, continuation, send)
        }
        if sendLevel { eventSink.yield(.level(Self.level(buffer))) }
        guard let conv, let fmt else { return }

        let ratio = fmt.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio + 1024)
        guard let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: capacity) else { return }
        var fed = false
        var err: NSError?
        let status = conv.convert(to: out, error: &err) { _, outStatus in
            if fed { outStatus.pointee = .noDataNow; return nil }
            fed = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, out.frameLength > 0 else { return }
        cont?.yield(AnalyzerInput(buffer: out))
        if fmt.sampleRate == 16000, fmt.channelCount == 1 {
            if let p = out.int16ChannelData {
                lock.withLock { ring.append(p[0], Int(out.frameLength)) }
            } else if let f = out.floatChannelData {
                let n = Int(out.frameLength)
                var tmp = [Int16](repeating: 0, count: n)
                for i in 0..<n { tmp[i] = Int16(max(-1, min(1, f[0][i])) * 32767) }
                tmp.withUnsafeBufferPointer { bp in lock.withLock { ring.append(bp.baseAddress!, n) } }
            }
        }
        let db = Self.decibels(buffer)
        let (cut, an) = lock.withLock { (vad.feed(db: db, frames: out.frameLength), currentAnalyzer) }
        if let cut, let an {
            if Self.debug { print(String(format: "[vad] finalize through %.2fs", cut)) }
            Task { try? await an.finalize(through: CMTime(seconds: cut, preferredTimescale: 1000)) }
        }
        writeQueue.async { [weak self] in self?.write(out) }
    }

    // 以下在 writeQueue 上执行
    private func write(_ buffer: AVAudioPCMBuffer) {
        let (active, needRotate) = lock.withLock { () -> (Bool, Bool) in
            (recordingActive && !writeFailed, audioFile == nil || Date().timeIntervalSince(audioFileStarted) > Self.rotateSeconds)
        }
        guard active else { return }
        if needRotate { openAudioFile() }
        guard let file = lock.withLock({ audioFile }) else { return }
        do { try file.write(from: buffer) } catch {
            lock.withLock { writeFailed = true }
            eventSink.yield(.error("录音写入失败（识别不受影响）：\(error.localizedDescription)"))
        }
    }

    private func openAudioFile() {
        guard let dir = recordDir, let fmt = lock.withLock({ analyzerFormat }) else { return }
        closeAudioFile()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        recordPart += 1
        var url = dir.appendingPathComponent("\(recordBaseName) 第\(recordPart)段.m4a")
        while FileManager.default.fileExists(atPath: url.path) {
            recordPart += 1
            url = dir.appendingPathComponent("\(recordBaseName) 第\(recordPart)段.m4a")
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVSampleRateKey: fmt.sampleRate,
            AVNumberOfChannelsKey: Int(fmt.channelCount),
            AVEncoderBitRateKey: 32000,
        ]
        do {
            let f = try AVAudioFile(forWriting: url, settings: settings, commonFormat: fmt.commonFormat, interleaved: fmt.isInterleaved)
            lock.withLock {
                audioFile = f
                audioFileStarted = Date()
            }
            eventSink.yield(.audioFile(url))
        } catch {
            lock.withLock { writeFailed = true }
            eventSink.yield(.error("没法创建录音文件（识别不受影响）：\(error.localizedDescription)"))
        }
    }

    private func closeAudioFile() {
        let f: AVAudioFile? = lock.withLock {
            let f = audioFile
            audioFile = nil
            return f
        }
        f?.close()
    }

    private static func decibels(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return -100 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        let ch = data[0]
        for i in 0..<n { sum += ch[i] * ch[i] }
        return 20 * log10(max(sqrt(sum / Float(n)), 1e-7))
    }

    private static func level(_ buffer: AVAudioPCMBuffer) -> Float {
        max(0, min(1, (decibels(buffer) + 60) / 60))
    }

    // MARK: 文件识别（导入录音）

    static func transcribeFile(_ url: URL, language: LectureLanguage, contextualStrings: [String], startDate: Date, prefer: ASREngine = .auto,
                               onFinal: @escaping @Sendable (FinalResult) async -> Void,
                               onProgress: (@Sendable (Double) async -> Void)? = nil) async throws {
        guard let (module, _) = await makeModule(for: language, prefer: prefer) else {
            throw NSError(domain: "Lecture", code: 2, userInfo: [NSLocalizedDescriptionKey: "系统不支持 \(language.label) 识别"])
        }
        let file = try AVAudioFile(forReading: url)
        let total = Double(file.length) / file.processingFormat.sampleRate
        let analyzer = SpeechAnalyzer(modules: [module])
        if !contextualStrings.isEmpty {
            let ctx = AnalysisContext()
            ctx.contextualStrings[.general] = contextualStrings
            try? await analyzer.setContext(ctx)
        }
        @Sendable func emit(_ text: AttributedString, _ range: CMTimeRange) async {
            let t = String(text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { return }
            let start = startDate.addingTimeInterval(range.start.isNumeric ? range.start.seconds : 0)
            await onFinal(FinalResult(text: t, start: start, duration: range.duration.isNumeric ? range.duration.seconds : 0, language: language))
            if total > 0, range.end.isNumeric { await onProgress?(min(1, range.end.seconds / total)) }
        }
        let collector = Task {
            if let m = module as? SpeechTranscriber {
                for try await r in m.results where r.isFinal { await emit(r.text, r.range) }
            } else if let m = module as? DictationTranscriber {
                for try await r in m.results where r.isFinal { await emit(r.text, r.range) }
            }
        }
        if let last = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: last)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        try await collector.value
    }
}
