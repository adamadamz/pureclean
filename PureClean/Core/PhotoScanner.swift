import Photos
import UIKit

/// 一组重复/相似照片。`keepLocalID` 为建议保留项（分辨率最高/文件最大）。
struct DuplicateGroup: Identifiable {
    let id = UUID()
    var assets: [PHAsset]
    var keepLocalID: String
    var wastedBytes: Int64        // 删除非保留项可释放的字节数
    var isSimilar: Bool           // false=精确重复 true=相似（Pro）
}

struct PhotoScanResult {
    var duplicateGroups: [DuplicateGroup] = []
    var screenshots: [PHAsset] = []
    var largeVideos: [PHAsset] = []
    var screenshotBytes: Int64 = 0
    var largeVideoBytes: Int64 = 0
    var scannedCount: Int = 0
    /// 仅存于 iCloud（本机无缩略图）被跳过的照片数 —— UI 须如实告知
    var skippedCount: Int = 0
    /// 文件体积缓存 [localIdentifier: bytes]。
    /// 性能关键：PHAssetResource 体积查询是同步磁盘 IO，必须在扫描阶段（后台）
    /// 一次性算好；UI 层（金额汇总等）只允许查这个字典，严禁直接调 estimatedFileSize，
    /// 否则主线程每帧多次磁盘查询会造成秒级挂起（Hang detected）。
    var sizeByID: [String: Int64] = [:]
}

/// 照片库本地扫描器。
/// 性能策略（目标：1 万张 ≤ 8 秒，内存 ≤ 18MB）：
/// - 64×64 fastFormat 缩略图 + dHash，单张图开销 < 5ms
/// - 16 路受限并发，缩略图即用即弃，不持有任何全尺寸图像
/// - 禁止 iCloud 网络拉取（isNetworkAccessAllowed = false），纯本地
final class PhotoScanner {

    static let largeVideoMinBytes: Int64 = 100 * 1024 * 1024  // ≥100MB 算大视频

