import Foundation
import Photos
import SwiftUI

/// 全屏大图预览项（长按缩略图触发，对齐系统相册「删前可查看」习惯）
struct PreviewItem: Identifiable {
    let asset: PHAsset
    var id: String { asset.localIdentifier }
}

enum ScanPhase: Equatable {
    case idle
    case scanning(Double)     // 0...1
    case preview
    case cleaning
    case done(Int64)          // 释放字节数
}

/// 扫描-预览-清理 全流程状态机（流程：扫描 → 预览 → 一键清理）。
@MainActor
final class AppState: ObservableObject {

    @Published var phase: ScanPhase = .idle
    @Published var storage = CacheScanner.deviceStorage()

    // 扫描结果
    @Published var junkItems: [JunkItem] = []
    @Published var photoResult = PhotoScanResult()

    // 用户勾选（localIdentifier / JunkItem.id）
    @Published var selectedAssetIDs: Set<String> = []
    @Published var selectedJunkIDs: Set<UUID> = []
    @Published var photoDenied = false
    /// 照片删除失败（权限不足/用户在系统框点了取消）——结果页须如实展示，绝不假装成功
    @Published var photoDeleteFailed = false
    /// 当前全屏预览的照片（nil = 未预览）
    @Published var previewItem: PreviewItem?

    // Pro：启动自动扫描（@Published 保证 Toggle 即时刷新，didSet 持久化）
    @Published var autoCleanEnabled = UserDefaults.standard.bool(forKey: "pc.autoClean") {
        didSet { UserDefaults.standard.set(autoCleanEnabled, forKey: "pc.autoClean") }
    }

    private let cacheScanner = CacheScanner()
    private let photoScanner = PhotoScanner()

    var junkSelectedBytes: Int64 {
        junkItems.filter { selectedJunkIDs.contains($0.id) }.reduce(0) { $0 + $1.size }
    }

    var assetSelectedBytes: Int64 {
        // 只查扫描期建好的体积缓存（字典），零磁盘 IO——此属性每帧都可能被 UI 调用
        selectedAssetIDs.reduce(0) { $0 + (photoResult.sizeByID[$1] ?? 0) }
    }

    var selectedAssets: [PHAsset] {
        var all = photoResult.duplicateGroups.flatMap(\.assets)
        all += photoResult.screenshots
        all += photoResult.largeVideos
        var seen = Set<String>()
        return all.filter {
            selectedAssetIDs.contains($0.localIdentifier) && seen.insert($0.localIdentifier).inserted
        }
    }

    // MARK: - 扫描

    /// 订阅门控（与原型一致）：识别和手动勾选清理人人免费；
    /// 「批量」相关的三件事归 Pro —— 深度扫描(相似)、默认勾选冗余项、全选按钮。
    /// 免费用户在「想一键全部清理」的时刻遇到 Paywall，这是最自然的付费点。
    func runScan(isPro: Bool) async {
        let deepScan = isPro
        if case .scanning = phase { return }
        phase = .scanning(0)
        selectedAssetIDs.removeAll()
        selectedJunkIDs.removeAll()
        photoDeleteFailed = false   // 清除上一轮的失败标记

        // 1. 沙盒垃圾（快，先做）
        let scanner = cacheScanner
        junkItems = await Task.detached(priority: .userInitiated) { scanner.scan() }.value
        selectedJunkIDs = Set(junkItems.map(\.id))   // 沙盒垃圾默认全选（无风险）
        phase = .scanning(0.05)

        // 2. 照片库
        let status = await PhotoScanner.requestAuthorization()
        photoDenied = !(status == .authorized || status == .limited)
        if !photoDenied {
            photoResult = await photoScanner.scan(deepScan: deepScan) { [weak self] p in
                self?.phase = .scanning(0.05 + p * 0.95)
            }
            // 默认勾选属于「批量清理」能力（Pro）：仅 Pro 且仅精确重复组自动勾选非保留项；
            // 免费用户从零开始手动勾选，想批量时点「全选」→ Paywall
            if isPro {
                for group in photoResult.duplicateGroups where !group.isSimilar {
                    for asset in group.assets where asset.localIdentifier != group.keepLocalID {
                        selectedAssetIDs.insert(asset.localIdentifier)
                    }
                }
            }
        } else {
            photoResult = PhotoScanResult()
        }
        phase = .preview
    }

