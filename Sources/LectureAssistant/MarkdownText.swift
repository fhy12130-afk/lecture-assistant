import SwiftUI

/// 够用的 Markdown 显示：标题、列表、引用按行处理，行内粗体/斜体/代码/链接交给 AttributedString。
struct MarkdownText: View {
    let text: String
    var fontSize: Double = 14

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in
                row(b)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private enum Block {
        case heading(String, Int)
        case bullet(String, Int)
        case numbered(String, String)
        case quote(String)
        case para(String)
        case rule
        case gap
    }

    private var blocks: [Block] {
        var out: [Block] = []
        for raw in text.components(separatedBy: "\n") {
            let indent = raw.prefix { $0 == " " }.count / 2
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if case .gap? = out.last {} else if !out.isEmpty { out.append(.gap) }
                continue
            }
            if line == "---" || line == "***" { out.append(.rule); continue }
            if line.hasPrefix("#") {
                let level = line.prefix { $0 == "#" }.count
                out.append(.heading(String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces), level))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                out.append(.bullet(String(line.dropFirst(2)), indent))
            } else if line.hasPrefix(">") {
                out.append(.quote(String(line.dropFirst()).trimmingCharacters(in: .whitespaces)))
            } else if let r = line.range(of: #"^\d+[\.\)、]\s*"#, options: .regularExpression) {
                out.append(.numbered(String(line[r]).trimmingCharacters(in: .whitespaces), String(line[r.upperBound...])))
            } else {
                out.append(.para(line))
            }
        }
        if case .gap? = out.last { out.removeLast() }
        return out
    }

    @ViewBuilder
    private func row(_ b: Block) -> some View {
        switch b {
        case .heading(let t, let level):
            inline(t)
                .font(.system(size: fontSize + (level <= 2 ? 3 : 1), weight: .semibold))
                .padding(.top, 4)
        case .bullet(let t, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("•").foregroundStyle(.secondary)
                inline(t)
            }
            .font(.system(size: fontSize))
            .padding(.leading, CGFloat(indent) * 14)
        case .numbered(let n, let t):
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(n).foregroundStyle(.secondary).monospacedDigit()
                inline(t)
            }
            .font(.system(size: fontSize))
        case .quote(let t):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 1).fill(.tertiary).frame(width: 3)
                inline(t).foregroundStyle(.secondary)
            }
            .font(.system(size: fontSize - 0.5))
        case .para(let t):
            inline(t).font(.system(size: fontSize))
        case .rule:
            Divider()
        case .gap:
            Spacer().frame(height: 2)
        }
    }

    private func inline(_ s: String) -> some View {
        inlineText(s).fixedSize(horizontal: false, vertical: true)
    }

    private func inlineText(_ s: String) -> Text {
        if let a = try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(a)
        }
        return Text(s)
    }
}