    /// 请求照片库读写权限（删除需要 .readWrite）
    static func requestAuthorization() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    /// 主扫描入口。`deepScan`（Pro）开启相似照片检测；progress 0...1 回调在主线程。
    func scan(deepScan: Bool, progress: @escaping @MainActor (Double) -> Void) async -> PhotoScanResult {
        var result = PhotoScanResult()

        // 1. 截图与大视频：直接由元数据筛选，O(n) 且无需解码
        let screenshotOptions = PHFetchOptions()
        screenshotOptions.predicate = NSPredicate(
            format: "(mediaSubtypes & %d) != 0", PHAssetMediaSubtype.photoScreenshot.rawValue)
        let screenshotFetch = PHAsset.fetchAssets(with: .image, options: screenshotOptions)
        screenshotFetch.enumerateObjects { asset, _, _ in
            let size = asset.estimatedFileSize          // 后台线程，一次性
            result.screenshots.append(asset)
            result.screenshotBytes += size
            result.sizeByID[asset.localIdentifier] = size
        }

        let videoFetch = PHAsset.fetchAssets(with: .video, options: nil)
        videoFetch.enumerateObjects { asset, _, _ in
            let size = asset.estimatedFileSize
            if size >= Self.largeVideoMinBytes {
                result.largeVideos.append(asset)
                result.largeVideoBytes += size
                result.sizeByID[asset.localIdentifier] = size
            }
        }

        // 2. 全量图片 dHash（按拍摄时间排序，相似检测只比对时间邻近窗口）
        let imageOptions = PHFetchOptions()
        imageOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        let imageFetch = PHAsset.fetchAssets(with: .image, options: imageOptions)
        let total = imageFetch.count
        result.scannedCount = total
        guard total > 0 else { return result }

        var assets: [PHAsset] = []
        assets.reserveCapacity(total)
        imageFetch.enumerateObjects { asset, _, _ in assets.append(asset) }

        struct Entry { let index: Int; let asset: PHAsset; let hash: UInt64 }
        var entries: [Entry] = []
        entries.reserveCapacity(total)

        let manager = PHImageManager.default()
        let batchSize = 16  // 受限并发：控制峰值内存
        var done = 0

        for batchStart in stride(from: 0, to: total, by: batchSize) {
            let batch = Array(assets[batchStart..<min(batchStart + batchSize, total)])
            let hashed: [Entry] = await withTaskGroup(of: Entry?.self) { group in
                for (offset, asset) in batch.enumerated() {
                    group.addTask {
                        guard let cg = await Self.thumbnail(for: asset, manager: manager),
                              let hash = PerceptualHash.dHash(cg) else { return nil }
                        return Entry(index: batchStart + offset, asset: asset, hash: hash)
                    }
                }
                var collected: [Entry] = []
                for await entry in group where entry != nil { collected.append(entry!) }
                return collected
            }
            entries.append(contentsOf: hashed)
            done += batch.count
            let fraction = Double(done) / Double(total)
            await progress(fraction)
        }

        // 3. 分组：并查集，精确重复（距离 0）始终启用；相似（距离 ≤ 阈值）仅 deepScan
        // 边界：iCloud 优化存储 + 禁网时本机可能无缩略图，被跳过的数量如实记录
        result.skippedCount = total - entries.count
        guard entries.count > 1 else { return result }
        entries.sort { $0.index < $1.index }
        var parent = Array(0..<entries.count)
        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }
            return x
        }
        func union(_ a: Int, _ b: Int) { parent[find(a)] = find(b) }

        // 精确重复：哈希桶，全库范围
        var buckets: [UInt64: [Int]] = [:]
        for (i, e) in entries.enumerated() { buckets[e.hash, default: []].append(i) }
        for indices in buckets.values where indices.count > 1 {
            for i in indices.dropFirst() { union(indices[0], i) }
        }

        // 相似：仅与时间序前 8 张比对（连拍场景），O(8n)
        if deepScan {
            let window = 8
            for i in 1..<entries.count {
                for j in max(0, i - window)..<i {
                    if PerceptualHash.hamming(entries[i].hash, entries[j].hash) <= PerceptualHash.similarThreshold {
                        union(i, j)
                        break
                    }
                }
            }
        }

        var groupsByRoot: [Int: [Entry]] = [:]
        for (i, e) in entries.enumerated() { groupsByRoot[find(i), default: []].append(e) }

        for members in groupsByRoot.values where members.count > 1 {
            let sorted = members.sorted {
                ($0.asset.pixelWidth * $0.asset.pixelHeight) > ($1.asset.pixelWidth * $1.asset.pixelHeight)
            }
            // 组内全员体积入缓存（含保留项），UI 金额汇总只查字典零 IO
            for entry in sorted {
                if result.sizeByID[entry.asset.localIdentifier] == nil {
                    result.sizeByID[entry.asset.localIdentifier] = entry.asset.estimatedFileSize
                }
            }
            let keep = sorted[0].asset
            let wasted = sorted.dropFirst().reduce(Int64(0)) {
                $0 + (result.sizeByID[$1.asset.localIdentifier] ?? 0)
            }
            let isSimilar = members.contains {
                PerceptualHash.hamming($0.hash, members[0].hash) != 0
            }
            result.duplicateGroups.append(DuplicateGroup(
                assets: sorted.map(\.asset),
                keepLocalID: keep.localIdentifier,
                wastedBytes: wasted,
                isSimilar: isSimilar))
        }
        result.duplicateGroups.sort { $0.wastedBytes > $1.wastedBytes }
        return result
    }

    /// 64×64 快速缩略图，禁网络、即用即弃。
    /// 关键：必须用 .opportunistic 而非 .fastFormat——
    /// 「优化 iPhone 储存空间」开启时原图在 iCloud，但本机始终保留小缩略图；
    /// .fastFormat 对此类资产会报 3303 而不回退，.opportunistic 才会返回本地降质图
    /// （与系统相册网格的加载行为一致）。降质小图对 9×8 dHash 完全够用。
    private static func thumbnail(for asset: PHAsset, manager: PHImageManager) async -> CGImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = false   // 纯本地承诺：绝不触网
            options.isSynchronous = false
            var resumed = false
            manager.requestImage(
                for: asset,
                targetSize: CGSize(width: 64, height: 64),
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                guard !resumed else { return }
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                if let cg = image?.cgImage {
                    // 第一张可用图（含降质）即取走，不等最终回调
                    resumed = true
                    continuation.resume(returning: cg)
                } else if !degraded {
                    // 最终回调仍无图：本机确实没有任何可用资源，跳过该资产
                    resumed = true
                    continuation.resume(returning: nil)
                }
                // degraded 且无图：中间回调，继续等待最终回调
            }
        }
    }
}

extension PHAsset {
    /// 本地估算文件大小：优先读资源 fileSize，失败则按像素估算
    var estimatedFileSize: Int64 {
        if let resource = PHAssetResource.assetResources(for: self).first,
           let size = resource.value(forKey: "fileSize") as? Int64, size > 0 {
            return size
        }
        if mediaType == .video {
            return Int64(duration * 2_000_000)            // ~16Mbps 估算
        }
        return Int64(Double(pixelWidth * pixelHeight) * 0.4) // JPEG 估算
    }
}
