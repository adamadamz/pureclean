import SwiftUI
import Photos

// MARK: - 扫描进度

struct ScanProgressView: View {
    @EnvironmentObject var l10n: L10n
    let progress: Double

    var body: some View {
        VStack(spacing: 24) {
            Spacer()
            ZStack {
                Circle().stroke(Theme.card, lineWidth: 10).frame(width: 160, height: 160)
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Theme.accent, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .frame(width: 160, height: 160)
                Text("\(Int(progress * 100))%")
                    .font(.system(size: 32, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
            }
            Text(l10n.t("scan.running"))
                .foregroundStyle(Theme.textSecondary)
            Text(l10n.t("scan.local"))
                .font(.caption)
                .foregroundStyle(Theme.accent)
            Spacer()
        }
        .padding(20)
    }
}

// MARK: - 预览（扫描结果 → 勾选 → 一键清理）

struct PreviewView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var store: StoreManager
    @EnvironmentObject var l10n: L10n
    @State private var showPaywall = false
    @State private var showCleanConfirm = false

    private var totalSelected: Int64 { appState.junkSelectedBytes + appState.assetSelectedBytes }
    private var totalSelectedCount: Int {
        appState.selectedAssetIDs.count + appState.selectedJunkIDs.count
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    junkSection
                    if appState.photoDenied {
                        Text(l10n.t("preview.photoDenied"))
                            .font(.footnote).foregroundStyle(Theme.danger)
                            .frame(maxWidth: .infinity, alignment: .leading).card()
                    } else {
                        duplicatesSection
                        assetSection(title: l10n.t("preview.screenshots"),
                                     assets: appState.photoResult.screenshots)
                        assetSection(title: l10n.t("preview.largeVideos"),
                                     assets: appState.photoResult.largeVideos)
                    }
                }
                .padding(16)
            }
            .background(Theme.bg)
            .navigationTitle(l10n.t("preview.title"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(l10n.t("common.back")) { appState.reset() }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 8) {
                    Text(l10n.t("preview.recoverNote"))
                        .font(.caption2).foregroundStyle(Theme.textSecondary)
                    Button(l10n.t("preview.clean", formatBytes(totalSelected))) {
                        // 全流程只确认一次：
                        // - 含照片：系统删除框（批量一次性，显示张数）即是二次确认，
                        //   且为 Apple 强制、不可绕过，再叠加自家弹窗属重复确认
                        // - 仅沙盒文件：系统不弹框，用自家确认弹窗兜底
                        if appState.selectedAssetIDs.isEmpty {
                            showCleanConfirm = true
                        } else {
                            Task { await appState.clean() }
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle(enabled: totalSelected > 0))
                    .disabled(totalSelected == 0)
                }
                .padding(16)
                .background(Theme.bg)
            }
        }
        .sheet(isPresented: $showPaywall) { PaywallView() }
        .fullScreenCover(item: $appState.previewItem) { item in
            PhotoViewerView(asset: item.asset)
        }
        // 二次确认：汇总数量与体积，明示可恢复路径；照片删除后还有系统确认框兜底
        .alert(l10n.t("confirm.title"), isPresented: $showCleanConfirm) {
            Button(l10n.t("confirm.ok"), role: .destructive) {
                Task { await appState.clean() }
            }
            Button(l10n.t("common.cancel"), role: .cancel) {}
        } message: {
            Text(l10n.t("confirm.message", totalSelectedCount, formatBytes(totalSelected)))
        }
    }

    private var junkSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(l10n.t("preview.junk")).font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(formatBytes(appState.junkItems.reduce(0) { $0 + $1.size }))
                    .font(.subheadline).foregroundStyle(Theme.accent)
            }
            Text(l10n.t("preview.junk.note"))
                .font(.caption).foregroundStyle(Theme.textSecondary)
        }
        .card()
    }

    private var duplicatesSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(l10n.t("preview.duplicates")).font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                // 批量全选 = Pro 功能
                Button(l10n.t(selectAllKey)) {
                    guard store.isPro else { showPaywall = true; return }
                    // 状态切换：全选 ↔ 取消勾选
                    if appState.allRedundantSelected { appState.deselectAllRedundant() }
                    else { appState.selectAllRedundant() }
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
                .font(.caption.weight(.semibold)).foregroundStyle(Theme.accent)
            }
            Text(l10n.t("preview.hint"))
                .font(.caption2).foregroundStyle(Theme.textSecondary)
            if appState.photoResult.duplicateGroups.isEmpty {
                Text(l10n.t("preview.none")).font(.caption).foregroundStyle(Theme.textSecondary)
            }
            // 诚实告知：仅存 iCloud 的照片因纯本地模式（不联网）未参与识别
            if appState.photoResult.skippedCount > 0 {
                Label(l10n.t("preview.icloudSkipped", appState.photoResult.skippedCount),
                      systemImage: "icloud")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
            }
            ForEach(appState.photoResult.duplicateGroups.prefix(50)) { group in
                DuplicateGroupRow(group: group)
            }
            if appState.photoResult.duplicateGroups.count > 50 {
                Text(l10n.t("preview.showingFirst", 50))
                    .font(.caption).foregroundStyle(Theme.textSecondary)
            }
            if !store.isPro {
                Button(l10n.t("preview.deepHint")) { showPaywall = true }
                    .font(.caption).foregroundStyle(Theme.accent)
            }
        }
        .card()
    }

    private func assetSection(title: String, assets: [PHAsset]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("\(assets.count)").font(.subheadline).foregroundStyle(Theme.textSecondary)
            }
            if assets.isEmpty {
                Text(l10n.t("preview.none")).font(.caption).foregroundStyle(Theme.textSecondary)
            } else {
                // 每行 3 张：参考系统相册的触控规格，单格 ~104pt，远大于 44pt 最低标准
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                    ForEach(assets.prefix(40), id: \.localIdentifier) { asset in
                        SelectableThumb(asset: asset)
                    }
                }
                if assets.count > 40 {
                    Text(l10n.t("preview.showingFirst", 40))
                        .font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .card()
    }

    /// 全选按钮文案：免费版带 Pro 标 / 已全选时切换为「取消勾选」
    private var selectAllKey: String {
        guard store.isPro else { return "preview.selectAll.pro" }
        return appState.allRedundantSelected ? "preview.deselectAll" : "preview.selectAll"
    }
}

