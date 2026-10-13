import Foundation

// Use the same language in AppKit, SwiftUI, and child command-line processes.
enum L10n {
    static let language: String = {
        let preferred = ProcessInfo.processInfo.environment["MACDISPLAYCTL_LANGUAGE"]
            ?? Bundle.main.preferredLocalizations.first ?? "en"
        return preferred.lowercased().hasPrefix("zh") ? "zh-Hans" : "en"
    }()
    private static let bundle: Bundle = {
        guard let path = Bundle.main.path(forResource: language, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return Bundle.main }
        return bundle
    }()
    static func text(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }
    static func format(_ key: String, _ arguments: CVarArg...) -> String {
        String(format: text(key), locale: Locale(identifier: language), arguments: arguments)
    }
}
