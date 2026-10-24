import Foundation

extension SessionStore {
    // MARK: 公共

    func makeClient() -> LLMClient? {
        guard let cfg = settings.llmConfig() else {
            lastAPIError = LLMError.noKey.errorDescription
            show(LLMError.noKey.errorDescription!, error: true, action: .openSettings)
            return nil
        }
        return LLMClient(config: cfg)
    }

    func makeContext() -> Assistant.Context {
        let d = settings.data
        return Assistant.Context(title: title, speaker: speaker, myProfile: d.myProfile, speakerProfile: d.speakerProfile,
                                 pinnedNotes: pinnedCache, glossary: d.glossaryTerms, domain: d.domain, questionFocus: d.questionFocus)
    }

    /// 最近若干句（从后往前取，不超过 maxChars）
    func recentLines(maxChars: Int, before: Date? = nil) -> [String] {
        var out: [String] = []
        var n = 0
        for seg in segments.reversed() {
            if let b = before, seg.time > b { continue }
            let line = seg.promptLine
            if n + line.count > maxChars, !out.isEmpty { break }
            out.append(line)
            n += line.count
        }
        return out.reversed()
    }

    private func noteAPI(_ error: Error?) {
        if let error {
            lastAPIError = error.localizedDescription
        } else {
            lastAPIError = nil
            lastAPIOK = Date()
        }
    }

    private func updateSegment(_ id: UUID, _ f: (inout Segment) -> Void) {
        guard let i = segments.firstIndex(where: { $0.id == id }) else { return }
        f(&segments[i])
    }

    // MARK: 翻译 / 校正

    func enqueueSecondary(_ ids: [UUID]) {
        secondaryQueue.append(contentsOf: ids)
        secondaryPending = secondaryQueue.count
        pumpSecondary()
    }

    func retryFailedSecondary() {
        let ids = segments.filter { $0.secondaryFailed || $0.secondary == nil }.map(\.id).filter { !secondaryQueue.contains($0) }
        enqueueSecondary(ids)
    }

    var secondaryIdle: Bool { !secondaryWorkerRunning && secondaryQueue.isEmpty }

