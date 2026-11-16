// 同集去重冒烟（审查 P1-⑭ 固化入库）——AGENTS 24「同一部剧的同一集只允许一条记录」
// 声称的 5 项断言此前只在排障会话里跑过（产物 out/library_check_v2…v10 已被
// .gitignore 忽略、源码不在仓库），承重逻辑无可跑回归。本文件即为那份冒烟。
//
// 编译（清单与 coretest 一致，把 main.swift 换成本文件；DramaCoverCache 桩见 coretest 说明）：
//   cd iOS/smoke && swiftc -O -o deduptest deduptest.swift \
//     ../SmartDownloader/Shared/DownloadModels.swift ../SmartDownloader/Shared/DramaModels.swift \
//     ../SmartDownloader/Shared/PlaybackProgress.swift ../SmartDownloader/Downloads/Downloader.swift \
//     ../SmartDownloader/Drama/DramaCache.swift ../SmartDownloader/Drama/DramaDatabase.swift \
//     ../SmartDownloader/Drama/DramaDetailData.swift ../SmartDownloader/Drama/EpisodeActionsStore.swift \
//     ../SmartDownloader/Drama/RecommendedDrama.swift <DramaCoverCache 桩> \
//     ../SmartDownloader/Infra/WebKitFetcher.swift
// 运行（SMARTDOWNLOADER_DIR 指向 fixture 根，DownloadEngine.downloadsDir 会重定向过去）：
//   SMARTDOWNLOADER_DIR="$PWD/out/dedup-fixture" ./deduptest
//
// 断言（与 conventions-browser-downloads.md「同集去重」验收口径一致）：
//   1. 同集双目录只列一条：磁盘造 第01集 + 第01集(1)，loadLibrary 每集号只收一条且选中无后缀目录
//   2. 播放目录与列表一致：两侧共用 preferredEpisodeFolder（无后缀优先，否则最新），
//      列表落点 == 规则判读（规则漂移立即在这里炸）
//   3. 重试摘旧：registerEpisode 摘掉旧的失败尝试；重试已下载集不夺走能播的那份
//   4. 落盘后只留一条：keeper 为 done 时摘掉同集其余已结束记录（含 done）
//   5. 散装不去重：顶层散装目录各自成条（去重只按「剧名+集号」收口）
//
// 注：多文件 swiftc 只允许 main.swift 写顶层语句，故入口用 @main 包装。

import Foundation

@main
struct DedupTest {

    static var failedCount = 0

    static func check(_ name: String, _ ok: Bool, _ detail: String = "") {
        if ok {
            print("PASS  \(name)")
        } else {
            failedCount += 1
            print("FAIL  \(name)\(detail.isEmpty ? "" : "  [\(detail)]")")
        }
    }

