import SwiftUI

/// Pro 订阅页（交付级）：
/// - 价格动态读取（loading / failed+重试 / loaded 三态，杜绝 "—" 占位上线）
/// - 试用天数按账号资格动态显示（已用过试用的用户不显示，避免误导性宣传）
/// - 购买结果完整处理：成功关页 / 取消静默 / 待批准提示 / 失败弹窗
/// - 审核合规：订阅条款 + 用户协议(EULA) + 隐私政策链接齐备
struct PaywallView: View {
    @EnvironmentObject var store: StoreManager
    @EnvironmentObject var l10n: L10n
    @Environment(\.dismiss) private var dismiss

    @State private var showFailAlert = false
    @State private var failMessage = ""
    @State private var showPendingNote = false

    private let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    private let privacyURL = URL(string: "https://ystech.com/pureclean/privacy")!

    var body: some View {
        VStack(spacing: 18) {
            Capsule().fill(Theme.card).frame(width: 40, height: 5).padding(.top, 10)

            Image(systemName: "sparkles")
                .font(.system(size: 40)).foregroundStyle(Theme.accent)
            Text(l10n.t("paywall.title"))
                .font(.title2.weight(.bold)).foregroundStyle(Theme.textPrimary)

            VStack(alignment: .leading, spacing: 14) {
                benefit("square.stack.3d.up", l10n.t("paywall.batch"))
                benefit("magnifyingglass", l10n.t("paywall.deep"))
                benefit("arrow.triangle.2.circlepath", l10n.t("paywall.auto"))
            }
            .card()

            Spacer(minLength: 8)

            if showPendingNote {
                Text(l10n.t("paywall.pending"))
                    .font(.footnote).foregroundStyle(Theme.accent)
                    .multilineTextAlignment(.center)
            } else if let days = store.trialDays {
                Text(l10n.t("paywall.trialDays", days))
                    .font(.footnote).foregroundStyle(Theme.accent)
            }

            purchaseArea

            Button(l10n.t("paywall.restore")) {
                Task {
                    await store.restore()
                    if store.isPro { dismiss() }
                }
            }
            .font(.footnote).foregroundStyle(Theme.textSecondary)

            VStack(spacing: 6) {
                Text(l10n.t("paywall.terms"))
                    .font(.caption2).foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 16) {
                    Link(l10n.t("paywall.links.terms"), destination: termsURL)
                    Link(l10n.t("paywall.links.privacy"), destination: privacyURL)
                }
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary.opacity(0.9))
                .underline()
            }
        }
        .padding(20)
        .presentationDetents([.large])
        .background(Theme.bg)
        .alert(l10n.t("paywall.failed.title"), isPresented: $showFailAlert) {
            Button(l10n.t("common.done"), role: .cancel) {}
        } message: {
            Text(failMessage)
        }
        .onChange(of: store.lastPurchaseOutcome) { outcome in
            switch outcome {
            case .success:
                dismiss()
            case .pending:
                showPendingNote = true       // Ask to Buy：等待家长批准，到账自动解锁
            case .failed(let message):
                failMessage = message
                showFailAlert = true
            case .cancelled, .none:
                break                        // 用户主动取消：静默，不打扰
            }
            store.lastPurchaseOutcome = nil
        }
        .task {
            // 弹出时商品仍未加载成功则自动重试一轮
            if store.productState == .failed { await store.loadProducts() }
        }
    }

    /// 价格三态区
    @ViewBuilder
    private var purchaseArea: some View {
        switch store.productState {
        case .loading:
            HStack(spacing: 10) {
                ProgressView().tint(Theme.accent)
                Text(l10n.t("paywall.loading"))
                    .font(.subheadline).foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(RoundedRectangle(cornerRadius: Theme.corner).fill(Theme.card))

        case .failed:
            VStack(spacing: 10) {
                Text(l10n.t("paywall.loadFailed"))
                    .font(.footnote).foregroundStyle(Theme.danger)
                #if DEBUG
                // 仅开发版可见：模拟器/本地调试最常见的真因不是网络，
                // 而是 Scheme 未选 StoreKit Configuration，或 ASC 商品未配置
                Text("[DEBUG] Edit Scheme → Run → Options → StoreKit Configuration → PureClean.storekit")
                    .font(.caption2.monospaced())
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                #endif
                Button(l10n.t("paywall.retry")) {
                    Task { await store.loadProducts() }
                }
                .buttonStyle(PrimaryButtonStyle())
            }

        case .loaded:
            Button {
                Task { await store.purchase() }
            } label: {
                if store.purchaseInFlight {
                    ProgressView().tint(.black)
                } else {
                    Text(l10n.t("paywall.subscribe",
                                store.monthly?.displayPrice ?? ""))
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(store.purchaseInFlight)
        }
    }

    private func benefit(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(Theme.accent).frame(width: 26)
            Text(text).font(.subheadline).foregroundStyle(Theme.textPrimary)
            Spacer()
        }
    }
}