    // MARK: - 勾选（底线规则：每组必须保留一张，任何入口不可绕过）

    /// 勾选/取消勾选。返回 false = 被底线规则拦截（该照片是组内最后一张未勾选的）。
    @discardableResult
    func toggleAssetSelection(_ asset: PHAsset) -> Bool {
        let id = asset.localIdentifier
        if selectedAssetIDs.contains(id) {
            selectedAssetIDs.remove(id)
            return true
        }
        // 底线第 1 层：同组（精确重复或相似）不允许全部勾选
        if let group = photoResult.duplicateGroups.first(where: { g in
            g.assets.contains { $0.localIdentifier == id }
        }) {
            let unselectedCount = group.assets.filter {
                !selectedAssetIDs.contains($0.localIdentifier)
            }.count
            if unselectedCount <= 1 { return false }   // 这是组里最后一张，禁止勾选
        }
        selectedAssetIDs.insert(id)
        return true
    }

    /// 全选冗余项：所有组（含相似组）勾选除「分辨率最高一张」外的全部成员。
    /// 这是产品初衷的代码化：找出重复/相似 → 保留最高清 → 清理其余。
    func selectAllRedundant() {
        for group in photoResult.duplicateGroups {
            for asset in group.assets where asset.localIdentifier != group.keepLocalID {
                selectedAssetIDs.insert(asset.localIdentifier)
            }
            // 同时纠正：若保留项之前被手动勾选过，强制移除
            selectedAssetIDs.remove(group.keepLocalID)
        }
    }

    /// 取消全选：清空所有重复/相似组的勾选（截图、大视频的勾选不受影响）
    func deselectAllRedundant() {
        for group in photoResult.duplicateGroups {
            for asset in group.assets {
                selectedAssetIDs.remove(asset.localIdentifier)
            }
        }
    }

    /// 所有组的冗余项是否均已勾选（驱动「全选 ↔ 取消勾选」按钮状态）
    var allRedundantSelected: Bool {
        let groups = photoResult.duplicateGroups
        guard !groups.isEmpty else { return false }
        return groups.allSatisfy { group in
            group.assets.allSatisfy {
                $0.localIdentifier == group.keepLocalID
                    || selectedAssetIDs.contains($0.localIdentifier)
            }
        }
    }

    // MARK: - 清理

    func clean() async {
        phase = .cleaning
        photoDeleteFailed = false
        var freed: Int64 = 0

        // 沙盒文件：白名单删除
        let junkToDelete = junkItems.filter { selectedJunkIDs.contains($0.id) }
        freed += SafeDeleter.delete(junk: junkToDelete)

        // 底线第 2 层（删除前最终校验）：任何组若被整组勾选，强制剔除保留项。
        // 即使未来 UI 出 bug，整组删除在这里也会被拦下。
        for group in photoResult.duplicateGroups {
            let allSelected = group.assets.allSatisfy {
                selectedAssetIDs.contains($0.localIdentifier)
            }
            if allSelected { selectedAssetIDs.remove(group.keepLocalID) }
        }

        // 照片：系统确认框 + 最近删除 30 天可恢复
        // 失败（权限不足/用户取消系统框）必须如实上报，不得吞错装成功
        let assets = selectedAssets
        if !assets.isEmpty {
            // 体积从缓存汇总（主线程零 IO），删除成功才计入
            let photoBytes = assets.reduce(Int64(0)) {
                $0 + (photoResult.sizeByID[$1.localIdentifier] ?? 0)
            }
            do {
                try await SafeDeleter.delete(assets: assets)
                freed += photoBytes
            } catch {
                photoDeleteFailed = true
            }
        }

        storage = CacheScanner.deviceStorage()
        phase = .done(freed)
    }

    func reset() {
        phase = .idle
        junkItems = []
        photoResult = PhotoScanResult()
        selectedAssetIDs.removeAll()
        selectedJunkIDs.removeAll()
        photoDeleteFailed = false
        storage = CacheScanner.deviceStorage()
    }
}
