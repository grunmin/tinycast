import SwiftUI

/// The `Detail` screen, and the pane a `List` shows when `isShowingDetail` is on.
struct ExtensionDetailBody: View {
    @Environment(\.metrics) private var metrics
    let markdown: String?
    let metadata: RenderNode?
    let isLoading: Bool
    let assetsPath: String?
    /// A list's detail pane is too narrow for a metadata sidebar.
    var stacksMetadata = false

    private static let documentInset: CGFloat = 16
    private static let documentVerticalInset: CGFloat = 13

    var body: some View {
        HStack(spacing: 0) {
            markdownPane(trailing: stacksMetadata ? metadata : nil)
            if !stacksMetadata, let metadata {
                Rectangle().fill(Theme.Colors.separator).frame(width: 1)
                metadataPane(metadata)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func markdownPane(trailing metadata: RenderNode?) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: metrics.spacing.md) {
                if isLoading && (markdown ?? "").isEmpty {
                    HStack(spacing: metrics.spacing.md) {
                        ProgressView().controlSize(.small)
                        Text("Loading…").foregroundStyle(.secondary)
                    }
                }
                if let markdown, !markdown.isEmpty {
                    ExtensionMarkdownView(markdown: markdown)
                }
                if let metadata {
                    ExtensionMetadataView(metadata: metadata, assetsPath: assetsPath, inline: true)
                        .padding(.top, (markdown ?? "").isEmpty ? 0 : metrics.spacing.xxl)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, metrics.scaled(Self.documentInset))
            .padding(.vertical, metrics.scaled(Self.documentVerticalInset))
            .hideNativeScrollers()
        }
        .frame(maxWidth: .infinity)
        .edgeDissolve()
        .thinScrollbar()
    }

    private static let metadataWidth: CGFloat = 240

    private func metadataPane(_ metadata: RenderNode) -> some View {
        ScrollView {
            ExtensionMetadataView(metadata: metadata, assetsPath: assetsPath)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, metrics.spacing.lg)
                .padding(.vertical, metrics.spacing.md)
                .hideNativeScrollers()
        }
        .frame(width: metrics.scaled(Self.metadataWidth))
        .edgeDissolve()
        .thinScrollbar()
    }
}

/// `Detail.Metadata` — label / link / tag-list / separator rows.
struct ExtensionMetadataView: View {
    @Environment(\.metrics) private var metrics
    @Environment(\.isDarkAppearance) private var isDark
    let metadata: RenderNode
    let assetsPath: String?
    var inline = false

    private static let inlineRowHeight: CGFloat = 28

    /// Stripes must count only real rows, so separators are dropped here.
    private var visibleChildren: [RenderNode] {
        inline
            ? metadata.children.filter { $0.type != "Detail.Metadata.Separator" }
            : metadata.children
    }

    var body: some View {
        VStack(alignment: .leading, spacing: inline ? 0 : metrics.spacing.lg) {
            ForEach(Array(visibleChildren.enumerated()), id: \.element.id) { index, child in
                switch child.type {
                case "Detail.Metadata.Label":
                    row(title: child.string("title"), index: index) {
                        HStack(spacing: metrics.spacing.xs) {
                            if let icon = child.props["icon"] {
                                ExtensionIconView(
                                    resolved: ExtensionImage.resolve(
                                        icon, assetsPath: assetsPath, isDark: isDark),
                                    size: 14)
                            }
                            Text(labelText(child))
                                .font(metrics.typography.rowTitle)
                                .textSelection(.enabled)
                        }
                    }
                case "Detail.Metadata.Link":
                    row(title: child.string("title"), index: index) {
                        if let target = child.string("target"), let url = URL(string: target) {
                            Link(child.string("text") ?? target, destination: url)
                                .font(metrics.typography.rowTitle)
                        } else {
                            Text(child.string("text") ?? "").font(metrics.typography.rowTitle)
                        }
                    }
                case "Detail.Metadata.TagList":
                    row(title: child.string("title"), index: index) {
                        ExtensionTagListView(tags: child.children, assetsPath: assetsPath)
                    }
                case "Detail.Metadata.Separator":
                    Rectangle().fill(Theme.Colors.separator).frame(height: 1)
                default:
                    EmptyView()
                }
            }
        }
    }

    /// `text` is a string or `{value, color}`; a Label can also carry only an icon.
    private func labelText(_ node: RenderNode) -> String {
        ExtensionAccessoriesView.label(node.props["text"])
            ?? node.date("text").map { $0.formatted(date: .abbreviated, time: .shortened) }
            ?? ""
    }

    @ViewBuilder
    private func row<Content: View>(
        title: String?, index: Int, @ViewBuilder content: () -> Content
    ) -> some View {
        if inline {
            HStack(alignment: .firstTextBaseline, spacing: metrics.spacing.xl) {
                Text(title ?? "")
                    .font(metrics.typography.rowTitle)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                content()
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, metrics.spacing.md)
            .padding(.vertical, metrics.spacing.xs)
            .frame(minHeight: metrics.scaled(Self.inlineRowHeight))
            .background(
                RoundedRectangle(cornerRadius: metrics.radius.menu, style: .continuous)
                    .fill(index.isMultiple(of: 2) ? ExtensionColors.detailCardFill : .clear))
        } else {
            VStack(alignment: .leading, spacing: 2) {
                if let title, !title.isEmpty {
                    Text(title)
                        .font(metrics.typography.sectionHeader)
                        .foregroundStyle(.secondary)
                }
                content()
            }
        }
    }
}

private struct ExtensionTagListView: View {

    @Environment(\.metrics) private var metrics
    @Environment(\.isDarkAppearance) private var isDark
    let tags: [RenderNode]
    let assetsPath: String?

    var body: some View {
        // Wrapping matters here: a metadata tag list is frequently longer than the pane is wide.
        FlowLayout(spacing: metrics.spacing.xs) {
            ForEach(tags) { tag in
                let color =
                    ExtensionImage.color(tag.props["color"], isDark: isDark) ?? Theme.Colors.textSecondary
                HStack(spacing: 3) {
                    if let icon = tag.props["icon"] {
                        ExtensionIconView(
                            resolved: ExtensionImage.resolve(icon, assetsPath: assetsPath, isDark: isDark),
                            size: 12)
                    }
                    Text(tag.string("text") ?? "")
                        .font(metrics.typography.rowTrailing)
                }
                .foregroundStyle(color)
                .padding(.horizontal, metrics.spacing.xs)
                .padding(.vertical, 2)
                .background(
                    RoundedRectangle(cornerRadius: 4, style: .continuous).fill(color.opacity(0.16))
                )
            }
        }
    }
}

/// Left-to-right wrapping row. SwiftUI has no built-in wrap, and tag lists need one.
struct FlowLayout: Layout {
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0
        var total = CGSize(width: 0, height: 0)
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if rowWidth > 0, rowWidth + spacing + size.width > width {
                total.width = max(total.width, rowWidth)
                total.height += rowHeight + spacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += rowWidth > 0 ? spacing + size.width : size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        total.width = max(total.width, rowWidth)
        total.height += rowHeight
        return total
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
