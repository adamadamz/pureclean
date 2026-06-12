import Foundation
import StoreKit
import UIKit

/// StoreKit 2 订阅管理（交付级）。
/// 商业模式：App 付费下载（¥1 / $0.99，ASC 配置）；Pro 月订阅 ¥10 / $1.49，
/// 3 天免费试用（介绍性优惠）。Pro 解锁：批量清理、深度扫描、自动清理。
///
/// 覆盖的完整场景：
/// - 商品加载：loading / loaded / failed + 指数退避重试 3 次 + 手动重试
/// - 购买结果：成功 / 用户取消 / 待批准（家长同意・Ask to Buy）/ 校验失败 / 网络错误
/// - 试用资格：动态读取介绍性优惠时长与本账号资格（已用过试用的不显示）
/// - 权益刷新：currentEntitlements（StoreKit 本地缓存，离线可用）+ 到期时间 + 自动续期状态
/// - 外部变更：Transaction.updates 监听退款/升级/家庭共享/到期
/// - 恢复购买：AppStore.sync + 明确的成功/未找到反馈
/// - 管理订阅：系统订阅管理面板（退订入口，审核要求可达）
@MainActor
final class StoreManager: ObservableObject {

    static let monthlyID = "com.ystech.pureclean.pro.monthly"

    enum ProductState: Equatable {
        case loading
        case loaded
        case failed
    }

    enum PurchaseOutcome: Equatable {
        case success
        case cancelled
        case pending          // Ask to Buy：等待家长批准
        case failed(String)
    }

    enum RestoreOutcome: Equatable { case restored, nothingToRestore, failed }

    // MARK: - Published 状态

    @Published private(set) var isPro = false
    @Published private(set) var productState: ProductState = .loading
    @Published private(set) var monthly: Product?
    /// 试用天数；nil = 本账号无试用资格（已用过）或商品无介绍优惠
    @Published private(set) var trialDays: Int?
    /// 当前订阅到期时间（isPro 时有值）
    @Published private(set) var expirationDate: Date?
    /// 是否开启自动续期（用户已退订但未到期时为 false）
    @Published private(set) var willAutoRenew = true
    @Published var purchaseInFlight = false
    @Published var lastPurchaseOutcome: PurchaseOutcome?
    @Published var lastRestoreOutcome: RestoreOutcome?

    // App 生命周期内常驻（@StateObject 持有），无需 deinit 取消
    private var updatesTask: Task<Void, Never>?

    // MARK: - 生命周期

    func start() async {
        // 防重入：SwiftUI .task 可能随场景重建多次调用
        guard updatesTask == nil else { return }
        // 监听外部交易更新（退款、家庭共享、Ask to Buy 批准后到账、续期）
        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                guard let self else { return }
                if let transaction = try? Self.verify(update) {
                    await transaction.finish()
                    await self.refreshEntitlements()
                }
            }
        }
        await loadProducts()
        await refreshEntitlements()
    }

    // MARK: - 商品加载（重试 + 状态机）

    func loadProducts() async {
        productState = .loading
        for attempt in 0..<3 {
            do {
                if let product = try await Product.products(for: [Self.monthlyID]).first {
                    monthly = product
                    productState = .loaded
                    await refreshTrialEligibility(product)
                    return
                }
                // 请求成功但商品不存在（ASC 未配置/未生效）
                break
            } catch {
                // 指数退避：0.5s / 1s
                if attempt < 2 {
                    try? await Task.sleep(nanoseconds: UInt64(500_000_000 * (attempt + 1)))
                }
            }
        }
        productState = .failed
    }

    private func refreshTrialEligibility(_ product: Product) async {
        guard let subscription = product.subscription,
              let intro = subscription.introductoryOffer,
              intro.paymentMode == .freeTrial,
              await subscription.isEligibleForIntroOffer
        else { trialDays = nil; return }
        trialDays = Self.days(of: intro.period)
    }

    private static func days(of period: Product.SubscriptionPeriod) -> Int {
        switch period.unit {
        case .day:   return period.value
        case .week:  return period.value * 7
        case .month: return period.value * 30
        case .year:  return period.value * 365
        @unknown default: return period.value
        }
    }

    // MARK: - 权益

    func refreshEntitlements() async {
        var active = false
        var expiry: Date?
        for await entitlement in Transaction.currentEntitlements {
            guard let transaction = try? Self.verify(entitlement),
                  transaction.productID == Self.monthlyID,
                  transaction.revocationDate == nil else { continue }
            // 防御：StoreKit 缓存极端情况下可能给出已过期交易
            if let exp = transaction.expirationDate, exp <= .now { continue }
            active = true
            expiry = transaction.expirationDate
        }
        isPro = active
        expirationDate = expiry
        await refreshRenewalState()
    }

    private func refreshRenewalState() async {
        guard isPro,
              let statuses = try? await monthly?.subscription?.status,
              let status = statuses.first(where: { $0.state == .subscribed || $0.state == .inGracePeriod }),
              let renewalInfo = try? Self.verify(status.renewalInfo)
        else { willAutoRenew = true; return }
        willAutoRenew = renewalInfo.willAutoRenew
    }

    // MARK: - 购买

    func purchase() async {
        guard let product = monthly, !purchaseInFlight else { return }
        purchaseInFlight = true
        defer { purchaseInFlight = false }
        do {
            let result = try await product.purchase()
            switch result {
            case .success(let verification):
                let transaction = try Self.verify(verification)
                await transaction.finish()
                await refreshEntitlements()
                lastPurchaseOutcome = .success
            case .userCancelled:
                lastPurchaseOutcome = .cancelled   // 静默：不打扰用户
            case .pending:
                lastPurchaseOutcome = .pending     // Ask to Buy：到账由 updates 监听接管
            @unknown default:
                lastPurchaseOutcome = .failed("Unknown result")
            }
        } catch {
            lastPurchaseOutcome = .failed(error.localizedDescription)
        }
    }

    // MARK: - 恢复购买

    func restore() async {
        do {
            try await AppStore.sync()
            await refreshEntitlements()
            lastRestoreOutcome = isPro ? .restored : .nothingToRestore
        } catch {
            lastRestoreOutcome = .failed
        }
    }

    // MARK: - 管理订阅（系统面板，含退订入口）

    func manageSubscriptions() async {
        guard let scene = UIApplication.shared.connectedScenes
            .compactMap({ $0 as? UIWindowScene })
            .first(where: { $0.activationState == .foregroundActive })
        else { return }
        try? await AppStore.showManageSubscriptions(in: scene)
        await refreshEntitlements()
    }

    // MARK: - 校验

    private static func verify<T>(_ result: VerificationResult<T>) throws -> T {
        switch result {
        case .unverified(_, let error): throw error   // JWS 签名校验失败：拒绝解锁
        case .verified(let safe): return safe
        }
    }
}
