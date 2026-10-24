import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            APISettings().tabItem { Label("AI 接口", systemImage: "network") }
            LectureSettings().tabItem { Label("讲座", systemImage: "mic") }
            ProfileSettings().tabItem { Label("我的资料", systemImage: "person.text.rectangle") }
            StorageSettings().tabItem { Label("存储", systemImage: "folder") }
        }
        .frame(width: 680, height: 560)
    }
}

private let knownModels = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-opus-5", "claude-sonnet-5", "claude-opus-4-8"]

struct APISettings: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(SessionStore.self) private var store
    @State private var inlineKey = ""
    @State private var testResult = ""
    @State private var testing = false

    var body: some View {
        Form {
            Section("接口（Anthropic 官方，或兼容的中转）") {
                TextField("地址", text: $settings.data.apiBaseURL)
                Picker("接口格式", selection: $settings.data.apiFormat) {
                    ForEach(APIFormat.allCases) { Text($0.label).tag($0) }
                }
                Picker("API key", selection: $settings.data.keyMode) {
                    Text("从文件读取").tag(KeyMode.file)
                    Text("手动填写").tag(KeyMode.inline)
                }
                if settings.data.keyMode == .file {
                    TextField("key 文件", text: $settings.data.keyFilePath)
                    Text("文件里只放 key 本身。应用每次请求时读取，不会把 key 复制到别处。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack {
                        SecureField(settings.hasInlineKey ? "已保存（重新填写可覆盖）" : "粘贴 key", text: $inlineKey)
                        Button("保存") {
                            settings.saveInlineKey(inlineKey)
                            inlineKey = ""
                            testResult = "已保存"
                        }
                        .disabled(inlineKey.isEmpty)
                    }
                }
                HStack {
                    Button(testing ? "测试中…" : "测试连接") {
                        testing = true
                        Task {
                            testResult = await store.testConnection()
                            testing = false
                        }
                    }
                    .disabled(testing)
                    Text(testResult).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
            }
            Section("模型") {
                modelField("回答 / 总结 / 提问", text: $settings.data.mainModel)
                modelField("翻译 / 校正 / 关键词", text: $settings.data.fastModel)
                Picker("解惑深度", selection: $settings.data.answerEffort) {
                    ForEach(Effort.allCases) { Text($0.label).tag($0) }
                }
                Picker("提问清单深度", selection: $settings.data.questionEffort) {
                    ForEach(Effort.allCases) { Text($0.label).tag($0) }
                }
                Text("翻译和总结固定用 low 档求快；主模型拒答时自动改用 claude-sonnet-5-5 重试一次。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func modelField(_ title: String, text: Binding<String>) -> some View {
        HStack {
            TextField(title, text: text)
            Menu("常用") {
                ForEach(knownModels, id: \.self) { m in Button(m) { text.wrappedValue = m } }
            }
            .fixedSize()
        }
    }
}

struct LectureSettings: View {
    @EnvironmentObject private var settings: AppSettings

    var body: some View {
        Form {
            Section("新记录的默认值") {
                TextField("讲座标题", text: $settings.data.sessionTitle)
                TextField("主讲人", text: $settings.data.speakerName)
                TextField("领域（翻译和纠错时参考，如：结构工程、机器学习）", text: $settings.data.domain)
            }
            Section("识别与 AI") {
                Toggle("英文自动翻译成中文 / 中文自动校正错字", isOn: $settings.data.autoSecondary)
                Stepper("每 \(settings.data.summaryIntervalMin) 分钟自动总结一次", value: $settings.data.summaryIntervalMin, in: 1...30)
                Toggle("同时录音（m4a，存进 Obsidian 附件）", isOn: $settings.data.recordAudio)
                HStack {
                    Text("字号")
                    Slider(value: $settings.data.fontSize, in: 12...24, step: 1)
                    Text("\(Int(settings.data.fontSize))").monospacedDigit()
                }
            }
            Section("术语表（每行一个，用来提高识别和翻译准确度）") {
                TextEditor(text: $settings.data.glossary)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 150)
            }
        }
        .formStyle(.grouped)
    }
}

struct ProfileSettings: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(SessionStore.self) private var store

    var body: some View {
        Form {
            Section("我的背景（解惑和提问都会参考）") {
                TextEditor(text: $settings.data.myProfile).frame(height: 130)
            }
            Section("主讲人信息") {
                TextEditor(text: $settings.data.speakerProfile).frame(height: 110)
            }
            Section("提问时想从哪些角度连到我的研究（可不填）") {
                TextEditor(text: $settings.data.questionFocus).frame(height: 50)
            }
            Section("每次都带上的笔记（相对 vault 的路径，每行一个，每篇最多取 7000 字）") {
                TextEditor(text: $settings.data.pinnedNotes)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 80)
                HStack {
                    Button("重新读取") { Task { await store.reindexVault() } }
                    Button("恢复默认内容") { settings.resetProfiles() }
                    Spacer()
                    Text("已加载 \(store.pinnedCache.count) 篇").font(.caption).foregroundStyle(.secondary)
                }
                Text("“恢复默认内容”会回到个人预设文件 \(AppSettings.presetURL.path) 里的值（没有这个文件就清空）。")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

struct StorageSettings: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(SessionStore.self) private var store

    var body: some View {
        Form {
            Section("Obsidian 笔记库") {
                TextField("vault 路径", text: $settings.data.vaultPath)
                TextField("讲座记录文件夹", text: $settings.data.notesFolder)
                TextField("录音文件夹", text: $settings.data.audioFolder)
                HStack {
                    Button("重新索引") { Task { await store.reindexVault() } }
                    Text("已索引 \(store.vaultDocCount) 篇 .md").font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("当前记录") {
                LabeledContent("Markdown", value: store.markdownURL.path)
                LabeledContent("录音", value: store.audioFiles.isEmpty ? "（还没有）" : store.audioFiles.joined(separator: "\n"))
                LabeledContent("崩溃恢复快照", value: SessionStore.snapshotURL.path)
            }
        }
        .formStyle(.grouped)
    }
}
