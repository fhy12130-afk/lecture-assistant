import Foundation

struct LLMConfig: Sendable {
    var baseURL: String
    var apiKey: String
    var format: APIFormat
}

struct ChatMessage: Sendable, Codable {
    var role: String
    var content: String
}

struct LLMRequest: Sendable {
    var model: String
    var system: String
    var messages: [ChatMessage]
    var maxTokens: Int = 4096
    var effort: Effort? = .low
    var webSearch = false
    /// 系统提示里稳定的大段上下文，打缓存断点（中转不支持也无害）
    var cacheSystem = false
}

enum LLMEvent: Sendable {
    case text(String)
    case searching(String)
    case sources([WebRef])
}

struct LLMResult: Sendable {
    var text: String
    var sources: [WebRef]
    var stopReason: String?
    var model: String
}

enum LLMError: LocalizedError {
    case noKey
    case http(Int, String)
    case badResponse(String)
    case refusal

    var errorDescription: String? {
        switch self {
        case .noKey: return "没有读到 API key：去设置里填 key 或 key 文件路径"
        case .http(let code, let body): return "HTTP \(code)：\(body.prefix(300))"
        case .badResponse(let s): return "返回内容解析失败：\(s.prefix(200))"
        case .refusal: return "模型拒绝回答（refusal）"
        }
    }

    var retryable: Bool {
        switch self {
        case .http(let code, _): return code == 429 || code >= 500
        case .badResponse: return true
        default: return false
        }
    }
}

/// 直接用 HTTP 调 Anthropic Messages（或 OpenAI 兼容）接口；Swift 没有官方 SDK。
struct LLMClient: Sendable {
    let config: LLMConfig
    /// 主模型 refusal 时改用的模型
    var refusalFallbackModel = "claude-sonnet-5-5"

    private var base: String {
        var b = config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while b.hasSuffix("/") { b.removeLast() }
        if b.hasSuffix("/v1") { b.removeLast(3) }
        return b
    }

    // MARK: 非流式

