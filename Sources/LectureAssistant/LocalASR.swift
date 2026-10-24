import Foundation

/// 本地第二识别引擎：后台跑 scripts/asr_server.py（sherpa-onnx 的 SenseVoice / Paraformer），
/// 每句话定稿后把那段音频再识别一遍，和系统识别的结果一起交给 AI 综合。
/// 只监听 127.0.0.1。没装好就自动不用，不影响主流程。
actor LocalASR {
    static let shared = LocalASR()
    let port = 18765

    private var process: Process?
    private(set) var engines: [String] = []
    private var starting = false

    static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LectureAssistant", isDirectory: true)
    }
    static var pythonURL: URL { supportDir.appendingPathComponent("asr-venv/bin/python") }
    static var modelsURL: URL { supportDir.appendingPathComponent("models", isDirectory: true) }
    static var scriptURL: URL? {
        if let u = Bundle.main.url(forResource: "asr_server", withExtension: "py") { return u }
        let local = supportDir.appendingPathComponent("asr_server.py")
        return FileManager.default.fileExists(atPath: local.path) ? local : nil
    }

    static var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: pythonURL.path) && scriptURL != nil
            && ((try? FileManager.default.contentsOfDirectory(atPath: modelsURL.path))?.contains { $0.hasPrefix("sherpa-onnx-") } ?? false)
    }

    var isReady: Bool { !engines.isEmpty }

    /// 启动（或连上已经在跑的）服务；返回加载的模型名，失败返回空
    @discardableResult
    func start() async -> [String] {
        // 另一个调用正在启动：等它的结果
        while starting { try? await Task.sleep(nanoseconds: 200_000_000) }
        if !engines.isEmpty { return engines }
        if let e = await health() { engines = e; return e }
        guard Self.isInstalled, !starting, let script = Self.scriptURL else { return [] }
        starting = true
        defer { starting = false }
        let p = Process()
        p.executableURL = Self.pythonURL
        p.arguments = [script.path, "--models", Self.modelsURL.path, "--port", String(port), "--threads", "4"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle(forWritingAtPath: "/dev/null")
        do { try p.run() } catch { return [] }
        process = p
        for _ in 0..<60 {
            try? await Task.sleep(nanoseconds: 300_000_000)
            if let e = await health() { engines = e; return e }
            if !p.isRunning { break }
        }
        return []
    }

    func stop() {
        process?.terminate()
        process = nil
        engines = []
    }

    private func health() async -> [String]? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/health") else { return nil }
        var r = URLRequest(url: url, timeoutInterval: 1.5)
        r.httpMethod = "GET"
        guard let (data, resp) = try? await URLSession.shared.data(for: r),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let e = obj["engines"] as? [String], !e.isEmpty else { return nil }
        return e
    }

    struct Result: Sendable {
        var text: String
        var engines: [String: String]
    }

    /// pcm：16 kHz 单声道 16 位小端
    func recognize(_ pcm: Data, language: LectureLanguage) async -> Result? {
        guard !engines.isEmpty, !pcm.isEmpty,
              let url = URL(string: "http://127.0.0.1:\(port)/asr?lang=\(language == .english ? "en" : "zh")") else { return nil }
        var r = URLRequest(url: url, timeoutInterval: 15)
        r.httpMethod = "POST"
        r.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        r.httpBody = pcm
        guard let (data, resp) = try? await URLSession.shared.data(for: r),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            // 服务挂了：下次再试着拉起来
            if await health() == nil { engines = [] }
            return nil
        }
        return Result(text: obj["text"] as? String ?? "", engines: obj["engines"] as? [String: String] ?? [:])
    }
}
