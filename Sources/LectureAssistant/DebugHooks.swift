import AppKit
import SwiftUI

/// 调试用：LECTURE_DEMO=会话json 载入演示数据；LECTURE_SNAPSHOT=前缀 把窗口截成 PNG（不需要录屏权限）。
@MainActor
enum DebugHooks {
    static func run(_ store: SessionStore) {
        let env = ProcessInfo.processInfo.environment
        if let demo = env["LECTURE_DEMO"] { store.loadDemo(URL(fileURLWithPath: demo)) }
        guard let prefix = env["LECTURE_SNAPSHOT"] else { return }
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if let sel = store.segments.dropLast().last { store.selected = [sel.id] }
            for tab in SessionStore.SideTab.allCases {
                store.sideTab = tab
                try? await Task.sleep(nanoseconds: 900_000_000)
                snapshot(to: "\(prefix)-\(tab.rawValue).png")
            }
            if env["LECTURE_SNAPSHOT_SETTINGS"] != nil {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                snapshot(to: "\(prefix)-设置.png", key: true)
            }
            if env["LECTURE_SNAPSHOT_QUIT"] != nil { NSApp.terminate(nil) }
        }
    }

    static func snapshot(to path: String, key: Bool = false) {
        let wins = NSApp.windows.filter { $0.isVisible && $0.contentView != nil && $0.frame.width > 300 }
        guard let win = key ? (NSApp.keyWindow ?? wins.last) : wins.first(where: { $0.toolbar != nil }) ?? wins.first,
              let content = win.contentView else { return }
        if ProcessInfo.processInfo.environment["LECTURE_SNAPSHOT_TREE"] != nil {
            var out = "== window \(win.title) \(win.frame)\n"
            func dump(_ v: NSView, _ depth: Int) {
                guard depth < 14 else { return }
                let name = String(describing: type(of: v))
                if !name.hasPrefix("_") || depth < 3 {
                    out += String(repeating: " ", count: depth) + "\(name) \(Int(v.frame.minX)),\(Int(v.frame.minY)) \(Int(v.frame.width))x\(Int(v.frame.height))\n"
                }
                for c in v.subviews { dump(c, depth + 1) }
            }
            dump(content, 0)
            out += "== accessibility\n"
            func ax(_ e: Any, _ depth: Int) {
                guard depth < 30, let el = e as? NSAccessibilityElementProtocol & NSObjectProtocol else { return }
                let o = el as AnyObject
                let role = (o.accessibilityRole?() ?? nil)?.rawValue ?? "?"
                let label = (o.accessibilityLabel?() ?? nil) ?? ""
                let value = (o.accessibilityValue?() ?? nil).map { "\($0)" } ?? ""
                let frame = o.accessibilityFrame?() ?? .zero
                let text = (label + " " + value).trimmingCharacters(in: .whitespaces)
                if !text.isEmpty || role.contains("Group") == false {
                    out += String(repeating: " ", count: depth) + "\(role) [\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))] \(text.prefix(60))\n"
                }
                for c in (o.accessibilityChildren?() ?? nil) ?? [] { ax(c, depth + 1) }
            }
            ax(win, 0)
            try? out.write(toFile: path + ".tree.txt", atomically: true, encoding: .utf8)
        }
        // 用图层渲染整个窗口（含标题栏），SwiftUI 内容在 cacheDisplay 里常是空白
        let root = content.superview ?? content
        root.layoutSubtreeIfNeeded()
        root.displayIfNeeded()
        let scale = win.backingScaleFactor
        let size = root.bounds.size
        guard let layer = root.layer, let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale),
                                                         bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        ctx.scaleBy(x: scale, y: scale)
        if !root.isFlipped {
            // CALayer 坐标系与位图一致即可
        }
        layer.render(in: ctx)
        guard let img = ctx.makeImage() else { return }
        let rep = NSBitmapImageRep(cgImage: img)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

extension SessionStore {
    func loadDemo(_ url: URL) {
        guard let data = try? Data(contentsOf: url), let s = try? JSONDecoder().decode(LectureSession.self, from: data) else { return }
        isDemo = true
        notesDirOverride = URL(fileURLWithPath: "/tmp/lecture-demo", isDirectory: true)
        sessionID = s.id
        title = s.title
        speaker = s.speaker
        startedAt = s.startedAt
        segments = s.segments
        summaries = s.summaries
        overallSummary = s.overallSummary
        qas = s.qas
        questionSets = s.questionSets
        audioFiles = s.audioFiles
        myNotes = s.myNotes
        markdownPath = nil
        lastSummarizedSegmentID = s.lastSummarizedSegmentID
        volatileText = "接下来我想给大家看一个具体的例子，就是车桥耦合振动的"
        recordedSeconds = 1234
    }
}
