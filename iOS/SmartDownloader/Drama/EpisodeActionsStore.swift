import Foundation
import SQLite3

// MARK: - 集级行为数据（SQLite）
//
// 「一集一行、列即行为」：点赞、收藏、上次播放位置，以及后续要加的行为字段都加在这张表上。
// 主表 episode_actions 以 (site, drama_id, episode_id) 为主键，与 drama_episodes 同一套身份，
// 因此可以直接 JOIN 出「这部剧看到哪一集」「哪些集被收藏」这类关系查询 ——
// 这就是不把行为数据散进 UserDefaults 的理由：分散存放建不起关系。
//
// 对不上服务端集 id 的资源（散装 HLS / 普通文件 / 磁盘收编的历史条目）走 local_actions，
// 主键是相对下载根目录的资源路径；两张表互不覆盖，读取侧按「先 id 后路径」兜底。
//
// 建表与迁移（含旧 UserDefaults 搬迁）统一在 Drama/DramaDatabase.swift，本文件只做行为数据读写。
// 写入只发生在关键时机（暂停 / 切集 / 退出播放页 / 进后台），沿用 DramaCache 的开-用-关写法，
// 不引入常驻连接。主线程约定：与 DramaCache 一致，全部调用 assume 主线程。


enum EpisodeActionsStore {

    /// 一集的行为数据快照：字段即表列，新增行为就加字段 + 加一次版本迁移。
    struct Actions: Equatable {
        var liked = false
        var saved = false
        var positionSeconds = 0.0
        var positionTotal = 0.0

        /// 播放进度；从未播放或时长未知时为 nil
        var position: PlaybackProgress? {
            positionTotal > 0 ? PlaybackProgress(seconds: positionSeconds, total: positionTotal) : nil
        }
    }

    private static let schemaVersion = 1
    /// 建表/迁移每进程只做一次（主线程约定，无需加锁）
    private static var migrated = false

    // MARK: 连接

    /// 建表与版本迁移统一由 DramaDatabase 负责：整库只有一个 user_version，
    /// 两个 Service 各管一段会互相跳过对方的建表，所以这里只负责开库。
    private static func openDB() -> OpaquePointer? { DramaDatabase.open() }


    // MARK: 读

