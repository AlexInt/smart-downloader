import Foundation
import CryptoKit
import UIKit

// MARK: - 剧集封面本地缓存（Service）
//
// 用户拍板（2026-11-13）：封面按剧集 id 缓存，不每次重新拉；拉取失败保留旧文件；
// 有效期 15 天（SDWebImage 语义的等价实现，不引入第三方依赖）。
//
// 设计：
// - 键 = (site, dramaID) 的 SHA256——按剧集 id 而不是 URL 键控：站点换图床 URL 也能命中；
// - 有效期按文件修改时间判定（写入即修改），过期文件顺手删除并允许重拉；
// - 存储放 Caches/DramaCovers（系统可回收空间；被清了就是重新拉一次，无一致性风险）；
// - 拉取用 URLSession 后台线程，写盘原子替换；解码校验避免把错误页缓存成图片。
// - 已知例外（真机实证）：本站图床 pic.* 下发的是密文（站点 JS 解密后转 blob 展示），
//   URLSession 直拉必 badData —— 解密后的图像数据由 DramaMetaHarvester 在隐藏 WebView
//   里（canvas 导出 JPEG）经 storeImageData 落盘，本类不负责解密；fetch() 仅作无
//   WebView 收割时的兕底（普通站点可直接命中）。
// 主线程约定：completion 固定回主线程；文件 IO 在 URLSession 回调线程。
final class DramaCoverCache {
    /// 缓存有效期：15 天（用户拍板 2026-11-13）
    static let maxAge: TimeInterval = 15 * 24 * 3600
    /// 缓存目录布局版本：**提取规则一改就必须递增**（v2 = 2026-11-15 主封面/推荐封面改按
    /// 「卡片归属 + 卡片文字」挑图）。旧目录里可能全是错配的图，而 `storeImageData` 有
    /// fresh-skip（存在就不重写），不换目录的话错图会一直用满 15 天。
    private static let layoutVersion = "v2"
    /// 旧布局清理只做一次（文件在各版本目录之外 = v1 遗留）
    private static var didCleanLegacyFiles = false

    private static var dir: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let root = caches.appendingPathComponent("DramaCovers", isDirectory: true)
        removeLegacyFiles(in: root)
        let dir = root.appendingPathComponent(layoutVersion, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 删掉根目录下散落的旧版本文件（v1 直接把 `<sha>.img` 放在 DramaCovers/ 里）。
    /// Caches 本来就可回收，这里只是别让错图白占几百 KB × N 部。
    private static func removeLegacyFiles(in root: URL) {
        guard !didCleanLegacyFiles else { return }
        didCleanLegacyFiles = true
        let items = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        var removed = 0
        for item in items {
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            guard !isDir else { continue }
            do {
                try FileManager.default.removeItem(at: item)
                removed += 1
            } catch {
                // 删不掉就算了：Caches 可回收，不阻断任何流程
            }
        }
        if removed > 0 {
            print("PLAYER_DBG [Entry] cover cache cleanup legacy v1 files=\(removed)")
        }
    }

    /// 稳定文件名：site#dramaID 的 SHA256（不能用 hashValue——跨启动不稳定）
    private static func fileName(site: String, dramaID: String) -> String {
        let digest = SHA256.hash(data: Data("\(site)#\(dramaID)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".img"
    }

    private static func fileURL(site: String, dramaID: String) -> URL {
        dir.appendingPathComponent(fileName(site: site, dramaID: dramaID))
    }

    /// 本地缓存文件的修改时间（封面被重新收割覆盖后要据此重建 AsyncImage）
    static func modifiedAt(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// 本地有效缓存（≤15 天）的文件 URL；过期文件顺手删除（下次 fetch 重新落盘）
    static func validLocalURL(site: String, dramaID: String) -> URL? {
        let url = fileURL(site: site, dramaID: dramaID)
        guard let attr = try? FileManager.default.attributesOfItem(atPath: url.path),
              let modified = attr[.modificationDate] as? Date else { return nil }
        guard Date().timeIntervalSince(modified) < maxAge else {
            try? FileManager.default.removeItem(at: url)
            print("PLAYER_DBG [Entry] cover cache EXPIRED id=\(dramaID) age=\(Int(Date().timeIntervalSince(modified) / 86400))d")
            return nil
        }
        return url
    }

    /// 拉取远程封面并落盘（原子替换）。失败回调 nil；已有旧文件保留不动（下次还能用）。
    static func fetch(site: String, dramaID: String, remote: URL, completion: @escaping (URL?) -> Void) {
        var request = URLRequest(url: remote)
        request.timeoutInterval = 15
        URLSession.shared.dataTask(with: request) { data, response, error in
            let httpOK = (response as? HTTPURLResponse)?.statusCode == 200
            // 解码校验：防止把 CDN/WAF 的错误页缓存成图片
            guard let data, data.count > 0, error == nil, httpOK,
                  UIImage(data: data) != nil else {
                print("PLAYER_DBG [Entry] cover cache FETCH FAIL id=\(dramaID) url=\(remote.absoluteString) err=\(error?.localizedDescription ?? (httpOK ? "badData" : "http\(String(describing: (response as? HTTPURLResponse)?.statusCode))"))")
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let target = fileURL(site: site, dramaID: dramaID)
            do {
                try data.write(to: target, options: .atomic)
                print("PLAYER_DBG [Entry] cover cache STORED id=\(dramaID) bytes=\(data.count)")
                DispatchQueue.main.async { completion(target) }
            } catch {
                print("PLAYER_DBG [Entry] cover cache WRITE FAIL id=\(dramaID) err=\(error.localizedDescription)")
                DispatchQueue.main.async { completion(nil) }
            }
        }.resume()
    }

    /// 收割 JS 已在站点 WebView 里解密好的封面（blob → canvas → dataURL）按剧集 id 落盘。
    /// 主线程调用（同步写，~几百 KB 原子替换）；与 fetch() 互不覆盖，过期逻辑共用。
    /// `overwrite`：允许覆盖已有文件。收割器按「一次收割写一次」自己节流，但**必须能覆盖**——
    /// 老的挑图规则存过错图，↻ 刷新若还被 fresh-skip 挡住，用户就只能等 15 天过期
    /// （用户 2026-11-15 实报错图的整条链路）。
    static func storeImageData(site: String, dramaID: String, data: Data, overwrite: Bool = false) {
        if !overwrite, validLocalURL(site: site, dramaID: dramaID) != nil {
            print("PLAYER_DBG [Entry] cover cache STORE SKIP reason=fresh id=\(dramaID)")
            return
        }
        guard UIImage(data: data) != nil else {
            print("PLAYER_DBG [Entry] cover cache HARVEST STORE FAIL id=\(dramaID) err=badData bytes=\(data.count)")
            return
        }
        let target = fileURL(site: site, dramaID: dramaID)
        do {
            try data.write(to: target, options: .atomic)
            print("PLAYER_DBG [Entry] cover cache STORED id=\(dramaID) bytes=\(data.count) via=harvest")
        } catch {
            print("PLAYER_DBG [Entry] cover cache WRITE FAIL id=\(dramaID) err=\(error.localizedDescription)")
        }
    }
}
