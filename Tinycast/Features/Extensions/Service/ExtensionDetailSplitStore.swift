import Foundation

/// UI geometry, so it rides `UserDefaults` beside `palettePosition` rather than `settings.json`.
@MainActor
struct ExtensionDetailSplitStore {
    private static let key = "extensionDetailSplitFraction"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var fraction: CGFloat {
        // A missing key reads 0, which is a fraction of its own, so ask for the object first.
        guard defaults.object(forKey: Self.key) != nil else {
            return ExtensionDetailSplit.defaultFraction
        }
        return ExtensionDetailSplit.clamped(defaults.double(forKey: Self.key))
    }

    func set(_ fraction: CGFloat) {
        defaults.set(Double(ExtensionDetailSplit.clamped(fraction)), forKey: Self.key)
    }
}