    static func main() {
        let fm = FileManager.default
        let root = DownloadEngine.downloadsDir   // SMARTDOWNLOADER_DIR 重定向（fixture 根）
        try? fm.removeItem(at: root)             // 幂等：上一次运行的残留清掉

        /// 造一个「含 playlist.m3u8 的集目录」
        func makeEpisodeDir(_ path: String) {
            let dir = root.appendingPathComponent(path, isDirectory: true)
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            fm.createFile(atPath: dir.appendingPathComponent("playlist.m3u8").path, contents: Data("#EXTM3U\n".utf8))
        }

        // fixture：同集双目录（第01集 无后缀 + 第01集(1) 重下后缀）+ 两个散装目录
        makeEpisodeDir("去重样张/第01集")
        makeEpisodeDir("去重样张/第01集(1)")
        makeEpisodeDir("散装A")
        makeEpisodeDir("散装B")

        // DownloadManager.init() 里就跑 loadLibrary 扫盘，fixture 必须先就位
        let manager = DownloadManager()

        // ── 断言 1：同集双目录只列一条 ──
        let seriesTasks = manager.tasks.filter { $0.seriesName == "去重样张" }
        check("1a 同集双目录只列一条", seriesTasks.count == 1,
              "实际 \(seriesTasks.count) 条：\(seriesTasks.map { "\($0.title)(\($0.state))" })")
        let libraryRow = seriesTasks.first
        check("1b 选中无后缀目录", libraryRow?.outputURL?.path.hasSuffix("去重样张/第01集/playlist.m3u8") == true,
              "实际 \(libraryRow?.outputURL?.path ?? "nil")")

        // ── 断言 2：播放目录与列表一致（preferredEpisodeFolder 是列表/播放两侧共用规则）──
        let ep1 = root.appendingPathComponent("去重样张/第01集", isDirectory: true)
        let ep1Dup = root.appendingPathComponent("去重样张/第01集(1)", isDirectory: true)
        let preferred = DownloadManager.preferredEpisodeFolder([ep1Dup, ep1], sort: 1)
        check("2a 规则判读选无后缀", preferred?.lastPathComponent == "第01集",
              "实际 \(preferred?.lastPathComponent ?? "nil")")
        check("2b 列表落点 == 规则判读",
              libraryRow?.outputURL?.deletingLastPathComponent() == preferred,
              "列表 \(libraryRow?.outputURL?.deletingLastPathComponent().lastPathComponent ?? "nil") vs 规则 \(preferred?.lastPathComponent ?? "nil")")

        // ── 断言 3：重试摘旧 ──
        // 3a 旧的失败尝试被摘掉：手工登记一条 failed 的 第03集，再 registerEpisode 同名重试
        let oldFailed = DownloadTask(url: "", title: "第03集", seriesName: "去重样张")
        oldFailed.state = .failed("冒烟模拟失败")
        manager.register(oldFailed)
        _ = manager.registerEpisode(title: "第03集", seriesName: "去重样张")
        let sort3Rows = manager.tasks.filter { $0.seriesName == "去重样张" && $0.title == "第03集" }
        check("3a 重试后 第03集 只剩一条且为等待中",
              sort3Rows.count == 1 && sort3Rows.first?.state == .waiting,
              "实际 \(sort3Rows.count) 条：\(sort3Rows.map { "\($0.state)" })")

        // 3b 重试已下载集不夺走能播的那份：keeper 未 done 时 done 的库条目必须活着
        _ = manager.registerEpisode(title: "第01集", seriesName: "去重样张")
        let sort1Rows = manager.tasks.filter { $0.seriesName == "去重样张" && $0.title == "第01集" }
        check("3b 重试已下载集：done 库条目保留 + 新等待条目就位",
              sort1Rows.count == 2
                  && sort1Rows.filter { $0.state == .done }.count == 1
                  && sort1Rows.filter { $0.state == .waiting }.count == 1,
              "实际 \(sort1Rows.map { "\($0.title)(\($0.state))" })")

        // ── 断言 4：落盘后只留一条（keeper done 摘掉同集其余已结束记录，含 done）──
        let oldDone = DownloadTask(url: "", title: "第04集", seriesName: "去重样张")
        oldDone.state = .done
        oldDone.outputURL = root.appendingPathComponent("去重样张/第04集/playlist.m3u8")
        let anotherFailed = DownloadTask(url: "", title: "第04集", seriesName: "去重样张")
        anotherFailed.state = .failed("冒烟模拟失败")
        let newDone = DownloadTask(url: "", title: "第04集", seriesName: "去重样张")
        newDone.state = .done
        newDone.outputURL = root.appendingPathComponent("去重样张/第04集/playlist.m3u8")
        manager.register(oldDone)
        manager.register(anotherFailed)
        manager.register(newDone)
        // 模拟落盘成功的收尾路径：新任务 done 后摘同集旧尝试
        manager.pruneSupersededAttempts(series: "去重样张", sort: 4, keeper: newDone)
        let sort4Rows = manager.tasks.filter { $0.seriesName == "去重样张" && $0.title == "第04集" }
        check("4 落盘后同集只留 keeper 一条",
              sort4Rows.count == 1 && sort4Rows.first?.id == newDone.id,
              "实际 \(sort4Rows.count) 条：\(sort4Rows.map { "\($0.state)" })")

        // ── 断言 5：散装不去重 ──
        let standalone = manager.tasks.filter { $0.seriesName == nil }
        check("5 散装目录各自成条",
              standalone.count == 2 && Set(standalone.map(\.title)) == Set(["散装A", "散装B"]),
              "实际 \(standalone.map(\.title))")

        if failedCount == 0 {
            print("DEDUPTEST PASS 5/5")
        } else {
            print("DEDUPTEST FAIL \(failedCount) 项")
            exit(1)
        }
    }
}