    private func pumpSecondary() {
        guard !secondaryWorkerRunning, !secondaryQueue.isEmpty else { return }
        guard let client = makeClient() else {
            for id in secondaryQueue { updateSegment(id) { $0.secondaryFailed = true } }
            secondaryQueue.removeAll()
            secondaryPending = 0
            return
        }
        secondaryWorkerRunning = true
        Task {
            while !secondaryQueue.isEmpty {
                // 同一语言的连续几句一起处理，排队越多一批越大
                var batch: [Segment] = []
                var chars = 0
                let maxCount = secondaryQueue.count > 8 ? 10 : 5
                while let id = secondaryQueue.first, batch.count < maxCount {
                    guard let seg = segments.first(where: { $0.id == id }) else { secondaryQueue.removeFirst(); continue }
                    if let f = batch.first, f.language != seg.language { break }
                    if chars > 1500, !batch.isEmpty { break }
                    batch.append(seg)
                    chars += seg.text.count
                    secondaryQueue.removeFirst()
                }
                secondaryPending = secondaryQueue.count + batch.count
                guard let first = batch.first else { continue }

                let prev = segments.filter { $0.time < first.time && $0.language == first.language }.suffix(3).map { s -> String in
                    if let sec = s.secondary { return "\(s.text)\n→ \(sec)" }
                    return s.text
                }
                let items = batch.enumerated().map { Assistant.SecondaryItem(id: $0.offset + 1, text: $0.element.text) }
                do {
                    let res = try await Assistant.secondary(items, language: first.language, previous: Array(prev),
                                                            ctx: makeContext(), client: client, model: settings.data.fastModel)
                    for (i, seg) in batch.enumerated() {
                        if let v = res[i + 1]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
                            updateSegment(seg.id) { $0.secondary = v; $0.secondaryFailed = false }
                        } else {
                            updateSegment(seg.id) { $0.secondaryFailed = true }
                        }
                    }
                    noteAPI(nil)
                } catch {
                    for seg in batch { updateSegment(seg.id) { $0.secondaryFailed = true } }
                    noteAPI(error)
                }
                scheduleSave()
            }
            secondaryWorkerRunning = false
            secondaryPending = 0
        }
    }

    // MARK: 摘要

    var unsummarizedSegments: [Segment] {
        guard let lastID = lastSummarizedSegmentID, let i = segments.firstIndex(where: { $0.id == lastID }) else { return segments }
        return Array(segments[(i + 1)...])
    }

    func summarizeIfDue() {
        guard isRecording, !isSummarizing else { return }
        let interval = TimeInterval(max(1, settings.data.summaryIntervalMin) * 60)
        let since = lastSummaryAt ?? recordingSince ?? startedAt
        guard Date().timeIntervalSince(since) >= interval else { return }
        let pending = unsummarizedSegments.reduce(0) { $0 + $1.text.count }
        guard pending >= 120 else { return }
        Task { await summarize() }
    }

    func summarize() async {
        guard !isSummarizing else { return }
        var segs = unsummarizedSegments
        guard !segs.isEmpty else { flash("没有新的内容需要总结"); return }
        guard let client = makeClient() else { return }
        isSummarizing = true
        defer { isSummarizing = false; liveSummary = nil }
        while !segs.isEmpty {
            var chunk: [Segment] = []
            var n = 0
            for s in segs {
                if n > 7000, !chunk.isEmpty { break }
                chunk.append(s)
                n += s.promptLine.count
            }
            segs.removeFirst(chunk.count)
            let from = chunk.first!.time
            let to = chunk.last!.time.addingTimeInterval(chunk.last!.duration)
            let req = Assistant.summaryRequest(newLines: chunk.map(\.promptLine), from: from, to: to,
                                               overall: overallSummary, ctx: makeContext(), model: settings.data.mainModel)
            liveSummary = ""
            do {
                let r = try await client.stream(req) { [weak self] ev in
                    if case .text(let t) = ev { await self?.appendLiveSummary(t) }
                }
                let out = Assistant.parseSummary(r.text)
                var points = out.points
                if !out.relevance.isEmpty { points += "\n\n**与我相关**\n" + out.relevance }
                summaries.append(SummaryBlock(createdAt: Date(), from: from, to: to, points: points))
                if !out.overall.isEmpty { overallSummary = out.overall }
                lastSummarizedSegmentID = chunk.last!.id
                lastSummaryAt = Date()
                noteAPI(nil)
                scheduleSave()
            } catch {
                noteAPI(error)
                lastSummaryAt = Date()   // 失败了也等下一个周期再试，别连续刷
                show("总结失败：\(error.localizedDescription)", error: true)
                break
            }
        }
    }

    private func appendLiveSummary(_ t: String) { liveSummary = (liveSummary ?? "") + t }

    // MARK: 解惑

    var canAsk: Bool { !selected.isEmpty || !qaDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    @discardableResult
    func askAboutSelection() -> UUID? {
        guard canAsk, let client = makeClient() else { return nil }
        let segs = selectedSegments
        let quotes = segs.map { s -> String in
            var q = "[\(Fmt.clock(s.time))] \(s.text)"
            if let sec = s.secondary, sec != s.text { q += s.language == .english ? "\n（译）\(sec)" : "\n（校正）\(sec)" }
            return q
        }
        let question = qaDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let item = QAItem(createdAt: Date(), quotes: quotes, question: question, webSearch: qaWebSearch)
        qas.insert(item, at: 0)
        selected = []
        qaDraft = ""
        sideTab = .qa
        let id = item.id
        let anchor = segs.last?.time
        let webSearch = qaWebSearch
        Task { await runQA(id: id, quotes: quotes, question: question, segs: segs, anchor: anchor, webSearch: webSearch, client: client) }
        return id
    }

    private func updateQA(_ id: UUID, _ f: (inout QAItem) -> Void) {
        guard let i = qas.firstIndex(where: { $0.id == id }) else { return }
        f(&qas[i])
    }

    private func runQA(id: UUID, quotes: [String], question: String, segs: [Segment], anchor: Date?, webSearch: Bool, client: LLMClient) async {
        let d = settings.data
        let queryText = (segs.map { $0.text + " " + ($0.secondary ?? "") } + [question]).joined(separator: "\n")
        updateQA(id) { $0.answer = "" }
        let kws = await Assistant.keywords(for: queryText, client: client, model: d.fastModel)
        let hits = await vault.search(kws, limit: 6)
        updateQA(id) { $0.vaultRefs = hits.map { VaultRef(path: $0.path, title: $0.title) } }
        let recent = recentLines(maxChars: 2500, before: anchor.map { $0.addingTimeInterval(60) })
        let req = Assistant.answerRequest(quotes: quotes, question: question, overall: overallSummary, recent: recent, hits: hits,
                                          webSearch: webSearch, ctx: makeContext(), model: d.mainModel, effort: d.answerEffort)
        do {
            let r = try await client.stream(req) { [weak self] ev in await self?.applyQAEvent(id, ev) }
            updateQA(id) {
                $0.answer = r.text
                if !r.sources.isEmpty { $0.webRefs = Self.dedupe(r.sources) }
                $0.status = r.text.isEmpty ? .failed : .done
                if r.text.isEmpty { $0.error = r.stopReason == "refusal" ? "模型拒绝回答" : "没有返回内容" }
            }
            noteAPI(nil)
        } catch {
            updateQA(id) { $0.status = .failed; $0.error = error.localizedDescription }
            noteAPI(error)
        }
        scheduleSave()
    }

    private func applyQAEvent(_ id: UUID, _ ev: LLMEvent) {
        switch ev {
        case .text(let t): updateQA(id) { $0.answer += t; $0.error = nil }
        case .searching(let q): updateQA(id) { $0.error = "正在搜索：\(q)" }
        case .sources(let refs): updateQA(id) { $0.webRefs = Self.dedupe($0.webRefs + refs) }
        }
    }

    func retryQA(_ id: UUID) {
        guard let q = qas.first(where: { $0.id == id }), let client = makeClient() else { return }
        updateQA(id) { $0.status = .running; $0.error = nil; $0.answer = "" }
        Task { await runQA(id: id, quotes: q.quotes, question: q.question, segs: [], anchor: q.createdAt, webSearch: q.webSearch, client: client) }
    }

    static func dedupe(_ refs: [WebRef]) -> [WebRef] {
        var seen = Set<String>()
        return refs.filter { seen.insert($0.url).inserted }
    }

    // MARK: 提问

    @discardableResult
    func generateQuestions(_ kind: QuestionSet.Kind) -> UUID? {
        guard let client = makeClient() else { return nil }
        let d = settings.data
        let set = QuestionSet(createdAt: Date(), kind: kind)
        questionSets.insert(set, at: 0)
        sideTab = .questions
        let id = set.id
        let req: LLMRequest
        switch kind {
        case .quick:
            req = Assistant.quickQuestionRequest(overall: overallSummary, recent: recentLines(maxChars: 3000), ctx: makeContext(), model: d.mainModel)
        case .full:
            let previous = questionSets.filter { $0.kind == .full && $0.status == .done }.prefix(2).flatMap { s in
                s.content.split(separator: "\n").filter { $0.contains("**中文**") }.map { String($0) }
            }
            req = Assistant.questionsRequest(overall: overallSummary, recent: recentLines(maxChars: 5000), previous: Array(previous),
                                             elapsed: Fmt.elapsed(max(elapsed, segments.last.map { $0.time.timeIntervalSince(startedAt) } ?? 0)),
                                             ctx: makeContext(), model: d.mainModel, effort: d.questionEffort)
        }
        Task {
            do {
                let r = try await client.stream(req) { [weak self] ev in
                    if case .text(let t) = ev { await self?.appendQuestion(id, t) }
                }
                updateQuestion(id) { $0.content = r.text; $0.status = r.text.isEmpty ? .failed : .done; if r.text.isEmpty { $0.error = "没有返回内容" } }
                noteAPI(nil)
            } catch {
                updateQuestion(id) { $0.status = .failed; $0.error = error.localizedDescription }
                noteAPI(error)
            }
            scheduleSave()
        }
        return id
    }

    private func updateQuestion(_ id: UUID, _ f: (inout QuestionSet) -> Void) {
        guard let i = questionSets.firstIndex(where: { $0.id == id }) else { return }
        f(&questionSets[i])
    }

    private func appendQuestion(_ id: UUID, _ t: String) { updateQuestion(id) { $0.content += t } }

    // MARK: 连接测试

    func testConnection() async -> String {
        guard let cfg = settings.llmConfig() else { return LLMError.noKey.errorDescription! }
        let client = LLMClient(config: cfg)
        let t0 = Date()
        let req = LLMRequest(model: settings.data.fastModel, system: "你是测试助手。", messages: [ChatMessage(role: "user", content: "回复“连接正常”四个字。")], maxTokens: 50, effort: .low)
        do {
            let r = try await client.complete(req, timeout: 30)
            noteAPI(nil)
            return "✅ \(r.model) \(String(format: "%.1f", Date().timeIntervalSince(t0)))s：\(r.text.prefix(30))"
        } catch {
            noteAPI(error)
            return "❌ \(error.localizedDescription)"
        }
    }
}
