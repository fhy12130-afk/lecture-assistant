import Foundation

/// 各项 AI 功能的提示词和调用。
enum Assistant {
    struct Context: Sendable {
        var title: String
        var speaker: String
        var myProfile: String
        var speakerProfile: String
        var pinnedNotes: [(path: String, text: String)]
        var glossary: [String]
        var domain: String
        var questionFocus: String

        static func orNone(_ s: String) -> String {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? "（没填写）" : t
        }

        var domainLine: String { domain.isEmpty ? "" : "领域：\(domain)。" }

        /// 稳定的大段上下文，放进 system 并打缓存断点
        var personalBlock: String {
            var s = "## 我的背景\n\(Self.orNone(myProfile))\n\n## 主讲人\n\(Self.orNone(speakerProfile))\n"
            if !pinnedNotes.isEmpty {
                s += "\n## 我的相关笔记（来自本地 Obsidian）\n"
                for n in pinnedNotes { s += "\n### \(n.path)\n\(n.text)\n" }
            }
            return s
        }
    }

    // MARK: 翻译 / 校正

    struct SecondaryItem: Sendable {
        var id: Int
        var text: String               // 系统识别
        var alts: [String: String] = [:]   // 本地引擎名 → 结果
    }

    static func secondary(_ items: [SecondaryItem], language: LectureLanguage, previous: [String], topic: String = "",
                          ctx: Context, client: LLMClient, model: String) async throws -> [Int: String] {
        let glossary = ctx.glossary.joined(separator: "、")
        let multi = items.contains { !$0.alts.isEmpty }
        let input = items.map { it -> [String: Any] in
            var o: [String: Any] = ["id": it.id]
            if it.alts.isEmpty {
                o["text"] = it.text
            } else {
                o["A_系统识别"] = it.text
                for (k, v) in it.alts.sorted(by: { $0.key < $1.key }) where !v.isEmpty { o["B_\(k)"] = v }
            }
            return o
        }
        let fusion = multi ? """

        有的段落给了多套语音识别结果（A_系统识别、B_sensevoice、B_paraformer 等），它们识别的是同一段话，各有错字和漏字。
        先综合它们还原说话人最可能的原话：几份结果读音相近而用字不同时，选符合上下文和领域的；某一份漏了或多了内容时，以说得通的为准；不能加入任何一份结果里都没有依据的内容。拿不准时优先相信 paraformer，其次 sensevoice。
        """ : ""
        let system: String
        let key: String
        if language == .english {
            key = "zh"
            system = """
            你是学术讲座的同声传译。讲座：\(ctx.title)，主讲人：\(ctx.speaker)。\(ctx.domainLine)
            参考术语：\(glossary.isEmpty ? "（无）" : glossary)
            规则：
            - 把每段英文语音转写翻成准确、自然的简体中文。
            - 转写是机器识别的，可能有同音词错误或断句错误（例如把 "finite element" 识别成 "fine eye development"），按上下文和术语推断原意再翻译。
            - 重要术语第一次出现时在中文后括注英文，例如“神经算子（neural operator）”。
            - 不解释、不总结、不补充原文没有的内容。
            \(fusion)
            只输出 JSON 数组，格式：[{"id": 1, "zh": "译文"}]
            """
        } else {
            key = "fixed"
            system = """
            你是学术讲座的速记校对。讲座：\(ctx.title)，主讲人：\(ctx.speaker)。\(ctx.domainLine)
            参考术语：\(glossary.isEmpty ? "（无）" : glossary)
            语音识别把中文讲座转成了文字，常见错误：同音错字、术语识别错（如“有限源”应为“有限元”、“神经算字”应为“神经算子”）、英文术语被写成中文音译、漏标点。
            规则：
            - 只改识别错误：改动后的字词必须和原文读音相同或相近（例如 财产→残差、工矿→工况、多不→多步、出网格→粗网格）。读音不相近的词一律不改，哪怕你觉得说话人可能想说别的；参考术语只用来判断同音词，不能把读音不同的词换成术语（例如“安全的”可以改成读音相近的“安全壳”，但绝不能改成“剪力墙”）。
            - 补上标点、断句；不改说话人的意思，不润色，不增删内容。
            - 被识别成中文音译的英文术语改回英文原形（PINN、DeepONet、Fourier neural operator 等）。
            - 拿不准就保持原样。
            \(fusion)
            只输出 JSON 数组，格式：[{"id": 1, "fixed": "校正后的文本"}]
            """
        }

        let inputJSON = String(decoding: try JSONSerialization.data(withJSONObject: input, options: [.withoutEscapingSlashes]), as: UTF8.self)
        var user = ""
        if !topic.isEmpty { user += "这场讲座目前讲到的内容（帮助判断术语）：\n\(topic)\n\n" }
        if !previous.isEmpty {
            user += "前文（只供理解上下文，不要处理）：\n" + previous.joined(separator: "\n") + "\n\n"
        }
        user += "待处理：\n\(inputJSON)"
        let req = LLMRequest(model: model, system: system, messages: [ChatMessage(role: "user", content: user)], maxTokens: 4096, effort: .low)
        let r = try await client.complete(req, timeout: 45)
        guard let data = LLMClient.extractJSON(r.text),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            // 只有一段时，模型偶尔直接输出译文
            if items.count == 1, !r.text.isEmpty, !r.text.contains("[{") {
                return [items[0].id: r.text.trimmingCharacters(in: .whitespacesAndNewlines)]
            }
            throw LLMError.badResponse(r.text)
        }
        var out: [Int: String] = [:]
        for o in arr {
            let id = (o["id"] as? Int) ?? Int(o["id"] as? String ?? "") ?? -1
            if let v = o[key] as? String, id >= 0 { out[id] = v }
        }
        return out
    }

    // MARK: 摘要

    struct SummaryOutput: Sendable {
        var points: String
        var overall: String
        var relevance: String
    }

    static func summaryRequest(newLines: [String], from: Date, to: Date, overall: String, ctx: Context, model: String) -> LLMRequest {
        let system = """
        你在帮我实时整理一场学术讲座的笔记。讲座：\(ctx.title)，主讲人：\(ctx.speaker)。\(ctx.domainLine)
        转写是语音识别得到的，可能有错字，请按上下文理解，不要照抄错字。中文输出。

        我的背景（只用来判断哪些内容和我相关）：
        \(Context.orNone(ctx.myProfile))
        """
        let user = """
        已有的累计摘要：
        \(overall.isEmpty ? "（还没有）" : overall)

        新的一段转写（\(Fmt.hm(from))–\(Fmt.hm(to))）：
        \(newLines.joined(separator: "\n"))

        请严格按下面三个标记输出：
        === 本段要点 ===
        3–6 条，每条一行，以“- ”开头。保留关键术语、方法名、数字和结论；听不清的地方注明“（转写不清）”。
        === 累计摘要 ===
        把新内容并进去之后的整场讲座摘要：按主题分条（可以用“**小标题**”），保留早先的要点，不超过 600 字。
        === 与我相关 ===
        0–2 条，这段内容和我的研究或发展方向（见我的背景）的关联，每条一行以“- ”开头；没有或我没填背景就写“无”。
        """
        return LLMRequest(model: model, system: system, messages: [ChatMessage(role: "user", content: user)], maxTokens: 3000, effort: .low)
    }

    static func parseSummary(_ text: String) -> SummaryOutput {
        func section(_ name: String) -> String {
            guard let r = text.range(of: "=== \(name) ===") else { return "" }
            let rest = text[r.upperBound...]
            let end = rest.range(of: "\n===")?.lowerBound ?? rest.endIndex
            return rest[..<end].trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var points = section("本段要点")
        let overall = section("累计摘要")
        var rel = section("与我相关")
        if points.isEmpty && overall.isEmpty { points = text.trimmingCharacters(in: .whitespacesAndNewlines) }
        if rel == "无" || rel == "- 无" { rel = "" }
        return SummaryOutput(points: points, overall: overall, relevance: rel)
    }

    // MARK: 拟题目

    static func titleRequest(excerpt: String, overall: String, currentTitle: String, currentSpeaker: String, ctx: Context, model: String) -> LLMRequest {
        var user = "下面是一场学术报告的语音转写（可能有错字）\(overall.isEmpty ? "" : "和摘要")。\n\n"
        if !overall.isEmpty { user += "摘要：\n\(overall)\n\n" }
        user += "转写：\n\(excerpt)\n\n"
        user += """
        请拟一个准确、像正式报告题目的标题（中文，不超过 30 字；讲者自己说了题目就用他说的），并判断汇报人姓名：只有转写里明确出现（比如主持人介绍、讲者自我介绍）才写，否则写空字符串。
        现在的标题：\(currentTitle.isEmpty ? "（无）" : currentTitle)；现在的汇报人：\(currentSpeaker.isEmpty ? "（无）" : currentSpeaker)。
        只输出 JSON：{"title": "...", "speaker": "..."}
        """
        return LLMRequest(model: model, system: "你帮我给讲座记录拟题目。\(ctx.domainLine)", messages: [ChatMessage(role: "user", content: user)],
                          maxTokens: 300, effort: .low)
    }

    // MARK: 检索关键词

    static func keywords(for text: String, client: LLMClient, model: String) async -> [String] {
        let req = LLMRequest(
            model: model,
            system: "你帮我从讲座片段里提取检索关键词，用来搜我本地的 Obsidian 笔记。",
            messages: [ChatMessage(role: "user", content: """
            从下面内容里提取 8–14 个检索关键词。中英文都要，同义词和缩写各占一个元素，只要具体的术语、方法名、人名、对象，不要“问题”“方法”这类泛词。
            只输出 JSON 字符串数组，每个元素只放一个词，例如：["神经算子", "neural operator", "FNO", "边界条件"]

            \(text.prefix(2000))
            """)],
            maxTokens: 400, effort: .low)
        if let r = try? await client.complete(req, timeout: 25),
           let data = LLMClient.extractJSON(r.text),
           let arr = try? JSONSerialization.jsonObject(with: data) as? [String], !arr.isEmpty {
            // 模型偶尔把同义词写在一个元素里（"神经算子 / neural operator"），拆开
            let seps = CharacterSet(charactersIn: "/、,，|;；")
            var out: [String] = []
            for k in arr {
                for part in k.components(separatedBy: seps) {
                    let t = part.trimmingCharacters(in: .whitespacesAndNewlines)
                    if t.count >= 2, !out.contains(t) { out.append(t) }
                }
            }
            return out
        }
        return VaultSearch.localKeywords(text)
    }

    // MARK: 解惑

    static func answerRequest(quotes: [String], question: String, overall: String, recent: [String],
                              hits: [VaultSearch.Hit], webSearch: Bool, ctx: Context, model: String, effort: Effort) -> LLMRequest {
        let system = """
        你是我的科研助教，陪我听一场学术讲座。我会选出听不懂的几句话问你。下面是我的背景、主讲人信息和我自己的笔记，回答时要结合我的实际情况。

        \(ctx.personalBlock)
        """
        var user = "讲座：\(ctx.title)（主讲：\(ctx.speaker)）\n\n"
        if !overall.isEmpty { user += "到目前为止的讲座摘要：\n\(overall)\n\n" }
        if !recent.isEmpty { user += "最近的讲话（上下文）：\n\(recent.joined(separator: "\n"))\n\n" }
        user += "我选中的、让我困惑的原话：\n" + quotes.map { "> " + $0.replacingOccurrences(of: "\n", with: "\n> ") }.joined(separator: "\n") + "\n\n"
        user += "我的问题：\(question.isEmpty ? "这几句我没太听懂，请解释他在说什么、为什么这么说。" : question)\n\n"
        if !hits.isEmpty {
            user += "在我本地笔记里检索到的相关内容（可能有用也可能无关）：\n"
            for (i, h) in hits.enumerated() {
                user += "[\(i + 1)] [[\(h.title)]]（\(h.path)）\n" + h.snippets.joined(separator: "\n") + "\n\n"
            }
        }
        user += """
        请按这个结构回答，用 Markdown，总共不超过 600 字：
        **他在说什么**：两三句话讲清楚这几句的意思。转写有识别错误时先推断原话，必要时注明“这里可能是 X 的误识别”。
        **关键概念**：解释涉及的概念或方法，用我能懂的方式讲，可以拿我熟悉的领域知识（见我的背景）来类比。
        **和我的关系**：和我的研究（见我的背景）的联系或差别；我的笔记里有相关内容就用 [[笔记名]] 引用，没有就不提笔记。
        **可以追问**：1–2 个就这一点可以问老师的问题，中英文各一句。
        """
        if webSearch {
            user += "\n可以联网搜索核实（比如他提到的论文、模型、数据集），用到的信息给出来源链接。"
        }
        return LLMRequest(model: model, system: system, messages: [ChatMessage(role: "user", content: user)],
                          maxTokens: 6000, effort: effort, webSearch: webSearch, cacheSystem: true)
    }

    // MARK: 提问

    static func questionsRequest(overall: String, recent: [String], previous: [String], elapsed: String,
                                 ctx: Context, model: String, effort: Effort) -> LLMRequest {
        let system = """
        你在帮我准备学术讲座问答环节的提问。主讲人可能点名让我提问，我希望问出有水平、和我的发展方向相关的问题，给老师留下好印象（我和他的关系、我的目标见我的背景）。下面是我的背景、主讲人信息和我的笔记。

        \(ctx.personalBlock)
        """
        var user = "讲座：\(ctx.title)（主讲：\(ctx.speaker)），已进行 \(elapsed)。\n\n"
        user += "讲座摘要：\n\(overall.isEmpty ? "（还没有摘要，讲座可能刚开始）" : overall)\n\n"
        if !recent.isEmpty { user += "最近的讲话：\n\(recent.joined(separator: "\n"))\n\n" }
        if !previous.isEmpty { user += "之前已经给过我的问题（不要重复）：\n\(previous.joined(separator: "\n"))\n\n" }
        user += """
        请给我 6 个问题，编号 Q1–Q6：
        - Q1–Q2：紧扣今天讲的内容做技术深挖（他具体讲到的方法、假设、实验设置）。
        - Q3–Q4：把他的方法和我的研究连起来\(ctx.questionFocus.isEmpty ? "" : "（可以从这些角度切入：\(ctx.questionFocus)）")，问他的看法或建议。
        - Q5：方法论、局限或未来方向。
        - Q6：适合会后私下问的得体问题：如果我的背景里写了想加入他的课题组，就问课题组方向或学生培养；否则问合作或学习建议。
        每个问题写四行：
        **中文**：口语化、具体，30–70 字，不要“您怎么看”这种空话
        **English**：对应英文
        **为什么好**：一句话
        **他可能怎么答**：一句话，帮我准备追问
        要求：体现我认真听了、也真做过相关工作；不吹捧，不暴露没听懂；讲座没提到的内容不要说成他讲过。
        注意事实和分寸：论文的作者角色按我笔记里写的说，他不是一作或通讯的论文不要说成“您的工作”；不要声称我有还没做出来的结果；不要当面挑他论文的毛病。
        现场通常只够问一个：最后用一句话告诉我现场优先问哪个、哪个留到会后私聊。
        最后给一段被点名时用的 20 秒自我介绍，中英文各一版。
        """
        return LLMRequest(model: model, system: system, messages: [ChatMessage(role: "user", content: user)],
                          maxTokens: 8000, effort: effort, cacheSystem: true)
    }

    static func quickQuestionRequest(overall: String, recent: [String], ctx: Context, model: String) -> LLMRequest {
        let system = """
        我正在听讲座，刚被主讲人点名提问，需要马上开口。下面是我的背景和主讲人信息。

        \(ctx.personalBlock)
        """
        var user = ""
        if !overall.isEmpty { user += "讲座摘要：\n\(overall)\n\n" }
        if !recent.isEmpty { user += "他最近在讲：\n\(recent.suffix(25).joined(separator: "\n"))\n\n" }
        user += """
        给我 1 个最好的问题，紧扣他最近讲的内容，并能自然带出我的研究。格式：
        **开场**：一句话自我介绍（学校、年级、做什么），10 秒内说完
        **问题**：中文，60 字以内，具体
        **English**：英文版
        不要别的解释。
        """
        return LLMRequest(model: model, system: system, messages: [ChatMessage(role: "user", content: user)],
                          maxTokens: 1500, effort: .low, cacheSystem: true)
    }
}
