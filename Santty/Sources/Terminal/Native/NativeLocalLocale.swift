// Adapted from libghostty-spm 1d84cf66 (MIT); see Launch-Adaptation-NOTICE.txt.
import Foundation

/// Pure child-locale exports adapted from the pinned wrapper's Cocoa/gettext
/// policy. Unlike that wrapper, this never calls setenv or ghostty_init.
/// Existing nonempty LANG is preserved; Apple BCP-47 language tags are mapped
/// to POSIX gettext names without linking libintl.
enum NativeLocalLocale {
    struct Values: Equatable {
        var lang: String
        var language: String?
    }

    /// Child-only exports: nothing while `LANG` is set and
    /// not empty, otherwise `values` for the locale's codes.
    static func exports(
        currentLang: String?,
        locale: Locale,
        preferredLanguages: [String],
    ) -> Values? {
        if let currentLang, !currentLang.isEmpty { return nil }
        let locale = locale as NSLocale
        return values(
            languageCode: locale.object(forKey: .languageCode) as? String,
            countryCode: locale.object(forKey: .countryCode) as? String,
            preferredLanguages: preferredLanguages,
        )
    }

    /// `LANG` is `<language>_<country>.UTF-8`, nothing at all without both
    /// codes. `LANGUAGE` lists every preferred language as a POSIX name
    /// with `.UTF-8`, colon-separated, and is left unset when the list is
    /// empty. The limits are upstream's buffers: 128 bytes for `LANG`, 255
    /// per language, 1024 for `LANGUAGE`, whose overflow drops it whole.
    static func values(
        languageCode: String?,
        countryCode: String?,
        preferredLanguages: [String],
    ) -> Values? {
        guard let languageCode, let countryCode else { return nil }
        let lang = "\(languageCode)_\(countryCode).UTF-8"
        guard lang.utf8.count < 128 else { return nil }

        let names = preferredLanguages
            .filter { $0.utf8.count < 255 }
            .map { NativeLocalLocaleName.posix($0) + ".UTF-8" }
        let language = names.joined(separator: ":")
        guard !language.isEmpty, language.utf8.count < 1024 else {
            return Values(lang: lang, language: nil)
        }
        return Values(lang: lang, language: language)
    }
}
