//
//  LanguageManager.swift
//  LiminalGenerator
//
//  In-app language selection (About sheet). The choice is stored in
//  UserDefaults ("appLanguage": "system" | "en" | "es" | "pt-BR" | "fr" |
//  "de" | "ja"). It is applied three ways so that every surface we own
//  follows it live, without a restart:
//   1. SwiftUI: the app root injects `.environment(\.locale, ...)`, which
//      localizes every `Text("KEY")` / LocalizedStringKey (incl.
//      accessibility labels) from the string catalog.
//   2. Code: `tr(...)` resolves a LocalizedStringResource with the chosen
//      locale (alerts, errors, typewriter intro, video OSD, timestamps).
//   3. Rendered video: VHSFrameCompositor calls `tr(...)` when it is built,
//      so a clip rendered after switching is baked in the chosen language.
//  System-owned surfaces (share sheet, StoreKit purchase sheets, the review
//  prompt, the keyboard) keep the device language.
//

import SwiftUI

enum AppLanguage {
    static let defaultsKey = "appLanguage"
    static let systemCode = "system"

    struct Option: Identifiable, Hashable {
        let code: String
        /// Name shown in the picker, always in the language itself.
        /// nil = "System Default" (localized through the catalog).
        let nativeName: String?
        var id: String { code }
    }

    static let options: [Option] = [
        Option(code: systemCode, nativeName: nil),
        Option(code: "en", nativeName: "English"),
        Option(code: "es", nativeName: "Español"),
        Option(code: "pt-BR", nativeName: "Português (Brasil)"),
        Option(code: "fr", nativeName: "Français"),
        Option(code: "de", nativeName: "Deutsch"),
        Option(code: "ja", nativeName: "日本語"),
    ]

    /// Current selection code; thread-safe (UserDefaults).
    static var selection: String {
        let v = UserDefaults.standard.string(forKey: defaultsKey) ?? systemCode
        return options.contains { $0.code == v } ? v : systemCode
    }

    /// nil = follow the system.
    static var overrideLocale: Locale? {
        let s = selection
        return s == systemCode ? nil : Locale(identifier: s)
    }

    static var locale: Locale { overrideLocale ?? .autoupdatingCurrent }
}

@MainActor
final class LanguageManager: ObservableObject {
    @Published var selection: String {
        didSet { UserDefaults.standard.set(selection, forKey: AppLanguage.defaultsKey) }
    }

    init() {
        #if DEBUG
        if ProcessInfo.processInfo.environment["LG_RESET_LANGUAGE"] == "1" {
            UserDefaults.standard.removeObject(forKey: AppLanguage.defaultsKey)
        }
        #endif
        selection = AppLanguage.selection
    }

    var locale: Locale { selection == AppLanguage.systemCode ? .autoupdatingCurrent : Locale(identifier: selection) }
}

/// Resolve a localized string for the in-app language (usable off the main
/// thread). Prefer `Text("KEY")` in views; use this for strings built in code.
func tr(_ resource: LocalizedStringResource) -> String {
    var r = resource
    if let l = AppLanguage.overrideLocale { r.locale = l }
    return String(localized: r)
}
