import Foundation

/// A `Detail`'s markdown as blocks; inline spans stay source for `AttributedString` in the view.
enum ExtensionMarkdown {
    enum Block: Equatable, Sendable {
        case heading(level: Int, text: String)
        case paragraph(String)
        /// A `<sub>`/`<sup>` line on its own: the footer an extension closes a Detail with.
        case caption(String)
        case bulletList([Item])
        case numberedList(start: Int, items: [Item])
        case code(language: String?, text: String)
        case quote([Block])
        case table(Table)
        case rule
        case image(URL)

        struct Item: Equatable, Sendable {
            let blocks: [Block]
            /// Set only by a task-list checkbox, so an ordinary bullet keeps its marker.
            let checked: Bool?
        }

        struct Table: Equatable, Sendable {
            enum Alignment: Equatable, Sendable {
                case leading
                case center
                case trailing
            }

            let header: [String]
            let alignments: [Alignment]
            let rows: [[String]]
        }
    }

    /// Tolerant by construction: an unclosed fence, list, quote or table ends at EOF.
    static func parse(_ markdown: String) -> [Block] {
        let text = markdown.replacingOccurrences(of: "\r\n", with: "\n")
        var reader = Reader(lines: text.components(separatedBy: "\n"))
        return reader.blocks()
    }

    private struct Reader {
        let lines: [String]
        var index = 0

        mutating func blocks() -> [Block] {
            var blocks: [Block] = []
            while let line = peek() {
                if Line.isBlank(line) {
                    index += 1
                } else if let fence = Line.fence(line) {
                    blocks.append(code(fence))
                } else if Line.isRule(line) {
                    index += 1
                    blocks.append(.rule)
                } else if let heading = Line.heading(line) {
                    index += 1
                    blocks.append(.heading(level: heading.level, text: heading.text))
                } else if Line.isQuote(line) {
                    blocks.append(quote())
                } else if let table = table() {
                    blocks.append(table)
                } else if let marker = Line.listMarker(line) {
                    blocks.append(list(from: marker))
                } else if let url = Line.imageURL(line) {
                    index += 1
                    blocks.append(.image(url))
                } else if let caption = Line.caption(line) {
                    index += 1
                    blocks.append(.caption(caption))
                } else if let paragraph = paragraph() {
                    blocks.append(paragraph)
                }
            }
            return blocks
        }

        private func peek(_ offset: Int = 0) -> String? {
            let target = index + offset
            return lines.indices.contains(target) ? lines[target] : nil
        }

        private mutating func code(_ fence: Line.Fence) -> Block {
            index += 1
            var body: [String] = []
            while let line = peek(), !Line.closes(line, fence) {
                body.append(Line.dedent(line, by: fence.indent))
                index += 1
            }
            if peek() != nil { index += 1 }
            while let last = body.last, Line.isBlank(last) { body.removeLast() }
            return .code(language: fence.language, text: body.joined(separator: "\n"))
        }

        private mutating func quote() -> Block {
            var inner: [String] = []
            while let line = peek() {
                if Line.isQuote(line) {
                    inner.append(Line.strippingQuoteMarker(line))
                } else if Line.isBlank(line) || Line.startsBlock(line) {
                    break
                } else {
                    inner.append(line)
                }
                index += 1
            }
            var reader = Reader(lines: inner)
            return .quote(reader.blocks())
        }

        private mutating func table() -> Block? {
            guard let header = peek(), header.contains("|"), let delimiter = peek(1),
                let alignments = Line.tableAlignments(delimiter)
            else { return nil }
            let titles = Line.tableCells(header)
            guard titles.count == alignments.count else { return nil }
            index += 2
            var rows: [[String]] = []
            while let line = peek(), !Line.isBlank(line), line.contains("|") {
                rows.append(Line.resizing(Line.tableCells(line), to: titles.count))
                index += 1
            }
            return .table(.init(header: titles, alignments: alignments, rows: rows))
        }

        private mutating func list(from first: Line.Marker) -> Block {
            var items: [Block.Item] = []
            while let line = peek(), let marker = Line.listMarker(line),
                marker.isOrdered == first.isOrdered, marker.indent <= first.indent + 1
            {
                index += 1
                items.append(item(startingWith: line, marker: marker))
            }
            return first.isOrdered ? .numberedList(start: first.number, items: items) : .bulletList(items)
        }

