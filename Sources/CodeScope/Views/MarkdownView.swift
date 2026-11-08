import SwiftUI

/// A small block-level Markdown renderer (headings, lists, code fences, quotes, tables, rules)
/// that uses `AttributedString(markdown:)` for inline styling. Good enough for model output.
enum MarkdownBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullets([String])
    case numbered([String])
    case code(language: String, code: String)
    case quote(String)
    case table(rows: [[String]])
    case rule
}

enum MarkdownParser {
    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var numbered: [String] = []
        var quote: [String] = []
        var table: [[String]] = []
        var codeLines: [String] = []
        var codeLanguage = ""
        var inCode = false

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: " ")))
                paragraph = []
            }
        }
        func flushLists() {
            if !bullets.isEmpty { blocks.append(.bullets(bullets)); bullets = [] }
            if !numbered.isEmpty { blocks.append(.numbered(numbered)); numbered = [] }
        }
        func flushQuote() {
            if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: " "))); quote = [] }
        }
        func flushTable() {
            if !table.isEmpty { blocks.append(.table(rows: table)); table = [] }
        }
        func flushAll() {
            flushParagraph()
            flushLists()
            flushQuote()
            flushTable()
        }

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if inCode {
                if line.hasPrefix("```") {
                    blocks.append(.code(language: codeLanguage, code: codeLines.joined(separator: "\n")))
                    codeLines = []
                    inCode = false
                } else {
                    codeLines.append(rawLine)
                }
                continue
            }
            if line.hasPrefix("```") {
                flushAll()
                inCode = true
                codeLanguage = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if line.isEmpty {
                flushAll()
                continue
            }
            if line.hasPrefix("|") {
                flushParagraph(); flushLists(); flushQuote()
                let cells = line.split(separator: "|", omittingEmptySubsequences: false)
                    .dropFirst()
                    .dropLast()
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                let isSeparator = cells.allSatisfy { cell in
                    !cell.isEmpty && cell.allSatisfy { $0 == "-" || $0 == ":" || $0 == " " }
                }
                if !isSeparator { table.append(cells) }
                continue
            } else {
                flushTable()
            }
            if line == "---" || line == "***" || line == "___" {
                flushAll()
                blocks.append(.rule)
                continue
            }
            if line.hasPrefix("#") {
                let level = line.prefix { $0 == "#" }.count
                if level <= 6, line.count > level, line[line.index(line.startIndex, offsetBy: level)] == " " {
                    flushAll()
                    let heading = String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                    blocks.append(.heading(level: level, text: heading))
                    continue
                }
            }
            if line.hasPrefix("> ") || line == ">" {
                flushParagraph(); flushLists(); flushTable()
                quote.append(String(line.dropFirst(1)).trimmingCharacters(in: .whitespaces))
                continue
            } else {
                flushQuote()
            }
            if let bullet = bulletText(line) {
                flushParagraph(); flushQuote()
                if !numbered.isEmpty && rawLine.hasPrefix("  ") {
                    numbered[numbered.count - 1] += "\n• " + bullet
                } else {
                    bullets.append(bullet)
                }
                continue
            }
            if let item = numberedText(line) {
                flushParagraph(); flushQuote()
                if !bullets.isEmpty { blocks.append(.bullets(bullets)); bullets = [] }
                numbered.append(item)
                continue
            }
            // Continuation of a list item (indented text).
            if rawLine.hasPrefix("  ") || rawLine.hasPrefix("\t") {
                if !bullets.isEmpty {
                    bullets[bullets.count - 1] += " " + line
                    continue
                }
                if !numbered.isEmpty {
                    numbered[numbered.count - 1] += " " + line
                    continue
                }
            }
            flushLists()
            paragraph.append(line)
        }
        if inCode {
            blocks.append(.code(language: codeLanguage, code: codeLines.joined(separator: "\n")))
        }
        flushAll()
        return blocks
    }

    private static func bulletText(_ line: String) -> String? {
        for prefix in ["- ", "* ", "+ ", "• "] where line.hasPrefix(prefix) {
            return String(line.dropFirst(prefix.count))
        }
        return nil
    }

    private static func numberedText(_ line: String) -> String? {
        var digits = 0
        for character in line {
            if character.isNumber { digits += 1 } else { break }
        }
        guard digits > 0, digits <= 3 else { return nil }
        let rest = line.dropFirst(digits)
        if rest.hasPrefix(". ") || rest.hasPrefix(") ") {
            return String(rest.dropFirst(2))
        }
        return nil
    }
}

struct MarkdownView: View {
    let text: String
    var baseFont: Font = .body

    var body: some View {
        let blocks = MarkdownParser.parse(text)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text))
                .font(headingFont(level))
                .fontWeight(.semibold)
                .padding(.top, level <= 2 ? 8 : 4)
        case .paragraph(let text):
            Text(inline(text))
                .font(baseFont)
                .lineSpacing(2)
        case .bullets(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").font(baseFont)
                        Text(inline(item)).font(baseFont)
                    }
                }
            }
            .padding(.leading, 6)
        case .numbered(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(offset + 1).").font(baseFont).monospacedDigit().frame(minWidth: 20, alignment: .trailing)
                        Text(inline(item)).font(baseFont)
                    }
                }
            }
            .padding(.leading, 2)
        case .code(_, let code):
            ScrollView(.horizontal, showsIndicators: true) {
                Text(code)
                    .font(.system(.callout, design: .monospaced))
                    .padding(10)
            }
            .background(Color(nsColor: .textBackgroundColor).opacity(0.7))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.25)))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        case .quote(let text):
            HStack(alignment: .top, spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(Color.accentColor.opacity(0.6)).frame(width: 3)
                Text(inline(text)).font(baseFont).foregroundStyle(.secondary)
            }
        case .table(let rows):
            tableView(rows)
        case .rule:
            Divider()
        }
    }

    private func tableView(_ rows: [[String]]) -> some View {
        let columnCount = rows.map { $0.count }.max() ?? 0
        return ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    GridRow {
                        ForEach(0..<columnCount, id: \.self) { column in
                            Text(inline(column < row.count ? row[column] : ""))
                                .font(rowIndex == 0 ? baseFont.weight(.semibold) : baseFont)
                        }
                    }
                    if rowIndex == 0 { Divider() }
                }
            }
            .padding(8)
        }
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title
        case 2: return .title2
        case 3: return .title3
        default: return .headline
        }
    }

    private func inline(_ text: String) -> AttributedString {
        if let attributed = try? AttributedString(markdown: text, options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return attributed
        }
        return AttributedString(text)
    }
}
