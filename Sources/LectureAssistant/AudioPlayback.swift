import Foundation
import AVFoundation
import Observation

/// 回放录音：按转写里的时间跳到对应的录音位置
@MainActor
@Observable
final class AudioPlayback {
    struct Part: Identifiable, Hashable {
        var id: String { url.path }
        var name: String
        var url: URL
        var start: Date
        var duration: TimeInterval?     // nil：打不开（多半是还在录的那段）
        var end: Date? { duration.map { start.addingTimeInterval($0) } }
    }

    var parts: [Part] = []
    var current: Int?
    var isPlaying = false
    var time: TimeInterval = 0
    var duration: TimeInterval = 0
    var rate: Float = 1.0
    var message: String?

    @ObservationIgnored private var player: AVAudioPlayer?
    @ObservationIgnored private var timer: Timer?

    /// 当前播放到的墙钟时间，用来高亮对应的句子
    var wallTime: Date? {
        guard let i = current, parts.indices.contains(i), player != nil else { return nil }
        return parts[i].start.addingTimeInterval(time)
    }

    func load(parts list: [AudioPart], files: [String], resolve: (String) -> URL?) {
        stop()
        var out: [Part] = []
        var seen = Set<String>()
        var entries = list
        // 旧记录只有文件名：用文件的创建时间当开始时间
        for f in files where !list.contains(where: { $0.name == f }) {
            if let u = resolve(f),
               let d = (try? u.resourceValues(forKeys: [.creationDateKey]))?.creationDate {
                entries.append(AudioPart(name: f, start: d))
            }
        }
        for p in entries.sorted(by: { $0.start < $1.start }) {
            guard let u = resolve(p.name), FileManager.default.fileExists(atPath: u.path), seen.insert(u.path).inserted else { continue }
            out.append(Part(name: u.lastPathComponent, url: u, start: p.start, duration: Self.duration(of: u)))
        }
        parts = out
        current = out.isEmpty ? nil : 0
        duration = out.first?.duration ?? 0
        time = 0
    }

    /// 刷新各段时长（正在录的那段停止后才能打开）
    func refreshDurations() {
        for i in parts.indices where parts[i].duration == nil {
            parts[i].duration = Self.duration(of: parts[i].url)
        }
    }

    private static func duration(of url: URL) -> TimeInterval? {
        guard let f = try? AVAudioFile(forReading: url), f.length > 0 else { return nil }
        return Double(f.length) / f.processingFormat.sampleRate
    }

    /// 从某个时刻开始播放（点句子的时间）
    func play(at date: Date) {
        refreshDurations()
        if let i = parts.firstIndex(where: { p in p.end.map { date >= p.start.addingTimeInterval(-1) && date <= $0 } ?? false }) {
            play(part: i, offset: max(0, date.timeIntervalSince(parts[i].start) - 0.5))
        } else if parts.contains(where: { $0.duration == nil && date >= $0.start }) {
            message = "这一段还在录音，停止录音后才能回放"
        } else {
            message = "这句话的时间不在任何一段录音里"
        }
    }

    func play(part i: Int, offset: TimeInterval = 0) {
        guard parts.indices.contains(i) else { return }
        message = nil
        if current != i || player == nil {
            player?.stop()
            guard let p = try? AVAudioPlayer(contentsOf: parts[i].url) else {
                message = "打不开这段录音（如果还在录，停止后再放）"
                return
            }
            p.enableRate = true
            p.rate = rate
            p.prepareToPlay()
            player = p
            current = i
            duration = p.duration
        }
        player?.currentTime = min(max(0, offset), max(0, duration - 0.1))
        time = player?.currentTime ?? offset
        player?.play()
        isPlaying = true
        startTimer()
    }

    func toggle() {
        if isPlaying {
            player?.pause()
            isPlaying = false
        } else if player != nil {
            player?.play()
            isPlaying = true
            startTimer()
        } else if let i = current {
            play(part: i, offset: time)
        }
    }

    func seek(_ t: TimeInterval) {
        time = t
        if let p = player { p.currentTime = t; time = p.currentTime } else if let i = current { play(part: i, offset: t); player?.pause(); isPlaying = false }
    }

    func skip(_ dt: TimeInterval) { seek(min(max(0, time + dt), duration)) }

    func setRate(_ r: Float) {
        rate = r
        player?.rate = r
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        timer?.invalidate()
        timer = nil
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard let p = player else { return }
        time = p.currentTime
        if !p.isPlaying, isPlaying {
            isPlaying = false
            // 这段放完了，接着放下一段
            if let i = current, time >= duration - 0.3, i + 1 < parts.count, parts[i + 1].duration != nil {
                play(part: i + 1)
            }
        }
    }
}