    func complete(_ req: LLMRequest, timeout: TimeInterval = 60) async throws -> LLMResult {
        var lastError: Error = LLMError.badResponse("unknown")
        for attempt in 0..<2 {
            do {
                let r = try await completeOnce(req, timeout: timeout)
                if r.stopReason == "refusal", req.model != refusalFallbackModel {
                    var fb = req
                    fb.model = refusalFallbackModel
                    return try await completeOnce(fb, timeout: timeout)
                }
                return r
            } catch let e as LLMError where e.retryable && attempt == 0 {
                lastError = e
                try await Task.sleep(nanoseconds: 1_500_000_000)
            } catch let e as URLError where attempt == 0 && e.code != .cancelled {
                lastError = e
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        throw lastError
    }

    private func completeOnce(_ req: LLMRequest, timeout: TimeInterval) async throws -> LLMResult {
        let urlReq = try buildRequest(req, stream: false, timeout: timeout)
        let (data, resp) = try await URLSession.shared.data(for: urlReq)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else {
            throw LLMError.http(code, Self.errorMessage(from: data))
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LLMError.badResponse(String(decoding: data, as: UTF8.self))
        }
        switch config.format {
        case .anthropic:
            let blocks = obj["content"] as? [[String: Any]] ?? []
            var text = ""
            var sources: [WebRef] = []
            for b in blocks {
                let type = b["type"] as? String
                if type == "text" { text += b["text"] as? String ?? "" }
                if type == "web_search_tool_result" { sources += Self.webRefs(from: b["content"]) }
            }
            return LLMResult(text: text, sources: sources, stopReason: obj["stop_reason"] as? String, model: obj["model"] as? String ?? req.model)
        case .openai:
            let choices = obj["choices"] as? [[String: Any]] ?? []
            let msg = choices.first?["message"] as? [String: Any]
            let text = msg?["content"] as? String ?? ""
            return LLMResult(text: text, sources: [], stopReason: choices.first?["finish_reason"] as? String, model: obj["model"] as? String ?? req.model)
        }
    }

    // MARK: 流式

    func stream(_ req: LLMRequest, onEvent: @escaping @Sendable (LLMEvent) async -> Void) async throws -> LLMResult {
        do {
            let r = try await streamOnce(req, onEvent: onEvent)
            if r.stopReason == "refusal", req.model != refusalFallbackModel, r.text.isEmpty {
                var fb = req
                fb.model = refusalFallbackModel
                return try await streamOnce(fb, onEvent: onEvent)
            }
            return r
        } catch let e as LLMError where e.retryable {
            try await Task.sleep(nanoseconds: 1_500_000_000)
            return try await streamOnce(req, onEvent: onEvent)
        }
    }

    private func streamOnce(_ req: LLMRequest, onEvent: @escaping @Sendable (LLMEvent) async -> Void) async throws -> LLMResult {
        let urlReq = try buildRequest(req, stream: true, timeout: req.webSearch ? 150 : 90)
        let (bytes, resp) = try await URLSession.shared.bytes(for: urlReq)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if code != 200 {
            var body = Data()
            for try await b in bytes { body.append(b); if body.count > 4000 { break } }
            throw LLMError.http(code, Self.errorMessage(from: body))
        }
        var text = ""
        var sources: [WebRef] = []
        var stop: String?
        var model = req.model
        var toolInputs: [Int: String] = [:]

        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else { continue }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { break }
            guard let data = payload.data(using: .utf8),
                  let ev = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

            if config.format == .openai {
                if let choices = ev["choices"] as? [[String: Any]], let first = choices.first {
                    if let delta = first["delta"] as? [String: Any], let t = delta["content"] as? String, !t.isEmpty {
                        text += t
                        await onEvent(.text(t))
                    }
                    if let fr = first["finish_reason"] as? String { stop = fr }
                }
                continue
            }

            switch ev["type"] as? String {
            case "message_start":
                if let m = (ev["message"] as? [String: Any])?["model"] as? String { model = m }
            case "content_block_start":
                let idx = ev["index"] as? Int ?? -1
                let block = ev["content_block"] as? [String: Any] ?? [:]
                switch block["type"] as? String {
                case "server_tool_use":
                    toolInputs[idx] = ""
                case "web_search_tool_result":
                    let refs = Self.webRefs(from: block["content"])
                    if !refs.isEmpty {
                        sources += refs
                        await onEvent(.sources(refs))
                    }
                default: break
                }
            case "content_block_delta":
                let idx = ev["index"] as? Int ?? -1
                let delta = ev["delta"] as? [String: Any] ?? [:]
                switch delta["type"] as? String {
                case "text_delta":
                    if let t = delta["text"] as? String, !t.isEmpty {
                        text += t
                        await onEvent(.text(t))
                    }
                case "input_json_delta":
                    if toolInputs[idx] != nil { toolInputs[idx]! += delta["partial_json"] as? String ?? "" }
                default: break
                }
            case "content_block_stop":
                let idx = ev["index"] as? Int ?? -1
                if let raw = toolInputs.removeValue(forKey: idx),
                   let d = raw.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                   let q = obj["query"] as? String {
                    await onEvent(.searching(q))
                }
            case "message_delta":
                if let s = (ev["delta"] as? [String: Any])?["stop_reason"] as? String { stop = s }
            case "error":
                let err = ev["error"] as? [String: Any]
                throw LLMError.http(-1, err?["message"] as? String ?? payload)
            default: break
            }
        }
        return LLMResult(text: text, sources: sources, stopReason: stop, model: model)
    }

    // MARK: 请求构造

    private func buildRequest(_ req: LLMRequest, stream: Bool, timeout: TimeInterval) throws -> URLRequest {
        let path = config.format == .anthropic ? "/v1/messages" : "/v1/chat/completions"
        guard let url = URL(string: base + path) else { throw LLMError.badResponse("中转地址不对：\(config.baseURL)") }
        var r = URLRequest(url: url, timeoutInterval: timeout)
        r.httpMethod = "POST"
        r.setValue("application/json", forHTTPHeaderField: "content-type")
        var body: [String: Any] = ["model": req.model, "max_tokens": req.maxTokens]
        if stream { body["stream"] = true }

        switch config.format {
        case .anthropic:
            r.setValue(config.apiKey, forHTTPHeaderField: "x-api-key")
            r.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            var sys: [String: Any] = ["type": "text", "text": req.system]
            if req.cacheSystem { sys["cache_control"] = ["type": "ephemeral"] }
            body["system"] = [sys]
            body["messages"] = req.messages.map { ["role": $0.role, "content": $0.content] }
            if let e = req.effort { body["output_config"] = ["effort": e.rawValue] }
            if req.webSearch {
                body["tools"] = [["type": "web_search_20260209", "name": "web_search", "max_uses": 3]]
            }
        case .openai:
            r.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization")
            var msgs: [[String: Any]] = [["role": "system", "content": req.system]]
            msgs += req.messages.map { ["role": $0.role, "content": $0.content] }
            body["messages"] = msgs
        }
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        return r
    }

    private static func errorMessage(from data: Data) -> String {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let e = obj["error"] as? [String: Any], let m = e["message"] as? String { return m }
            if let m = obj["message"] as? String { return m }
        }
        return String(decoding: data.prefix(400), as: UTF8.self)
    }

    private static func webRefs(from content: Any?) -> [WebRef] {
        guard let list = content as? [[String: Any]] else { return [] }
        return list.compactMap { item in
            guard let url = item["url"] as? String else { return nil }
            return WebRef(url: url, title: item["title"] as? String ?? url)
        }
    }

    // MARK: 工具

    /// 从模型输出里抠出 JSON（容忍 ```json 包裹和前后废话）
    static func extractJSON(_ text: String, open: Character = "[", close: Character = "]") -> Data? {
        guard let s = text.firstIndex(of: open), let e = text.lastIndex(of: close), s < e else { return nil }
        return String(text[s...e]).data(using: .utf8)
    }
}
