import SwiftUI

/// A `Detail`'s markdown, set as a document: block rhythm, hanging list indents, real code cards.
struct ExtensionMarkdownView: View {
    let markdown: String

    var body: some View {
        ExtensionMarkdownBlockList(blocks: ExtensionMarkdown.parse(markdown))
    }
}

/// One block list; `AnyView` erases the body so a nested list cannot make `Body` circular.
private struct ExtensionMarkdownBlockList: View {
    @Environment(\.metrics) private var metrics
    let blocks: [ExtensionMarkdown.Block]
    var style = ExtensionMarkdownStyle.document

    var body: AnyView {
        AnyView(
            VStack(alignment: .leading, spacing: 0) {
                // Positional, so a live image keeps its last frame while the next one decodes.
                ForEach(Array(blocks.enumerated()), id: \.offset) { offset, block in
                    ExtensionMarkdownBlockView(block: block, style: style)
                        .padding(
                            .top,
                            style.gap(after: offset > 0 ? blocks[offset - 1] : nil, before: block, metrics)
                        )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        )
    }
}

private enum ExtensionMarkdownStyle {
    case document
    case nested

    /// The air a block takes above it: a heading opens a section, a rule opens a pause.
    func gap(
        after previous: ExtensionMarkdown.Block?, before block: ExtensionMarkdown.Block,
        _ metrics: InterfaceMetrics
    ) -> CGFloat {
        guard let previous else { return 0 }
        if case .rule = block { return metrics.spacing.xl }
        if case .rule = previous { return metrics.spacing.xl }
        if case .heading(let level, _) = block {
            switch self {
            case .document:
                return level <= 2
                    ? metrics.scaled(ExtensionMarkdownGeometry.headingSpace)
                    : metrics.spacing.lg
            case .nested: return metrics.spacing.md
            }
        }
        if case .heading(let level, _) = previous {
            return level <= 2 ? metrics.spacing.md : metrics.spacing.sm
        }
        switch self {
        case .document: return metrics.scaled(ExtensionMarkdownGeometry.blockSpace)
        case .nested: return metrics.spacing.sm
        }
    }
}

private struct ExtensionMarkdownBlockView: View {
    @Environment(\.metrics) private var metrics
    let block: ExtensionMarkdown.Block
    let style: ExtensionMarkdownStyle

    var body: some View {
        switch block {
        case .heading(let level, let text):
            Text(ExtensionMarkdownInline.attributed(text, metrics))
                .font(ExtensionMarkdownInline.headingFont(level, metrics))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .paragraph(let text):
            Text(ExtensionMarkdownInline.attributed(text, metrics))
                .font(metrics.typography.rowTitle)
                .lineSpacing(metrics.scaled(ExtensionMarkdownGeometry.bodyLeading))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .bulletList(let items):
            ExtensionMarkdownListView(items: items, start: nil)
        case .numberedList(let start, let items):
            ExtensionMarkdownListView(items: items, start: start)
        case .code(let language, let text):
            ExtensionMarkdownCodeCard(language: language, text: text)
        case .quote(let blocks):
            ExtensionMarkdownQuoteView(blocks: blocks)
        case .table(let table):
            ExtensionMarkdownTableView(table: table)
        case .rule:
            Rectangle()
                .fill(Theme.Colors.separator)
                .frame(height: Theme.Size.hairline)
                .frame(maxWidth: .infinity)
        case .image(let url):
            ExtensionMarkdownImage(url: url)
        }
    }
}

private struct ExtensionMarkdownListView: View {
    @Environment(\.metrics) private var metrics
    let items: [ExtensionMarkdown.Block.Item]
    /// Nil for a bulleted list; otherwise the number the first item counts from.
    let start: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.spacing.xs) {
            ForEach(Array(items.enumerated()), id: \.offset) { offset, item in
                HStack(alignment: .firstTextBaseline, spacing: metrics.spacing.xs) {
                    marker(at: offset, checked: item.checked)
                    ExtensionMarkdownBlockList(blocks: item.blocks, style: .nested)
                }
            }
        }
    }