        private mutating func item(startingWith line: String, marker: Line.Marker) -> Block.Item {
            var body = [String(line.dropFirst(min(marker.contentIndent, line.count)))]
            while let line = peek() {
                if Line.isBlank(line) {
                    guard let next = peek(1), !Line.isBlank(next), Line.indent(next) >= marker.contentIndent
                    else { break }
                } else if Line.indent(line) < marker.contentIndent, Line.startsBlock(line) {
                    break
                }
                body.append(Line.dedent(line, by: marker.contentIndent))
                index += 1
            }
            var reader = Reader(lines: body)
            var blocks = reader.blocks()
            guard case .paragraph(let text) = blocks.first, let task = Line.taskBox(text) else {
                return .init(blocks: blocks, checked: nil)
            }
            blocks[0] = .paragraph(task.rest)
            return .init(blocks: blocks, checked: task.checked)
        }

        private mutating func paragraph() -> Block? {
            var body: [String] = []
            while let line = peek(), !Line.isBlank(line) {
                if !body.isEmpty, Line.startsBlock(line) || startsTable() { break }
                body.append(line.trimmingCharacters(in: .whitespaces))
                index += 1
            }
            return body.isEmpty ? nil : .paragraph(body.joined(separator: " "))
        }

        private func startsTable() -> Bool {
            guard let header = peek(), header.contains("|"), let delimiter = peek(1) else {
                return false
            }
            return Line.tableAlignments(delimiter) != nil
        }
    }
}

/// Pure line classification: everything the reader must recognise before it can consume a block.
private enum Line {
    struct Fence {
        let character: Character
        let length: Int
        let indent: Int
        let language: String?
    }

    struct Marker {
        let indent: Int
        /// Column the item's own content starts at, and the amount its later lines are dedented by.
        let contentIndent: Int
        let isOrdered: Bool
        let number: Int
    }

    static func isBlank(_ line: String) -> Bool { line.allSatisfy(\.isWhitespace) }

    /// A line that is nothing but `<sub>…</sub>` or `<sup>…</sup>`, which is how an extension
    /// signs a Detail with its model and latency; the tags are markup, not words.
    static func caption(_ line: String) -> String? {
        let text = line.trimmingCharacters(in: .whitespaces)
        let lowered = text.lowercased()
        for (open, close) in [("<sub>", "</sub>"), ("<sup>", "</sup>")]
        where lowered.hasPrefix(open) && lowered.hasSuffix(close) && text.count > open.count + close.count {
            return String(text.dropFirst(open.count).dropLast(close.count))
                .trimmingCharacters(in: .whitespaces)
        }
        return nil
    }

    /// Leading whitespace measured in characters, so it also indexes back into the line.
    static func indent(_ line: String) -> Int { line.prefix(while: { $0 == " " || $0 == "\t" }).count }

    static func fence(_ line: String) -> Fence? {
        let indent = indent(line)
        let body = line.dropFirst(indent)
        guard let character = body.first, character == "`" || character == "~" else { return nil }
        let length = body.prefix(while: { $0 == character }).count
        guard length >= 3 else { return nil }
        let info = body.dropFirst(length).trimmingCharacters(in: .whitespaces)
        guard character == "~" || !info.contains("`") else { return nil }
        let language = info.split(separator: " ").first.map(String.init)
        return Fence(character: character, length: length, indent: indent, language: language)
    }

    static func closes(_ line: String, _ fence: Fence) -> Bool {
        let body = line.dropFirst(indent(line))
        let run = body.prefix(while: { $0 == fence.character }).count
        return run >= fence.length && body.dropFirst(run).allSatisfy(\.isWhitespace)
    }

    static func isRule(_ line: String) -> Bool {
        let body = line.filter { !$0.isWhitespace }
        guard let character = body.first, "-*_".contains(character) else { return false }
        return body.count >= 3 && body.allSatisfy { $0 == character }
    }

    static func heading(_ line: String) -> (level: Int, text: String)? {
        let body = line.dropFirst(indent(line))
        let level = body.prefix(while: { $0 == "#" }).count
        let rest = body.dropFirst(level)
        guard (1...6).contains(level), rest.isEmpty || rest.first == " " else { return nil }
        return (level, strippingClosingHashes(rest))
    }

    static func isQuote(_ line: String) -> Bool { line.dropFirst(indent(line)).first == ">" }

    static func strippingQuoteMarker(_ line: String) -> String {
        var body = line.dropFirst(indent(line)).dropFirst()
        if body.first == " " { body = body.dropFirst() }
        return String(body)
    }

