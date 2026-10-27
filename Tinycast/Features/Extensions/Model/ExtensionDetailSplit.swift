import Foundation

/// A list/detail split as a share of the pane space; the caller passes the minima already scaled.
struct ExtensionDetailSplit: Equatable, Sendable {
    static let defaultFraction: CGFloat = 0.33
    static let minimumFraction: CGFloat = 0.28
    static let maximumFraction: CGFloat = 0.60
    static let minimumListWidth: CGFloat = 200
    static let minimumDetailWidth: CGFloat = 300
    static let dividerWidth: CGFloat = 1

    static let standard = ExtensionDetailSplit()

    /// Always inside the fraction clamp, so a dragged or stored value can never leave it.
    var fraction: CGFloat

    init(fraction: CGFloat = ExtensionDetailSplit.defaultFraction) {
        self.fraction = ExtensionDetailSplit.clamped(fraction)
    }

    static func clamped(_ fraction: CGFloat) -> CGFloat {
        min(max(fraction, minimumFraction), maximumFraction)
    }

    /// Detail minimum outranks the cap, list minimum the floor, a too-narrow width splits in ratio.
    func listWidth(
        in contentWidth: CGFloat,
        minimumList: CGFloat = ExtensionDetailSplit.minimumListWidth,
        minimumDetail: CGFloat = ExtensionDetailSplit.minimumDetailWidth,
        divider: CGFloat = ExtensionDetailSplit.dividerWidth
    ) -> CGFloat {
        let panes = contentWidth - divider
        guard panes > 0 else { return 0 }
        guard panes >= minimumList + minimumDetail else {
            return panes * minimumList / (minimumList + minimumDetail)
        }
        return max(min(fraction * panes, panes - minimumDetail), minimumList)
    }

    func detailWidth(
        in contentWidth: CGFloat,
        minimumList: CGFloat = ExtensionDetailSplit.minimumListWidth,
        minimumDetail: CGFloat = ExtensionDetailSplit.minimumDetailWidth,
        divider: CGFloat = ExtensionDetailSplit.dividerWidth
    ) -> CGFloat {
        max(
            0,
            contentWidth - divider
                - listWidth(
                    in: contentWidth, minimumList: minimumList, minimumDetail: minimumDetail,
                    divider: divider))
    }

    /// A drag is measured from where it began, so a clamp never leaves the divider stuck behind it.
    func dragged(
        by translation: CGFloat,
        in contentWidth: CGFloat,
        minimumList: CGFloat = ExtensionDetailSplit.minimumListWidth,
        minimumDetail: CGFloat = ExtensionDetailSplit.minimumDetailWidth,
        divider: CGFloat = ExtensionDetailSplit.dividerWidth
    ) -> ExtensionDetailSplit {
        let panes = contentWidth - divider
        guard panes >= minimumList + minimumDetail else { return self }
        let width = listWidth(
            in: contentWidth, minimumList: minimumList, minimumDetail: minimumDetail,
            divider: divider)
        let bounded = min(max(width + translation, minimumList), panes - minimumDetail)
        return ExtensionDetailSplit(fraction: bounded / panes)
    }

    mutating func reset() {
        self = ExtensionDetailSplit.standard
    }
}