    @ViewBuilder private func marker(at offset: Int, checked: Bool?) -> some View {
        if let checked {
            SymbolImage(
                name: checked ? "checkmark.square.fill" : "square",
                size: metrics.scaled(ExtensionMarkdownGeometry.taskGlyph)
            )
            .foregroundStyle(checked ? Theme.Colors.success : Theme.Colors.textTertiary)
            .frame(width: metrics.size.markdownListMarker)
        } else if start != nil {
            // A fixed column and trailing alignment keep every wrapped line on the item's text.
            Text(verbatim: orderedMarker(at: offset))
                .font(metrics.typography.rowTitle)
                .monospacedDigit()
                .foregroundStyle(Theme.Colors.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .frame(width: metrics.size.markdownListMarker, alignment: .trailing)
        } else {
            Text(verbatim: "•")
                .font(metrics.typography.rowTitle)
                .foregroundStyle(Theme.Colors.textSecondary)
                .frame(width: metrics.size.markdownListMarker, alignment: .trailing)
        }
    }

    private func orderedMarker(at offset: Int) -> String {
        "\(start.map { $0 + offset } ?? 0)."
    }
}

private struct ExtensionMarkdownCodeCard: View {
    @Environment(\.metrics) private var metrics
    let language: String?
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.spacing.sm) {
            if let language, !language.isEmpty {
                Text(language)
                    .font(metrics.typography.keyCap)
                    .foregroundStyle(Theme.Colors.textTertiary)
            }
            Text(verbatim: text)
                .font(metrics.typography.code)
                .lineSpacing(metrics.scaled(ExtensionMarkdownGeometry.codeLeading))
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.horizontal, metrics.spacing.xl)
        .padding(.vertical, metrics.spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: metrics.radius.card, style: .continuous)
                .fill(Theme.Colors.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: metrics.radius.card, style: .continuous)
                .stroke(Theme.Colors.cardStroke)
        )
    }
}

private struct ExtensionMarkdownQuoteView: View {
    @Environment(\.metrics) private var metrics
    let blocks: [ExtensionMarkdown.Block]

    var body: some View {
        ExtensionMarkdownBlockList(blocks: blocks, style: .nested)
            .foregroundStyle(Theme.Colors.textSecondary)
            .padding(.leading, metrics.size.markdownQuoteBar + metrics.spacing.xl)
            .overlay(alignment: .leading) {
                // An overlay takes the content's height, so the bar ends with the words.
                RoundedRectangle(cornerRadius: metrics.radius.keyCap, style: .continuous)
                    .fill(Theme.Colors.border)
                    .frame(width: metrics.size.markdownQuoteBar)
            }
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct ExtensionMarkdownTableView: View {
    @Environment(\.metrics) private var metrics
    let table: ExtensionMarkdown.Block.Table

    var body: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 0, verticalSpacing: 0) {
            header
            hairline(Theme.Colors.cardStroke)
            ForEach(Array(table.rows.enumerated()), id: \.offset) { offset, row in
                bodyRow(row)
                if offset < table.rows.count - 1 {
                    hairline(Theme.Colors.cardStroke.opacity(0.6))
                }
            }
        }
        // Given only a width, Grid measures a wrapping row a line short of what it draws.
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: metrics.radius.card, style: .continuous)
                .fill(Theme.Colors.cardFill)
        )
        .clipShape(RoundedRectangle(cornerRadius: metrics.radius.card, style: .continuous))
    }

    private var header: some View {
        GridRow {
            ForEach(Array(table.header.enumerated()), id: \.offset) { column, cell in
                cellView(cell)
                    .font(metrics.typography.sectionHeader)
                    .foregroundStyle(Theme.Colors.textSecondary)
                    .frame(maxWidth: .infinity, alignment: alignment(at: column))
            }
        }
    }

    private func bodyRow(_ row: [String]) -> some View {
        GridRow {
            ForEach(Array(row.enumerated()), id: \.offset) { column, cell in
                cellView(cell)
                    .font(metrics.typography.rowTitle)
                    .lineSpacing(metrics.scaled(ExtensionMarkdownGeometry.tableCellLeading))
                    .frame(maxWidth: .infinity, alignment: alignment(at: column))
            }
        }
    }

    private func cellView(_ source: String) -> some View {
        Text(ExtensionMarkdownInline.attributed(source, metrics))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, metrics.spacing.md)
            .padding(.vertical, metrics.scaled(ExtensionMarkdownGeometry.tableCellInset))
    }

    private func hairline(_ color: Color) -> some View {
        GridRow {
            Rectangle()
                .fill(color)
                .frame(height: Theme.Size.hairline)
                .gridCellUnsizedAxes(.horizontal)
                .gridCellColumns(table.header.count)
        }
    }

    private func alignment(at column: Int) -> Alignment {
        switch table.alignments[column] {
        case .leading: .leading
        case .center: .center
        case .trailing: .trailing
        }
    }
}

