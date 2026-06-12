import Foundation

/// 可清理的垃圾项（全部位于本 App 沙盒内 —— iOS 沙盒隔离下，
/// 第三方 App 无法访问其他 App 的缓存；本功能如实只清理自身可达范围）。
struct JunkItem: Identifiable {
    enum Kind: String { case cache, tmp, log }
    let id = UUID()
    let url: URL
    let size: Int64
    let kind: Kind
    var name: String { url.lastPathComponent }
}

struct DeviceStorage {
    let totalBytes: Int64
    let availableBytes: Int64
    var usedBytes: Int64 { totalBytes - availableBytes }
    var usedFraction: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0 }
}

/// 沙盒垃圾扫描器：枚举 Caches / tmp，统计可安全删除的文件。
final class CacheScanner {

    /// 唯一允许清理的根目录白名单 —— 安全删除第一道防线。
    /// Documents、Library/Preferences 等用户数据目录永不入内。
    static var allowedRoots: [URL] {
        var roots: [URL] = [FileManager.default.temporaryDirectory]
        if let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first {
            roots.append(caches)
        }
        return roots
    }

    /// 扫描沙盒垃圾。轻量同步 IO，放到后台执行器调用。
    func scan() -> [JunkItem] {
        var items: [JunkItem] = []
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]

        for root in Self.allowedRoots {
            let kind: JunkItem.Kind = root == fm.temporaryDirectory ? .tmp : .cache
            guard let enumerator = fm.enumerator(
                at: root, includingPropertiesForKeys: keys,
                options: [.skipsPackageDescendants]) else { continue }

            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: Set(keys)),
                      values.isRegularFile == true else { continue }
                let size = Int64(values.totalFileAllocatedSize ?? 0)
                guard size > 0 else { continue }
                let itemKind: JunkItem.Kind = url.pathExtension == "log" ? .log : kind
                items.append(JunkItem(url: url, size: size, kind: itemKind))
            }
        }
        return items.sorted { $0.size > $1.size }
    }

    /// 设备整机存储概览（仅读取容量数字，不访问任何文件内容）
    static func deviceStorage() -> DeviceStorage {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let values = try? home.resourceValues(forKeys: [
            .volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey])
        return DeviceStorage(
            totalBytes: Int64(values?.volumeTotalCapacity ?? 0),
            availableBytes: values?.volumeAvailableCapacityForImportantUsage ?? 0)
    }
}
