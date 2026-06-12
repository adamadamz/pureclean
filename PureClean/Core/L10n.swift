import Foundation
import SwiftUI

/// 本地 JSON 多语言：zh-Hans / zh-Hant / en / es。
/// 不依赖任何在线服务；用户可在设置内覆盖系统语言。
@MainActor
final class L10n: ObservableObject {
    static let shared = L10n()
    static let supported = ["zh-Hans", "zh-Hant", "en", "es"]

    @AppStorage("pc.language") private var storedLanguage = ""  // 空 = 跟随系统
    @Published private(set) var table: [String: String] = [:]
    @Published private(set) var code: String = "en"

    private var fallback: [String: String] = [:]

    private init() { reload() }

    var languageOverride: String {
        get { storedLanguage }
        set { storedLanguage = newValue; reload() }
    }

    func reload() {
        fallback = Self.load("en")
        let preferred = storedLanguage.isEmpty ? Self.detectSystem() : storedLanguage
        code = preferred
        table = Self.load(preferred)
    }

    /// 取词。键缺失时回退英文，再缺失返回键名（便于发现漏译）。
    func t(_ key: String) -> String {
        table[key] ?? fallback[key] ?? key
    }

    func t(_ key: String, _ args: CVarArg...) -> String {
        String(format: t(key), arguments: args)
    }

    private static func detectSystem() -> String {
        // 首选：Bundle.preferredLocalizations 由系统按「用户语言 × App 声明语言(lproj)」
        // 标准匹配，依赖 Info.plist 的 CFBundleLocalizations 声明——
        // 未声明时 iOS 视 App 为纯英文，跟随系统会恒为 en（曾导致订阅页全英文）
        for lang in Bundle.main.preferredLocalizations + Locale.preferredLanguages {
            if lang.hasPrefix("zh-Hant") || lang.hasPrefix("zh-HK") || lang.hasPrefix("zh-TW") { return "zh-Hant" }
            if lang.hasPrefix("zh") { return "zh-Hans" }
            if lang.hasPrefix("es") { return "es" }
            if lang.hasPrefix("en") { return "en" }
        }
        return "en"
    }

    private static func load(_ code: String) -> [String: String] {
        guard let url = Bundle.main.url(forResource: code, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let dict = try? JSONDecoder().decode([String: String].self, from: data)
        else { return [:] }
        return dict
    }
}

/// 字节数本地化格式 "1.2 GB"；禁用非数字格式（避免 0 显示为 "Zero KB"）
func formatBytes(_ bytes: Int64) -> String {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.allowsNonnumericFormatting = false
    return formatter.string(fromByteCount: max(0, bytes))
}
