import CoreGraphics
import Foundation

/// The extension list/detail split: the list's share, the two minima, and a drag that never inverts.
@main
@MainActor
struct ExtensionDetailSplitTests {
    static var failures = 0
    static var passes = 0

    /// The palette's 750pt content, and the minima `ExtensionListView` hands in at `.standard`.
    static let width: CGFloat = 750
    static let minimumList: CGFloat = 200
    static let minimumDetail: CGFloat = 300
    static let divider = ExtensionDetailSplit.dividerWidth

    static func expect(_ condition: Bool, _ message: String) {
        if condition {
            passes += 1
            print("PASS  \(message)")
        } else {
            failures += 1
            print("FAIL  \(message)")
        }
    }

    static func expect(_ actual: CGFloat, _ expected: CGFloat, _ message: String) {
        expect(abs(actual - expected) < 0.001, "\(message) — got \(actual), want \(expected)")
    }

    static func main() {
        defaults()
        fractionClamp()
        widthClamps()
        scaledMinima()
        dragging()
        reset()
        degenerateWidths()
        coverage()
        store()

        print("")
        print(failures == 0 ? "ALL PASSED" : "\(failures) FAILED")
        print("\(passes) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    // MARK: - The default

    static func defaults() {
        let split = ExtensionDetailSplit()
        expect(split.fraction, 0.33, "an untouched split is the 0.33 default")
        expect(ExtensionDetailSplit.standard.fraction, 0.33, "`standard` is the default too")
        // 749pt of pane space: the hairline is not the list's to spend.
        expect(split.listWidth(in: width), 247.17, "750pt gives the list ~247pt")
        expect(split.detailWidth(in: width), 501.83, "and the detail the other ~502pt")
        expect(split.detailWidth(in: width) > split.listWidth(in: width), "which is the wider pane")
    }

    // MARK: - Clamps

    static func fractionClamp() {
        expect(ExtensionDetailSplit.clamped(0.9), 0.60, "a stored fraction above the cap is 0.60")
        expect(ExtensionDetailSplit.clamped(0.1), 0.28, "and one below the floor is 0.28")
        expect(ExtensionDetailSplit.clamped(0.45), 0.45, "a fraction inside the range is kept")
        expect(ExtensionDetailSplit(fraction: 0.9).fraction, 0.60, "the initialiser clamps the cap")
        expect(ExtensionDetailSplit(fraction: -1).fraction, 0.28, "the initialiser clamps the floor")
    }

    static func widthClamps() {
        let capped = ExtensionDetailSplit(fraction: 0.60)
        // 0.60 x 749 is 449.4, but the detail may not fall under 300: the minimum wins.
        expect(capped.listWidth(in: width), 449, "the 0.60 cap gives way to the 300pt detail minimum")
        expect(capped.detailWidth(in: width), 300, "so the detail pane stops at exactly 300pt")

        let floored = ExtensionDetailSplit(fraction: 0.28)
        expect(floored.listWidth(in: width), 209.72, "the 0.28 floor leaves the list ~210pt")
        expect(
            floored.listWidth(in: width) >= minimumList,
            "which is still over the list's own 200pt minimum")
    }

    // MARK: - Interface Size

    static func scaledMinima() {
        // Interface Size 1.2: a 900pt panel, and minima scaled with it.
        let scaledWidth: CGFloat = 900
        let scaledList = minimumList * 1.2
        let scaledDetail = minimumDetail * 1.2
        let split = ExtensionDetailSplit()

        let list = split.listWidth(in: scaledWidth, minimumList: scaledList, minimumDetail: scaledDetail)
        expect(list, 296.67, "1.2x gives the list ~297pt, the same share as 750pt")
        expect(list / (scaledWidth - divider), 0.33, "so the proportion survives the scale")
        expect(
            split.detailWidth(in: scaledWidth, minimumList: scaledList, minimumDetail: scaledDetail),
            602.33, "and the detail ~602pt")

        let capped = ExtensionDetailSplit(fraction: 0.60)
        expect(
            capped.detailWidth(in: scaledWidth, minimumList: scaledList, minimumDetail: scaledDetail),
            360, "the scaled detail minimum still outranks the cap")

        let floored = ExtensionDetailSplit(fraction: 0.28)
        expect(
            floored.listWidth(in: scaledWidth, minimumList: scaledList, minimumDetail: scaledDetail)
                >= scaledList, "and the scaled list minimum still holds at the floor")
    }

    // MARK: - Dragging

    static func dragging() {
        let split = ExtensionDetailSplit()
        let wider = split.dragged(by: 100, in: width, minimumList: minimumList, minimumDetail: minimumDetail)
        expect(wider.listWidth(in: width), 347.17, "a 100pt drag widens the list by 100pt")
        expect(wider.fraction, 347.17 / 749, "and records it as a fraction")

        let narrower = split.dragged(
            by: -20, in: width, minimumList: minimumList, minimumDetail: minimumDetail)
        expect(narrower.listWidth(in: width), 227.17, "a 20pt drag left narrows it by 20pt")

        let still = split.dragged(by: 0, in: width, minimumList: minimumList, minimumDetail: minimumDetail)
        expect(still.fraction, 0.33, "a drag that never moves changes nothing")

        let pastDetail = split.dragged(
            by: 1000, in: width, minimumList: minimumList, minimumDetail: minimumDetail)
        expect(pastDetail.listWidth(in: width), 449, "dragging past the right bound stops at 449pt")
        expect(pastDetail.detailWidth(in: width), 300, "leaving the detail its 300pt minimum")

        let pastList = split.dragged(
            by: -1000, in: width, minimumList: minimumList, minimumDetail: minimumDetail)
        expect(pastList.fraction, 0.28, "dragging past the left bound stops at the 0.28 floor")
        expect(
            pastList.listWidth(in: width) >= minimumList,
            "and the list never goes under its own minimum on the way")

        // Reported from the drag's start, so coming back off a clamp recovers at once.
        let back = split.dragged(by: 90, in: width, minimumList: minimumList, minimumDetail: minimumDetail)
        expect(back.listWidth(in: width), 337.17, "a drag is measured from where it began, not the clamp")

        let narrowPanel = split.dragged(
            by: 100, in: 620, minimumList: minimumList, minimumDetail: minimumDetail)
        expect(narrowPanel.listWidth(in: 620), 304.27, "a 620pt panel still drags by the same points")

        let scaled = split.dragged(
            by: 100, in: 900, minimumList: minimumList * 1.2, minimumDetail: minimumDetail * 1.2)
        expect(scaled.listWidth(in: 900, minimumList: 240, minimumDetail: 360), 396.67, "1.2x drags too")
    }

    // MARK: - Reset

    static func reset() {
        var split = ExtensionDetailSplit(fraction: 0.55)
        split.reset()
        expect(split.fraction, 0.33, "a reset returns to the 0.33 default")
        expect(split.listWidth(in: width), 247.17, "and to the default widths")
    }

    // MARK: - Degenerate widths

    static func degenerateWidths() {
        let split = ExtensionDetailSplit()
        expect(split.listWidth(in: 0), 0, "no width leaves the list nothing to draw")
        expect(split.detailWidth(in: 0), 0, "and the detail nothing either")
        expect(split.listWidth(in: -80), 0, "a negative width cannot invert the panes")
        expect(split.detailWidth(in: -80), 0, "nor give the detail a negative one")

        // 299pt of pane space cannot hold both minima, so the two share it in their own ratio.
        let narrow = split.listWidth(in: 300, minimumList: minimumList, minimumDetail: minimumDetail)
        let narrowDetail = split.detailWidth(
            in: 300, minimumList: minimumList, minimumDetail: minimumDetail)
        expect(narrow, 119.6, "a 300pt width splits the list ~120pt")
        expect(narrowDetail, 179.4, "and the detail ~179pt")
        expect(narrow > 0 && narrowDetail > 0, "both panes stay positive")

        let exact = split.listWidth(in: 501, minimumList: minimumList, minimumDetail: minimumDetail)
        expect(exact, 200, "the narrowest width that fits both minima is the list's own minimum")
        expect(
            split.detailWidth(in: 501, minimumList: minimumList, minimumDetail: minimumDetail), 300,
            "with the detail's minimum beside it")

        // A drag has nowhere to go before the width can honour both minima.
        let pinned = split.dragged(by: 100, in: 300, minimumList: minimumList, minimumDetail: minimumDetail)
        expect(pinned.fraction, 0.33, "a drag inside a too-narrow panel changes nothing")
    }

    // MARK: - Coverage

    static func coverage() {
        let widths: [CGFloat] = [0, 1, 2, 120, 300, 501, 620, 750, 900, 1200, 2000]
        let fractions: [CGFloat] = [0, 0.28, 0.33, 0.5, 0.6, 1]
        var covered = true
        var positive = true
        for contentWidth in widths {
            for fraction in fractions {
                let split = ExtensionDetailSplit(fraction: fraction)
                let list = split.listWidth(in: contentWidth)
                let detail = split.detailWidth(in: contentWidth)
                let span = contentWidth < divider ? contentWidth : contentWidth - divider
                if abs(list + detail - max(0, span)) >= 0.001 { covered = false }
                if contentWidth > divider, !(list > 0 && detail > 0) { positive = false }
                if list < 0 || detail < 0 { covered = false }
            }
        }
        expect(covered, "list + divider + detail covers the content width at every size")
        expect(positive, "both panes stay positive wherever there is room to draw them")

        // The same, straight from the two accessors the view calls.
        let split = ExtensionDetailSplit(fraction: 0.33)
        expect(
            split.listWidth(in: width) + divider + split.detailWidth(in: width), width,
            "750pt is fully spent across the three")
        expect(
            split.listWidth(in: 620) + divider + split.detailWidth(in: 620), 620,
            "and so is 620pt")
        expect(
            split.listWidth(in: 900) + divider + split.detailWidth(in: 900), 900,
            "and 900pt")
    }

    // MARK: - The remembered choice

    static func store() {
        let suite = "ext-detail-split-test-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            expect(false, "a private defaults suite")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = ExtensionDetailSplitStore(defaults: defaults)
        expect(store.fraction, 0.33, "an untouched store is the default")

        store.set(0.4)
        expect(store.fraction, 0.4, "a dragged fraction reads back")
        expect(
            ExtensionDetailSplitStore(defaults: defaults).fraction, 0.4,
            "and survives a new store over the same defaults")

        store.set(0.9)
        expect(store.fraction, 0.60, "a stored value above the cap is clamped on the way in")
        store.set(0.1)
        expect(store.fraction, 0.28, "and one below the floor on the way out")
    }
}
