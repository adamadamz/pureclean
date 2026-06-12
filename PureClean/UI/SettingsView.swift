import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var store: StoreManager
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var l10n: L10n
    @Environment(\.dismiss) private var dismiss
    @State private var showPaywall = false
    @State private var showPrivacy = false
    @State private var restoreMessage: String?

    /// 「跟随系统」选项随当前语言本地化（对齐 iOS 系统设置）；
    /// 各语言名按惯例显示其母语原文，不翻译
    private var languages: [(String, String)] {
        [("", l10n.t("settings.language.system")),
         ("zh-Hans", "简体中文"), ("zh-Hant", "繁體中文"),
         ("en", "English"), ("es", "Español")]
    }

    var body: some View {
        NavigationStack {
            List {
                Section(l10n.t("settings.language")) {
                    Picker(l10n.t("settings.language"), selection: Binding(
                        get: { l10n.languageOverride },
                        set: { l10n.languageOverride = $0 }
                    )) {
                        ForEach(languages, id: \.0) { code, name in
                            Text(name).tag(code)
                        }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }

                Section(l10n.t("settings.pro")) {
                    subscriptionStatusRow

                    Toggle(l10n.t("settings.autoClean"), isOn: Binding(
                        get: { appState.autoCleanEnabled && store.isPro },
                        set: { newValue in
                            if store.isPro { appState.autoCleanEnabled = newValue }
                            else { showPaywall = true }
                        }))

                    if store.isPro {
                        // 审核合规：退订入口必须可达
                        Button(l10n.t("settings.manage")) {
                            Task { await store.manageSubscriptions() }
                        }
                    } else {
                        Button(l10n.t("settings.upgrade")) { showPaywall = true }
                            .foregroundStyle(Theme.accent)
                    }

                    Button(l10n.t("paywall.restore")) {
                        Task {
                            await store.restore()
                            switch store.lastRestoreOutcome {
                            case .restored:        restoreMessage = l10n.t("restore.success")
                            case .nothingToRestore: restoreMessage = l10n.t("restore.none")
                            case .failed:          restoreMessage = l10n.t("restore.failed")
                            case .none:            break
                            }
                            store.lastRestoreOutcome = nil
                        }
                    }
                }

                Section(l10n.t("settings.privacy")) {
                    // 全文移入弹窗阅读，主界面保持极简
                    Button {
                        showPrivacy = true
                    } label: {
                        HStack {
                            Text(l10n.t("settings.privacy.view"))
                                .foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.bg)
            .navigationTitle(l10n.t("settings.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(l10n.t("common.done")) { dismiss() }
                }
            }
        }
        .sheet(isPresented: $showPaywall) { PaywallView() }
        .sheet(isPresented: $showPrivacy) {
            NavigationStack {
                ScrollView {
                    Text(l10n.t("settings.privacy.body"))
                        .font(.subheadline)
                        .foregroundStyle(Theme.textPrimary)
                        .lineSpacing(5)
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .background(Theme.bg)
                .navigationTitle(l10n.t("settings.privacy.view"))
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(l10n.t("common.done")) { showPrivacy = false }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
        .alert(restoreMessage ?? "", isPresented: Binding(
            get: { restoreMessage != nil },
            set: { if !$0 { restoreMessage = nil } }
        )) {
            Button(l10n.t("common.done"), role: .cancel) {}
        }
    }

    /// 订阅状态行：未订阅 / 已订阅（到期时间 + 是否续期）
    @ViewBuilder
    private var subscriptionStatusRow: some View {
        if store.isPro {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Theme.accent)
                    Text(l10n.t("settings.status.active"))
                        .font(.subheadline.weight(.semibold))
                }
                if let expiry = store.expirationDate {
                    Text(l10n.t(
                        store.willAutoRenew ? "settings.status.renews" : "settings.status.expires",
                        expiry.formatted(date: .abbreviated, time: .omitted)))
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }
        } else {
            Text(l10n.t("settings.status.free"))
                .font(.subheadline).foregroundStyle(Theme.textSecondary)
        }
    }
}
