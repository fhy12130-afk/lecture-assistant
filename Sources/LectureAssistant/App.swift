import SwiftUI
import AppKit

@main
enum Main {
    static func main() {
        if ["--selftest", "--searchtest", "--renderdemo"].contains(where: CommandLine.arguments.contains) {
            SelfTest.launch()
        } else {
            LectureAssistantApp.main()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var store: SessionStore?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else { return .terminateNow }
        // 先停录音，让 m4a 正常收尾，再保存
        Task { @MainActor in
            await store.stop()
            store.flushSaves()
            await LocalASR.shared.stop()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

struct LectureAssistantApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var store = SessionStore()
    @StateObject private var settings = AppSettings.shared

    var body: some Scene {
        WindowGroup("讲座助手") {
            ContentView()
                .environment(store)
                .environmentObject(settings)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear {
                    delegate.store = store
                    DebugHooks.run(store)
                }
        }
        .defaultSize(width: 1320, height: 860)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建一场记录") { Task { await store.newSession() } }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandMenu("讲座") {
                Button(store.isRecording ? "停止" : "开始") { store.toggleRecording() }
                    .keyboardShortcut("r", modifiers: .command)
                Button("立即总结") { Task { await store.summarize() } }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Button("被点名了！马上给一个问题") { store.generateQuestions(.quick) }
                    .keyboardShortcut("j", modifiers: .command)
                Button("生成问题清单") { store.generateQuestions(.full) }
                Divider()
                Button("打开记录（Obsidian）") { store.openMarkdown() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandGroup(after: .toolbar) {
                Button("放大字号") { settings.data.fontSize = min(28, settings.data.fontSize + 1) }
                    .keyboardShortcut("+", modifiers: .command)
                Button("缩小字号") { settings.data.fontSize = max(11, settings.data.fontSize - 1) }
                    .keyboardShortcut("-", modifiers: .command)
            }
        }
        Settings {
            SettingsView()
                .environment(store)
                .environmentObject(settings)
        }
    }
}