    static func listMarker(_ line: String) -> Marker? {
        let indent = indent(line)
        let body = line.dropFirst(indent)
        guard let character = body.first else { return nil }
        var isOrdered = false
        var number = 1
        var width = 1
        if !"-*+".contains(character) {
            let digits = body.prefix(while: \.isNumber)
            guard digits.count <= 9, let value = Int(digits),
                let delimiter = body.dropFirst(digits.count).first, delimiter == "." || delimiter == ")"
            else { return nil }
            isOrdered = true
            number = value
            width = digits.count + 1
        }
        let rest = body.dropFirst(width)
        let gap = rest.prefix(while: { $0 == " " }).count
        guard rest.isEmpty || gap > 0 else { return nil }
        return Marker(
            indent: indent, contentIndent: indent + width + max(gap, 1), isOrdered: isOrdered,
            number: number)
    }

    static func startsBlock(_ line: String) -> Bool {
        fence(line) != nil || isRule(line) || heading(line) != nil || isQuote(line)
            || imageURL(line) != nil || listMarker(line) != nil
    }

    static func taskBox(_ text: String) -> (checked: Bool, rest: String)? {
        guard text.count >= 3, text.hasPrefix("["), text.dropFirst(2).first == "]" else { return nil }
        let box = text.dropFirst().first
        guard box == " " || box == "x" || box == "X" else { return nil }
        let rest = text.dropFirst(3)
        guard rest.isEmpty || rest.first == " " else { return nil }
        return (box != " ", String(rest.dropFirst(rest.isEmpty ? 0 : 1)))
    }

    /// `![alt](url)` or `<img src="url">` alone on a line; anything else stays inline text.
    static func imageURL(_ line: String) -> URL? {
        let body = line.trimmingCharacters(in: .whitespaces)
        let target: String
        if body.hasPrefix("<img"),
            let tag = body.wholeMatch(of: #/<img(?:\s[^>]*?)?\ssrc=["']([^"']+)["'][^>]*>/#)
        {
            target = String(tag.1)
        } else {
            guard body.hasPrefix("!["), let open = body.lastIndex(of: "("), body.hasSuffix(")") else {
                return nil
            }
            let inner = body[body.index(after: open)..<body.index(before: body.endIndex)]
            target = inner.split(separator: " ").first.map(String.init) ?? String(inner)
        }
        guard let url = URL(string: target) else { return nil }
        switch url.scheme {
        case "http", "https": return url.host == nil ? nil : url
        case "data": return target.count > "data:".count ? url : nil
        default: return nil
        }
    }

    static func tableCells(_ line: String) -> [String] {
        var body = Substring(line.trimmingCharacters(in: .whitespaces))
        if body.first == "|" { body = body.dropFirst() }
        if body.hasSuffix("|"), !body.hasSuffix("\\|") { body = body.dropLast() }
        var cells: [String] = []
        var current = ""
        var isEscaped = false
        for character in body {
            if isEscaped || character == "\\" {
                isEscaped = !isEscaped && character == "\\"
                current.append(character)
            } else if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    /// The pipe is required: without it a lone `---` under a line of prose is a rule, not a table.
    static func tableAlignments(_ line: String) -> [ExtensionMarkdown.Block.Table.Alignment]? {
        guard line.contains("|") else { return nil }
        var alignments: [ExtensionMarkdown.Block.Table.Alignment] = []
        for cell in tableCells(line) {
            let dashes = cell.trimmingCharacters(in: CharacterSet(charactersIn: ":"))
            guard !dashes.isEmpty, dashes.allSatisfy({ $0 == "-" }) else { return nil }
            let isLeading = cell.hasPrefix(":")
            let isTrailing = cell.hasSuffix(":")
            alignments.append(isLeading && isTrailing ? .center : isTrailing ? .trailing : .leading)
        }
        return alignments.isEmpty ? nil : alignments
    }

    static func resizing(_ cells: [String], to count: Int) -> [String] {
        cells.count >= count
            ? Array(cells.prefix(count)) : cells + Array(repeating: "", count: count - cells.count)
    }

    static func dedent(_ line: String, by count: Int) -> String {
        var body = Substring(line)
        var remaining = count
        while remaining > 0, let character = body.first, character == " " || character == "\t" {
            body = body.dropFirst()
            remaining -= 1
        }
        return String(body)
    }

    /// A closing `###` run counts only when spaced off the text, so `# C#` keeps its hash.
    private static func strippingClosingHashes(_ text: Substring) -> String {
        let body = text.trimmingCharacters(in: .whitespaces)
        let hashes = body.reversed().prefix(while: { $0 == "#" }).count
        guard hashes > 0, hashes < body.count,
            body[body.index(body.endIndex, offsetBy: -hashes - 1)] == " "
        else { return body }
        return body.dropLast(hashes).trimmingCharacters(in: .whitespaces)
    }
}
