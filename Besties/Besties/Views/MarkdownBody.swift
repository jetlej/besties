import SwiftUI

/// Renders assistant markdown with real block layout — tables, lists, and
/// headings — since Text's inline parsing leaves them as raw symbols. Shared by
/// the chat transcript and the report cards.
struct MarkdownBody: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(Self.segments(Self.blocks(text)).enumerated()), id: \.offset) { _, segment in
                switch segment {
                case .text(let content):
                    Text(content)
                case .table(let header, let rows):
                    table(header: header, rows: rows)
                }
            }
        }
    }

    private func table(header: [AttributedString], rows: [[AttributedString]]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        Text(cell).font(.callout.weight(.semibold))
                    }
                }
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            Text(cell)
                        }
                    }
                    if index < rows.count - 1 { Divider() }
                }
            }
            .padding(10)
        }
        .background(Color.white.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - Layout

    /// What actually renders. Paragraphs, headings and lists between tables
    /// fold into one Text, because a selection can't cross from one Text to
    /// the next — separate views would let you highlight only a paragraph at
    /// a time.
    private enum Segment {
        case text(AttributedString)
        case table(header: [AttributedString], rows: [[AttributedString]])
    }

    private static func segments(_ blocks: [Block]) -> [Segment] {
        var segments: [Segment] = []
        var run: AttributedString?

        func append(_ piece: AttributedString) {
            if run == nil {
                run = piece
            } else {
                run!.append(paragraphBreak)
                run!.append(piece)
            }
        }
        func flush() {
            if let run { segments.append(.text(run)) }
            run = nil
        }

        for block in blocks {
            switch block {
            case .paragraph(let content):
                append(content)
            case .heading(var content, let level):
                content.font = level <= 1 ? .title3.bold() : level == 2 ? .headline : .subheadline.bold()
                append(content)
            case .items(let items):
                var list = AttributedString()
                for (index, item) in items.enumerated() {
                    if index > 0 { list.append(AttributedString("\n")) }
                    var marker = AttributedString(item.marker + "\u{2002}")
                    marker.foregroundColor = Color.ink.opacity(0.5)
                    list.append(marker)
                    list.append(item.content)
                }
                append(list)
            case .table(let header, let rows):
                flush()
                segments.append(.table(header: header, rows: rows))
            }
        }
        flush()
        return segments
    }

    /// A line break plus a short empty line: a paragraph gap about the size
    /// of the old 8pt stack spacing, rather than a full blank line.
    private static let paragraphBreak: AttributedString = {
        var gap = AttributedString("\n\n")
        gap.font = .system(size: 5)
        return gap
    }()

    // MARK: - Parsing

    private enum Block {
        case paragraph(AttributedString)
        case heading(AttributedString, level: Int)
        case items([(marker: String, content: AttributedString)])
        case table(header: [AttributedString], rows: [[AttributedString]])
    }

    /// Inline markdown (bold/italic/code) with line breaks preserved.
    private static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }

    private static func blocks(_ text: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var items: [(String, String)] = []
        var table: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(inline(paragraph.joined(separator: "\n"))))
            paragraph = []
        }
        func flushItems() {
            guard !items.isEmpty else { return }
            blocks.append(.items(items.map { (marker: $0.0, content: inline($0.1)) }))
            items = []
        }
        func flushTable() {
            guard !table.isEmpty else { return }
            defer { table = [] }
            let rows = table.map { line in
                line.trimmingCharacters(in: CharacterSet(charactersIn: "| "))
                    .components(separatedBy: "|")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
            }
            // A real table has a |---|---| separator as its second line.
            let hasSeparator = rows.count >= 2 && rows[1].allSatisfy { cell in
                !cell.isEmpty && cell.allSatisfy { "-: ".contains($0) }
            }
            guard hasSeparator else {
                blocks.append(.paragraph(inline(table.joined(separator: "\n"))))
                return
            }
            let width = rows[0].count
            let bodyRows = rows.dropFirst(2).map { row -> [AttributedString] in
                var cells = row.map(inline)
                while cells.count < width { cells.append(AttributedString("")) }
                return Array(cells.prefix(width))
            }
            blocks.append(.table(header: rows[0].map(inline), rows: bodyRows))
        }

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("|") {
                flushParagraph(); flushItems()
                table.append(line)
                continue
            }
            flushTable()
            if line.isEmpty {
                flushParagraph(); flushItems()
                continue
            }
            if line.hasPrefix("#") {
                flushParagraph(); flushItems()
                let level = line.prefix(while: { $0 == "#" }).count
                let content = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(inline(content), level: level))
                continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") {
                flushParagraph()
                items.append(("•", String(line.dropFirst(2))))
                continue
            }
            if let marker = line.range(of: #"^\d{1,3}[.)] "#, options: .regularExpression) {
                flushParagraph()
                items.append((String(line[..<marker.upperBound]).trimmingCharacters(in: .whitespaces),
                              String(line[marker.upperBound...])))
                continue
            }
            flushItems()
            paragraph.append(rawLine)
        }
        flushTable(); flushItems(); flushParagraph()
        return blocks
    }
}