/// Inline markdown for one block. `Text` renders emphasis on its own but not code or strikethrough.
private enum ExtensionMarkdownInline {
    static func attributed(_ source: String, _ metrics: InterfaceMetrics) -> AttributedString {
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        options.failurePolicy = .returnPartiallyParsedIfPossible
        var text =
            (try? AttributedString(markdown: source, options: options))
            ?? AttributedString(source)
        let intents = text.runs.compactMap { run in
            run.inlinePresentationIntent.map { ($0, run.range) }
        }
        for (intent, range) in intents {
            if intent.contains(.code) {
                text[range].font = metrics.typography.inlineCode
                text[range].backgroundColor = Theme.Colors.controlSurface
            }
            if intent.contains(.strikethrough) { text[range].strikethroughStyle = .single }
        }
        return text
    }

    static func headingFont(_ level: Int, _ metrics: InterfaceMetrics) -> Font {
        switch level {
        case 1: .system(size: metrics.scaled(ExtensionMarkdownGeometry.heading1), weight: .semibold)
        case 2: .system(size: metrics.scaled(ExtensionMarkdownGeometry.heading2), weight: .semibold)
        case 3: .system(size: metrics.scaled(ExtensionMarkdownGeometry.heading3), weight: .semibold)
        default: metrics.typography.rowTitle.weight(.semibold)
        }
    }
}

/// Geometry the document states for itself; `Theme` has no token for a heading's own type scale.
private enum ExtensionMarkdownGeometry {
    static let heading1: CGFloat = 20
    static let heading2: CGFloat = 17
    static let heading3: CGFloat = 15
    static let blockSpace: CGFloat = 11
    static let headingSpace: CGFloat = 14
    static let bodyLeading: CGFloat = 2.5
    static let codeLeading: CGFloat = 2
    static let tableCellLeading: CGFloat = 2
    static let tableCellInset: CGFloat = 5
    static let taskGlyph: CGFloat = 12.5
}

/// An image inside a Detail's markdown, at its own size or the one its URL asks for.
private struct ExtensionMarkdownImage: View {
    @Environment(\.metrics) private var metrics
    @Environment(\.isDarkAppearance) private var isDark
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Group {
                    if image.isAnimated {
                        AnimatedImageView(image: image)
                    } else {
                        Image(nsImage: image).resizable().scaledToFit()
                    }
                }
                .frame(
                    maxWidth: maxWidth ?? (size == nil ? image.size.width : .infinity), maxHeight: maxHeight
                )
                .clipShape(RoundedRectangle(cornerRadius: metrics.radius.menu, style: .continuous))
                .frame(maxWidth: .infinity)
            } else {
                RoundedRectangle(cornerRadius: metrics.radius.menu, style: .continuous)
                    .fill(ExtensionColors.detailCardFill)
                    .frame(height: 120)
            }
        }
        // Keyed on the appearance too: an inline SVG's palette resolves at decode, not in the URL.
        .task(id: ExtensionImage.LoadKey(source: source, isDark: isDark)) {
            // A slow remote load must not show the previous row's image meanwhile.
            if url.scheme != "data" { image = nil }
            let loaded =
                url.scheme == "data"
                ? await ExtensionIconCache.loadInlineAsync(
                    url, palette: ExtensionImage.svgPalette(isDark: isDark))
                : await ExtensionIconCache.loadRemoteAsync(url, asIcon: false)
            if !Task.isCancelled { image = loaded }
        }
    }

    private var source: ExtensionImage.Source {
        url.scheme == "data" ? .inline(url) : .remote(url)
    }

    private var size: ExtensionImageSize? { ExtensionImageSize(url: url) }

    private var maxWidth: CGFloat? { size?.width.map { CGFloat($0) } }

    private var maxHeight: CGFloat { size?.height.map { CGFloat($0) } ?? .infinity }
}
