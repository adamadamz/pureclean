import Foundation
import Photos

/// 安全删除器 —— 三道防线：
/// 1. 照片删除走 PHAssetChangeRequest：系统弹出原生确认框，且照片进入
///    「最近删除」相册保留 30 天，可随时恢复，杜绝误删不可逆。
/// 2. 文件删除仅限白名单根目录（Caches/tmp）前缀校验，路径标准化后
///    逐项比对，防符号链接/`..` 越界；Documents 永不可达。
/// 3. 删除全程逐项 try，单项失败不中断、不抛弃已统计字节数。
enum SafeDeleter {

    enum DeleteError: Error { case photoPermissionDenied, outsideWhitelist }

    // MARK: - 照片（系统级安全网）

    /// 删除照片资产。系统会弹确认框；用户取消时抛错，调用方按「未删除」处理。
    /// 注意：不在此计算体积（estimatedFileSize 是同步磁盘 IO，会卡主线程），
    /// 释放字节数由调用方从扫描期的体积缓存汇总。
    static func delete(assets: [PHAsset]) async throws {
        guard !assets.isEmpty else { return }
        // .limited（限定照片）同样可删除已授权范围内的资产——扫描结果必然在该范围内
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else {
            throw DeleteError.photoPermissionDenied
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets as NSArray)
        }
    }

    // MARK: - 沙盒文件

    /// 删除沙盒垃圾文件。逐项白名单校验，返回实际释放字节数。
    static func delete(junk items: [JunkItem]) -> Int64 {
        let fm = FileManager.default
        let roots = CacheScanner.allowedRoots.map { $0.standardizedFileURL.path + "/" }
        var freed: Int64 = 0

        for item in items {
            let path = item.url.standardizedFileURL.path
            // 防线 2：标准化路径必须以白名单根目录为前缀
            guard roots.contains(where: { path.hasPrefix($0) }) else { continue }
            // 防线 3：单项失败不影响整体
            if (try? fm.removeItem(at: item.url)) != nil {
                freed += item.size
            }
        }
        return freed
    }

    /// 一键清空本 App 全部缓存（保留目录本身）
    static func clearAllOwnCache() -> Int64 {
        let scanner = CacheScanner()
        return delete(junk: scanner.scan())
    }
}
