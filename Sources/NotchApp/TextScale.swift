import Combine
import SwiftUI

/// How much larger than designed the notch draws its text. One number, kept in defaults, that
/// every font in the panel goes through (`Font.ui`); the panel itself grows with it so nothing
/// clips.
@MainActor
final class TextScale: ObservableObject {
    static let shared = TextScale()
    static let options: [(label: String, value: Double)] = [("Default", 1.0), ("Larger", 1.1), ("Largest", 1.2)]
    private static let key = "textScale"

    @Published var value: Double {
        didSet { UserDefaults.standard.set(value, forKey: Self.key) }
    }

    private init() {
        let stored = UserDefaults.standard.double(forKey: Self.key)
        value = stored > 0 ? stored : 1
    }
}

extension Font {
    /// A system font at the design size times the user's text scale.
    @MainActor
    static func ui(_ size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: size * TextScale.shared.value, weight: weight, design: design)
    }
}