    /// 单条读（播放侧用）：无记录返回默认值 —— 未点赞、未收藏、无进度
    static func actions(for identity: MediaIdentity) -> Actions {
        guard let db = openDB() else { return Actions() }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, selectSQL(for: identity), -1, &stmt, nil) == SQLITE_OK else {
            DramaDatabase.fail(db, "actions read"); return Actions()
        }
        defer { sqlite3_finalize(stmt) }
        bindKeys(identity, to: stmt)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return Actions() }
        return Actions(liked: sqlite3_column_int(stmt, 0) != 0,
                       saved: sqlite3_column_int(stmt, 1) != 0,
                       positionSeconds: sqlite3_column_double(stmt, 2),
                       positionTotal: sqlite3_column_double(stmt, 3))
    }

    /// 整部剧的行为数据（列表批量读，避免一行开一次库）：集 id → 行为
    static func episodeActions(site: String, dramaID: String) -> [Int: Actions] {
        guard let db = openDB() else { return [:] }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = """
        SELECT episode_id, liked, saved, position_seconds, position_total
        FROM episode_actions WHERE site=? AND drama_id=?;
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            DramaDatabase.fail(db, "episodeActions read"); return [:]
        }
        defer { sqlite3_finalize(stmt) }
        DramaDatabase.bind(stmt, 1, site)
        DramaDatabase.bind(stmt, 2, dramaID)
        var result: [Int: Actions] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = Int(sqlite3_column_int64(stmt, 0))
            result[id] = Actions(liked: sqlite3_column_int(stmt, 1) != 0,
                                 saved: sqlite3_column_int(stmt, 2) != 0,
                                 positionSeconds: sqlite3_column_double(stmt, 3),
                                 positionTotal: sqlite3_column_double(stmt, 4))
        }
        return result
    }

    /// 本地兜底表全量：资源路径 → 行为（几十行量级，整表读一次比逐行查划算）
    static func allLocalActions() -> [String: Actions] {
        guard let db = openDB() else { return [:] }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = "SELECT media_path, liked, saved, position_seconds, position_total FROM local_actions;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            DramaDatabase.fail(db, "localActions read"); return [:]
        }
        defer { sqlite3_finalize(stmt) }
        var result: [String: Actions] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let path = sqlite3_column_text(stmt, 0).map({ String(cString: $0) }) else { continue }
            result[path] = Actions(liked: sqlite3_column_int(stmt, 1) != 0,
                                   saved: sqlite3_column_int(stmt, 2) != 0,
                                   positionSeconds: sqlite3_column_double(stmt, 3),
                                   positionTotal: sqlite3_column_double(stmt, 4))
        }
        return result
    }

    // MARK: 写

    static func setLiked(_ value: Bool, for identity: MediaIdentity) { writeFlag("liked", value, for: identity) }
    static func setSaved(_ value: Bool, for identity: MediaIdentity) { writeFlag("saved", value, for: identity) }

    /// 播放位置落库：只在关键时机调用（暂停 / 切集 / 退出播放页 / 进后台）
    static func savePosition(seconds: Double, total: Double, for identity: MediaIdentity) {
        guard seconds.isFinite, seconds >= 0, total.isFinite, total > 0 else {
            print("CACHE SKIP[savePosition] reason=badValue s=\(seconds) total=\(total) id=\(identity.label)")
            return
        }
        guard let db = openDB() else { return }
        defer { sqlite3_close(db) }
        let now = ISO8601DateFormatter().string(from: Date())
        switch identity {
        case .episode(let site, let dramaID, let episodeID):
            DramaDatabase.execWrite(db, """
            INSERT INTO episode_actions (site, drama_id, episode_id, position_seconds, position_total, updated_at)
            VALUES (?,?,?,?,?,?)
            ON CONFLICT(site, drama_id, episode_id) DO UPDATE SET
              position_seconds=excluded.position_seconds, position_total=excluded.position_total,
              updated_at=excluded.updated_at
            """, what: "savePosition ep \(episodeID)") { stmt in
                DramaDatabase.bind(stmt, 1, site)
                DramaDatabase.bind(stmt, 2, dramaID)
                sqlite3_bind_int64(stmt, 3, Int64(episodeID))
                sqlite3_bind_double(stmt, 4, seconds)
                sqlite3_bind_double(stmt, 5, total)
                DramaDatabase.bind(stmt, 6, now)
            }
        case .localPath(let path):
            DramaDatabase.execWrite(db, """
            INSERT INTO local_actions (media_path, position_seconds, position_total, updated_at)
            VALUES (?,?,?,?)
            ON CONFLICT(media_path) DO UPDATE SET
              position_seconds=excluded.position_seconds, position_total=excluded.position_total,
              updated_at=excluded.updated_at
            """, what: "savePosition local") { stmt in
                DramaDatabase.bind(stmt, 1, path)
                sqlite3_bind_double(stmt, 2, seconds)
                sqlite3_bind_double(stmt, 3, total)
                DramaDatabase.bind(stmt, 4, now)
            }
        }
        print("CACHE OK[savePosition] id=\(identity.label) s=\(Int(seconds)) total=\(Int(total))")
    }

    /// 资源文件被删除时清掉它的行为数据（否则历史条目残留，列表与库对不上）
    static func removeActions(for identity: MediaIdentity) {
        guard let db = openDB() else { return }
        defer { sqlite3_close(db) }
        switch identity {
        case .episode(let site, let dramaID, let episodeID):
            DramaDatabase.execWrite(db, "DELETE FROM episode_actions WHERE site=? AND drama_id=? AND episode_id=?;",
                      what: "remove ep \(episodeID)") { stmt in
                DramaDatabase.bind(stmt, 1, site)
                DramaDatabase.bind(stmt, 2, dramaID)
                sqlite3_bind_int64(stmt, 3, Int64(episodeID))
            }
        case .localPath(let path):
            DramaDatabase.execWrite(db, "DELETE FROM local_actions WHERE media_path=?;", what: "remove local") { stmt in
                DramaDatabase.bind(stmt, 1, path)
            }
        }
    }

    // MARK: 私有 —— 语句与身份

    private static func writeFlag(_ column: String, _ value: Bool, for identity: MediaIdentity) {
        guard let db = openDB() else { return }
        defer { sqlite3_close(db) }
        let now = ISO8601DateFormatter().string(from: Date())
        switch identity {
        case .episode(let site, let dramaID, let episodeID):
            DramaDatabase.execWrite(db, """
            INSERT INTO episode_actions (site, drama_id, episode_id, \(column), updated_at) VALUES (?,?,?,?,?)
            ON CONFLICT(site, drama_id, episode_id) DO UPDATE SET
              \(column)=excluded.\(column), updated_at=excluded.updated_at
            """, what: "actions \(column) ep \(episodeID)") { stmt in
                DramaDatabase.bind(stmt, 1, site)
                DramaDatabase.bind(stmt, 2, dramaID)
                sqlite3_bind_int64(stmt, 3, Int64(episodeID))
                sqlite3_bind_int(stmt, 4, value ? 1 : 0)
                DramaDatabase.bind(stmt, 5, now)
            }
        case .localPath(let path):
            DramaDatabase.execWrite(db, """
            INSERT INTO local_actions (media_path, \(column), updated_at) VALUES (?,?,?)
            ON CONFLICT(media_path) DO UPDATE SET
              \(column)=excluded.\(column), updated_at=excluded.updated_at
            """, what: "actions \(column) local") { stmt in
                DramaDatabase.bind(stmt, 1, path)
                sqlite3_bind_int(stmt, 2, value ? 1 : 0)
                DramaDatabase.bind(stmt, 3, now)
            }
        }
        print("CACHE OK[actions] \(column)=\(value) id=\(identity.label)")
    }

    private static func selectSQL(for identity: MediaIdentity) -> String {
        switch identity {
        case .episode:
            return "SELECT liked, saved, position_seconds, position_total FROM episode_actions WHERE site=? AND drama_id=? AND episode_id=?;"
        case .localPath:
            return "SELECT liked, saved, position_seconds, position_total FROM local_actions WHERE media_path=?;"
        }
    }

    private static func bindKeys(_ identity: MediaIdentity, to stmt: OpaquePointer?) {
        switch identity {
        case .episode(let site, let dramaID, let episodeID):
            DramaDatabase.bind(stmt, 1, site)
            DramaDatabase.bind(stmt, 2, dramaID)
            sqlite3_bind_int64(stmt, 3, Int64(episodeID))
        case .localPath(let path):
            DramaDatabase.bind(stmt, 1, path)
        }
    }

    /// 资源文件相对下载根目录的路径：local_actions 的主键，也是「找不到服务端 id」时唯一的身份来源
    static func relativePath(for url: URL) -> String {
        let root = DownloadEngine.downloadsDir.standardizedFileURL.path
        let file = url.standardizedFileURL.path
        return file.hasPrefix(root) ? String(file.dropFirst(root.count)) : file
    }

    static func localIdentity(for url: URL) -> MediaIdentity { .localPath(relativePath(for: url)) }

    /// 行为数据归属的唯一算法（播放队列、下载列表、删除清理三处共用，口径不会漂）：
    /// 已知剧身份且该集号有服务端 id → id 表；否则退回资源路径 → 本地表。
    static func identity(series: DramaCache.SeriesIdentity?, sort: Int, playlistURL: URL?) -> MediaIdentity {
        if let series, let episodeID = series.episodeIDsBySort[sort] {
            return .episode(site: series.site, dramaID: series.dramaID, episodeID: episodeID)
        }
        if let playlistURL { return .localPath(relativePath(for: playlistURL)) }
        // 集还没下载（占位卡）：没有文件可依据，只作占位，播放侧不会碰库
        return .localPath("/unassigned/\(sort)")
    }

    /// 只有剧名时的入口（删除清理等一次性场合）：内部按剧名反查，别在循环里反复调
    static func identity(seriesName: String?, sort: Int?, playlistURL: URL?) -> MediaIdentity {
        guard let sort else {
            return playlistURL.map { .localPath(relativePath(for: $0)) } ?? .localPath("/unassigned/0")
        }
        let series = seriesName.flatMap { DramaCache.seriesIdentity(forSeriesName: $0) }
        return identity(series: series, sort: sort, playlistURL: playlistURL)
    }

}
