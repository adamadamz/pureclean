import CoreGraphics
import Foundation

/// 感知哈希（dHash）：将图片降采样为 9×8 灰度图，按相邻像素亮度差生成 64 位指纹。
/// - 汉明距离 0          → 视觉完全相同（精确重复）
/// - 汉明距离 ≤ similarThreshold → 视觉相似（连拍/微调，Pro 深度扫描）
/// 全程 CoreGraphics 本地计算，零网络。单张耗时 < 0.5ms。
enum PerceptualHash {

    static let similarThreshold = 10

    /// 计算 64 位 dHash。失败返回 nil（损坏图等），调用方应跳过该资产。
    static func dHash(_ image: CGImage) -> UInt64? {
        let w = 9, h = 8
        var pixels = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(
            data: &pixels,
            width: w, height: h,
            bitsPerComponent: 8,
            bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }

        ctx.interpolationQuality = .low
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        var hash: UInt64 = 0
        for y in 0..<h {
            for x in 0..<(w - 1) {
                hash <<= 1
                if pixels[y * w + x] > pixels[y * w + x + 1] { hash |= 1 }
            }
        }
        return hash
    }

    @inline(__always)
    static func hamming(_ a: UInt64, _ b: UInt64) -> Int {
        (a ^ b).nonzeroBitCount
    }
}