/// 一组重复照片：横向缩略图，保留项标绿
struct DuplicateGroupRow: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var l10n: L10n
    let group: DuplicateGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(l10n.t(group.isSimilar ? "preview.similarGroup" : "preview.dupGroup",
                            group.assets.count))
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                Spacer()
                Text(formatBytes(group.wastedBytes)).font(.caption).foregroundStyle(Theme.accent)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(group.assets, id: \.localIdentifier) { asset in
                        // 所有组（精确重复 + 相似）统一锁定保留项：置灰、不可勾选
                        SelectableThumb(asset: asset,
                                        isKeeper: asset.localIdentifier == group.keepLocalID,
                                        size: 104)
                    }
                }
            }
        }
    }
}

/// 可勾选缩略图（保留项带绿色「保留」角标，不可勾选误删）。
/// 交互要点：必须用 Button 而非 onTapGesture——在 ScrollView/LazyVGrid 中
/// onTapGesture 与滚动手势竞争，点击经常被吞掉（「勾选不灵敏」的根因）。
struct SelectableThumb: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var l10n: L10n
    let asset: PHAsset
    var isKeeper = false
    var size: CGFloat? = nil    // nil = 自适应网格列宽；横滑行传固定值
    @State private var image: UIImage?
    @State private var loadFailed = false   // iCloud 仅云端 / 损坏：显示占位图标

    private var selected: Bool { appState.selectedAssetIDs.contains(asset.localIdentifier) }

    var body: some View {
        Button(action: toggle) {
            ZStack(alignment: .topTrailing) {
                Color.clear
                    .aspectRatio(1, contentMode: .fit)
                    .overlay(thumbContent)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(selected ? Theme.accent : .clear, lineWidth: 2))
                    // 保留项置灰：明确传达「这张不可选，将被保留」
                    .saturation(isKeeper ? 0.3 : 1)
                    .opacity(isKeeper ? 0.55 : 1)

                if isKeeper {
                    Text(l10n.t("preview.keep"))
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Capsule().fill(Theme.accent))
                        .foregroundStyle(.black)
                        .padding(5)
                } else if !loadFailed {
                    // 安全底线：缩略图不可见的照片不显示勾选框，杜绝盲删
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 24))
                        .foregroundStyle(selected ? Theme.accent : .white.opacity(0.75))
                        .shadow(color: .black.opacity(0.4), radius: 2)
                        .padding(6)
                }
            }
        }
        .buttonStyle(.plain)
        .frame(width: size)
        // 长按 = 全屏看大图（对齐相册习惯）；轻点 = 勾选，互不冲突
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.35).onEnded { _ in
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                appState.previewItem = PreviewItem(asset: asset)
            })
        .task {
            // .opportunistic：iCloud 优化存储的资产返回本地降质缩略图（与系统相册一致），
            // 而 .fastFormat 会直接报 3303 失败——这是「开 iCloud 就看不到缩略图」的根因
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = false
            image = await withCheckedContinuation { continuation in
                var resumed = false
                PHImageManager.default().requestImage(
                    for: asset, targetSize: CGSize(width: 256, height: 256),   // 104pt@3x 需 ≥312px，留余量防糊
                    contentMode: .aspectFill, options: options
                ) { img, info in
                    guard !resumed else { return }
                    let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                    if img != nil {
                        resumed = true
                        continuation.resume(returning: img)   // 第一张可用图（含降质）即显示
                    } else if !degraded {
                        resumed = true
                        continuation.resume(returning: nil)   // 最终回调仍无图：真正不可用
                    }
                }
            }
            if image == nil {
                loadFailed = true
                // 已被勾选（手动点过/批量全选）的不可见照片强制移出勾选，绝不盲删
                appState.selectedAssetIDs.remove(asset.localIdentifier)
            }
        }
    }

    private var thumbContent: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    Theme.card
                    Image(systemName: loadFailed ? "icloud" : "photo")
                        .font(.system(size: 24))
                        .foregroundStyle(Theme.textSecondary.opacity(0.5))
                }
            }
        }
    }

    private func toggle() {
        // 保留项与不可见照片（iCloud 仅云端）均禁止勾选
        guard !isKeeper, !loadFailed else { return }
        // 统一走 AppState 守卫路径：组内最后一张未勾选的会被拦截
        if appState.toggleAssetSelection(asset) {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } else {
            UINotificationFeedbackGenerator().notificationOccurred(.warning)   // 底线拦截：必须留一张
        }
    }
}

// MARK: - 全屏大图预览（长按缩略图进入，删前可查看）

struct PhotoViewerView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var l10n: L10n
    @Environment(\.dismiss) private var dismiss
    let asset: PHAsset
    @State private var image: UIImage?
    @State private var isHighQuality = false          // 已拿到非降质原图
    @State private var cloudProgress: Double?          // nil = 未在下载
    @State private var cloudFailed = false

    // 缩放/平移状态（对齐系统相册：捏合缩放、放大后可拖移、双击切换）
    @State private var zoom: CGFloat = 1
    @State private var steadyZoom: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var steadyOffset: CGSize = .zero

    private var selected: Bool { appState.selectedAssetIDs.contains(asset.localIdentifier) }
    /// 任何组（精确重复/相似）的保留项在大图页同样不可勾选（防误删最后一张）
    private var isKeeper: Bool {
        appState.photoResult.duplicateGroups.contains {
            $0.keepLocalID == asset.localIdentifier
        }
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .scaleEffect(zoom)
                    .offset(offset)
                    .ignoresSafeArea(edges: .horizontal)
                    .gesture(zoomAndPanGesture)
                    .onTapGesture(count: 2) { toggleDoubleTapZoom() }
                    .animation(.easeOut(duration: 0.15), value: zoom)
            } else {
                ProgressView().tint(.white)
            }

            VStack {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 32))
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
                .padding(16)

                Spacer()

                // 高清未就绪（原图在 iCloud）：提供用户主动触发的单张下载。
                // 隐私边界：仅下行（从用户自己的 iCloud 取自己的照片），绝不上传；
                // 默认纯本地，联网只发生在用户明确点击这一刻、仅此一张。
                if !isHighQuality {
                    if let progress = cloudProgress {
                        VStack(spacing: 6) {
                            ProgressView(value: progress)
                                .tint(Theme.accent)
                                .frame(width: 180)
                            Text(l10n.t("viewer.downloading"))
                                .font(.caption).foregroundStyle(.white.opacity(0.7))
                        }
                        .padding(.bottom, 12)
                    } else {
                        Button {
                            downloadHD()
                        } label: {
                            Label(l10n.t("viewer.loadHD"), systemImage: "icloud.and.arrow.down")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(Theme.accent)
                                .padding(.horizontal, 14).padding(.vertical, 8)
                                .background(Capsule().fill(.white.opacity(0.12)))
                        }
                        .padding(.bottom, 8)
                        if cloudFailed {
                            Text(l10n.t("viewer.loadFailed"))
                                .font(.caption2).foregroundStyle(Theme.danger)
                                .padding(.bottom, 8)
                        }
                    }
                }

                if isKeeper {
                    Text(l10n.t("preview.keep"))
                        .font(.footnote.weight(.bold))
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(Capsule().fill(Theme.accent))
                        .foregroundStyle(.black)
                        .padding(.bottom, 24)
                } else {
                    Button {
                        // 大图页同样走守卫路径，底线规则全入口一致
                        if appState.toggleAssetSelection(asset) {
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        } else {
                            UINotificationFeedbackGenerator().notificationOccurred(.warning)
                        }
                    } label: {
                        Label(l10n.t(selected ? "viewer.deselect" : "viewer.select"),
                              systemImage: selected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(selected ? Color.black : Theme.textPrimary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 15)
                            .background(
                                RoundedRectangle(cornerRadius: Theme.corner)
                                    .fill(selected ? Theme.accent : Theme.card))
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                }
            }
        }
        .task { loadFullImage() }
    }

    /// 捏合缩放（1x–6x）+ 放大后拖移；缩回 1x 自动回正
    private var zoomAndPanGesture: some Gesture {
        let magnify = MagnificationGesture()
            .onChanged { value in
                zoom = min(max(steadyZoom * value, 1), 6)
            }
            .onEnded { _ in
                steadyZoom = zoom
                if zoom <= 1 { resetZoom() }
            }
        let pan = DragGesture()
            .onChanged { value in
                guard zoom > 1 else { return }   // 未放大时不拦截（保留系统手势）
                offset = CGSize(width: steadyOffset.width + value.translation.width,
                                height: steadyOffset.height + value.translation.height)
            }
            .onEnded { _ in steadyOffset = offset }
        return magnify.simultaneously(with: pan)
    }

    /// 双击：1x ↔ 2.5x（系统相册同款交互）
    private func toggleDoubleTapZoom() {
        if zoom > 1 {
            resetZoom()
        } else {
            zoom = 2.5
            steadyZoom = 2.5
        }
    }

    private func resetZoom() {
        zoom = 1
        steadyZoom = 1
        offset = .zero
        steadyOffset = .zero
    }

    /// 渐进加载：本地降质图先显示，本机有高清则随后替换；此阶段禁网
    private func loadFullImage() {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.isNetworkAccessAllowed = false
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: 1600, height: 1600),
            contentMode: .aspectFit,
            options: options
        ) { img, info in
            let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
            if let img {
                self.image = img            // 两次回调依次更新：降质 → 高清
                if !degraded { self.isHighQuality = true }
            }
        }
    }

    /// 用户主动触发：从其本人的 iCloud 下载这一张的高清图（仅下行，绝不上传）
    private func downloadHD() {
        cloudFailed = false
        cloudProgress = 0
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = true   // 唯一允许联网的代码路径：用户点击、单张、官方 Photos 通道
        options.progressHandler = { progress, _, _, _ in
            DispatchQueue.main.async { cloudProgress = progress }
        }
        PHImageManager.default().requestImage(
            for: asset,
            targetSize: CGSize(width: 2400, height: 2400),   // 支撑 6x 缩放清晰度；不取全尺寸防内存峰值
            contentMode: .aspectFit,
            options: options
        ) { img, _ in
            DispatchQueue.main.async {
                cloudProgress = nil
                if let img {
                    image = img
                    isHighQuality = true
                } else {
                    cloudFailed = true       // 断网/iCloud 异常：如实提示，可重试
                }
            }
        }
    }
}

// MARK: - 清理中 / 结果

struct CleaningView: View {
    @EnvironmentObject var l10n: L10n
    var body: some View {
        VStack(spacing: 16) {
            ProgressView().controlSize(.large).tint(Theme.accent)
            Text(l10n.t("clean.running")).foregroundStyle(Theme.textSecondary)
        }
    }
}

struct ResultView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var l10n: L10n
    let freedBytes: Int64

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64))
                .foregroundStyle(Theme.accent)
            Text(l10n.t("result.title"))
                .font(.title2.weight(.bold)).foregroundStyle(Theme.textPrimary)
            Text(l10n.t("result.freed", formatBytes(freedBytes)))
                .foregroundStyle(Theme.textSecondary)
            if appState.photoDeleteFailed {
                Text(l10n.t("result.photoFailed"))
                    .font(.footnote).foregroundStyle(Theme.danger)
                    .multilineTextAlignment(.center)
            } else {
                Text(l10n.t("result.recover"))
                    .font(.caption).foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
            Button(l10n.t("common.done")) { appState.reset() }
                .buttonStyle(PrimaryButtonStyle())
        }
        .padding(20)
    }
}
