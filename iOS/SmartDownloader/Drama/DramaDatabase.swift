import Foundation
import SQLite3

// MARK: - 剧集库的统一连接与迁移入口
//
// 同一个 drama_cache.sqlite3 由两个 Service 读写（DramaCache 管元数据、EpisodeActionsStore 管行为数据），
// 但 `PRAGMA user_version` 是整库一个计数器：谁先开库谁先迁移，两边各管一段会互相跳过对方的建表。
// 所以迁移集中在这里，按版本顺序一次跑完，两个 Service 都只调 `open()`。
//
// 版本历史：
//   v1  episode_actions / local_actions 两张行为表 + 把旧 UserDefaults 的点赞/收藏/进度搬进库
//   v2  详情接口整包落库：drama_cache 加 api_detail 与提升列、drama_episodes 加每集元数据列、新增 drama_related
//
// 幂等策略：建表一律 CREATE IF NOT EXISTS；加列先查 PRAGMA table_info 再 ALTER（不靠版本号判断列是否存在），
// 这样即使旧库版本号被别的入口提前抬高，缺的列也补得上。
// 旧数据搬迁另用 UserDefaults 标记门控，与 schema 版本解耦（避免「版本已被抬高 → 搬迁被跳过」丢用户数据）。
// 主线程约定：与两个 Service 一致，全部调用 assume 主线程。

let SQLITE_TRANSIENT = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)

enum DramaDatabase {

    static let schemaVersion = 2
    private static var migrated = false
    private static let legacyMigratedKey = "EpisodeActions.legacyMigrated"

    /// 打开库并确保 schema 就绪（每进程只迁移一次）
    static func open() -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(DramaCache.dbURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            fail(db, "open")
            return nil
        }
        if !migrated {
            migrated = true
            migrate(db)
        }
        return db
    }

    // MARK: 迁移

    private static func migrate(_ db: OpaquePointer?) {
        let version = userVersion(db)
        createBaseTables(db)
        addMissingColumns(db)
        migrateLegacyUserDefaultsIfNeeded(db)
        if version < schemaVersion {
            sqlite3_exec(db, "PRAGMA user_version = \(schemaVersion);", nil, nil, nil)
            print("CACHE OK[migrate] user_version \(version) -> \(schemaVersion)")
        }
    }

    private static func userVersion(_ db: OpaquePointer?) -> Int {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "PRAGMA user_version;", -1, &stmt, nil) == SQLITE_OK,
              sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int(stmt, 0))
    }

    private static func createBaseTables(_ db: OpaquePointer?) {
        let schema = """
        CREATE TABLE IF NOT EXISTS drama_cache (
            site TEXT NOT NULL,
            drama_id TEXT NOT NULL,
            name TEXT, update_status TEXT, cover TEXT, intro TEXT,
            page_meta TEXT, fetched_at TEXT,
            PRIMARY KEY (site, drama_id)
        );
        CREATE TABLE IF NOT EXISTS drama_episodes (
            site TEXT NOT NULL,
            drama_id TEXT NOT NULL,
            episode_id INTEGER NOT NULL,
            sort INTEGER, playable INTEGER,
            downloaded INTEGER DEFAULT 0,
            folder TEXT, updated_at TEXT,
            PRIMARY KEY (site, drama_id, episode_id)
        );
        CREATE TABLE IF NOT EXISTS episode_actions (
            site TEXT NOT NULL,
            drama_id TEXT NOT NULL,
            episode_id INTEGER NOT NULL,
            liked INTEGER NOT NULL DEFAULT 0,
            saved INTEGER NOT NULL DEFAULT 0,
            position_seconds REAL NOT NULL DEFAULT 0,
            position_total REAL NOT NULL DEFAULT 0,
            updated_at TEXT,
            PRIMARY KEY (site, drama_id, episode_id)
        );
        CREATE TABLE IF NOT EXISTS local_actions (
            media_path TEXT NOT NULL PRIMARY KEY,
            liked INTEGER NOT NULL DEFAULT 0,
            saved INTEGER NOT NULL DEFAULT 0,
            position_seconds REAL NOT NULL DEFAULT 0,
            position_total REAL NOT NULL DEFAULT 0,
            updated_at TEXT
        );
        CREATE TABLE IF NOT EXISTS drama_related (
            site TEXT NOT NULL,
            drama_id TEXT NOT NULL,
            related_video_id INTEGER NOT NULL,
            title TEXT, cover TEXT, tags TEXT,
            play_count INTEGER, play_count_text TEXT,
            serialize_status_text TEXT, content_access_type TEXT,
            position INTEGER, updated_at TEXT,
            PRIMARY KEY (site, drama_id, related_video_id)
        );
        """
        if sqlite3_exec(db, schema, nil, nil, nil) != SQLITE_OK {
            fail(db, "base schema")
        }
        // tags 列是历史追加列：与 v2 补列同一套「先查再补」，不再每次启动打 duplicate column 报错
        if !columnNames(db, table: "drama_cache").contains("tags") {
            if sqlite3_exec(db, "ALTER TABLE drama_cache ADD COLUMN tags TEXT;", nil, nil, nil) != SQLITE_OK {
                fail(db, "add column drama_cache.tags TEXT")
            }
        }
    }

    /// v2：详情接口整包落库需要的列。逐列查 table_info 再 ALTER，缺哪列补哪列
    private static func addMissingColumns(_ db: OpaquePointer?) {
        let dramaColumns: [(String, String)] = [
            ("api_detail", "TEXT"),              // 详情接口原始响应体（整包，任何字段都不丢）
            ("detail_fetched_at", "TEXT"),       // 这份详情是什么时候抓的
            ("api_title", "TEXT"),               // 详情接口标题（与下载接口的 name 分开存，互不覆盖）
            ("score", "REAL"),
            ("social_cover", "TEXT"),
            ("actor_list", "TEXT"),              // JSON 数组原文
            ("original", "INTEGER"),
            ("serialize_status", "INTEGER"),
            ("serialize_status_text", "TEXT"),
            ("episode_count", "INTEGER"),
            ("play_count", "INTEGER"),
            ("play_count_text", "TEXT"),
            ("like_count", "INTEGER"),
            ("chase_count", "INTEGER"),
            ("comment_count", "INTEGER"),
            ("collect_count", "INTEGER"),
            ("current_episode_id", "INTEGER"),   // 服务端记的「当前集」
            ("continue_episode_id", "INTEGER"),  // 服务端记的「续播集」
            ("play_duration", "INTEGER"),        // 服务端记的观看时长
            ("resolution", "TEXT"),
            ("video_width", "INTEGER"),
            ("video_height", "INTEGER"),
            ("video_orientation", "TEXT"),
            ("is_collected", "INTEGER"),         // 服务端收藏状态（与本地 episode_actions.saved 不同维度）
            ("is_chased", "INTEGER"),            // 服务端追剧状态
            ("content_access_type", "TEXT"),
            ("coin_price", "INTEGER"),
            ("share_url", "TEXT"),
            ("share_title", "TEXT"),
            ("share_cover", "TEXT"),
            ("show_hot_badge", "INTEGER"),
            ("show_new", "INTEGER"),
            ("show_completed", "INTEGER"),
            ("show_hot", "INTEGER"),
            ("access_json", "TEXT"),             // 权限/付费判定整块
            ("urge_json", "TEXT"),               // 催更整块
        ]
        let episodeColumns: [(String, String)] = [
            ("title", "TEXT"),
            ("duration", "INTEGER"),             // 站点给的时长，样本里常为 0（未提供）
            ("resolution", "TEXT"),
            ("is_new", "INTEGER"),
            ("access_state", "TEXT"),
            ("can_play", "INTEGER"),             // 详情接口的可播判定（playable 来自下载接口，两者并存）
            ("content_type", "TEXT"),
            ("is_trial", "INTEGER"),
        ]
        addColumns(db, table: "drama_cache", columns: dramaColumns)
        addColumns(db, table: "drama_episodes", columns: episodeColumns)
    }

    private static func addColumns(_ db: OpaquePointer?, table: String, columns: [(String, String)]) {
        let existing = columnNames(db, table: table)
        for (name, type) in columns where !existing.contains(name) {
            if sqlite3_exec(db, "ALTER TABLE \(table) ADD COLUMN \(name) \(type);", nil, nil, nil) != SQLITE_OK {
                fail(db, "add column \(table).\(name)")
            } else {
                print("CACHE OK[migrate] add column \(table).\(name) \(type)")
            }
        }
    }

    private static func columnNames(_ db: OpaquePointer?, table: String) -> Set<String> {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmt, nil) == SQLITE_OK else { return [] }
        var names = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let c = sqlite3_column_text(stmt, 1) { names.insert(String(cString: c)) }
        }
        return names
    }

    // MARK: 旧 UserDefaults 行为数据搬迁（v1 的数据部分，与 schema 版本解耦）

    private struct LegacyRecord {
        var liked = false
        var saved = false
        var seconds = 0.0
        var total = 0.0
        var isEmpty: Bool { !liked && !saved && total == 0 }
    }

    private static let legacyLikedPrefix = "DramaPlayer.liked."
    private static let legacySavedPrefix = "DramaPlayer.saved."
    private static let legacyProgressPrefix = "PlaybackProgress."

    /// 旧写法把点赞/收藏按「集目录相对路径」记在 UserDefaults，上一版进度记在 PlaybackProgress.<资源路径>。
    /// 一次性搬进库并删源键；用独立标记门控，避免 schema 版本被提前抬高后搬迁被跳过。
    private static func migrateLegacyUserDefaultsIfNeeded(_ db: OpaquePointer?) {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: legacyMigratedKey) else { return }
        defer {
            defaults.set(true, forKey: legacyMigratedKey)
        }

        var records: [String: LegacyRecord] = [:]
        for (key, value) in defaults.dictionaryRepresentation() {
            if key.hasPrefix(legacyLikedPrefix) || key.hasPrefix(legacySavedPrefix) {
                let prefix = key.hasPrefix(legacyLikedPrefix) ? legacyLikedPrefix : legacySavedPrefix
                let folder = String(key.dropFirst(prefix.count))
                guard !folder.isEmpty, (value as? Bool) == true else { continue }
                let path = folder + "/playlist.m3u8"
                // 集目录早已被删掉的历史标记不搬：搬进去就是一行永远读不到的死数据
                guard FileManager.default.fileExists(atPath: DownloadEngine.downloadsDir.appendingPathComponent(folder).path) else {
                    print("CACHE SKIP[legacy flag] reason=pathMissing \(folder)")
                    continue
                }
                var record = records[path] ?? LegacyRecord()
                if prefix == legacyLikedPrefix { record.liked = true } else { record.saved = true }
                records[path] = record
            } else if key.hasPrefix(legacyProgressPrefix) {
                let path = String(key.dropFirst(legacyProgressPrefix.count))
                let parts = (value as? String)?.split(separator: "|") ?? []
                guard parts.count == 2, let seconds = Double(parts[0]), let total = Double(parts[1]) else { continue }
                var record = records[path] ?? LegacyRecord()
                record.seconds = seconds
                record.total = total
                records[path] = record
            }
        }

        var moved = 0
        for (path, record) in records where !record.isEmpty {
            writeLegacy(db, identity: legacyIdentity(forResourcePath: path), record: record)
            moved += 1
        }
        for key in defaults.dictionaryRepresentation().keys
        where key.hasPrefix(legacyLikedPrefix) || key.hasPrefix(legacySavedPrefix) || key.hasPrefix(legacyProgressPrefix) {
            defaults.removeObject(forKey: key)
        }
        print("CACHE OK[legacy migrate] records=\(records.count) moved=\(moved)")
    }

    /// 旧路径 → 新身份：能按剧名+集号反查到服务端 id 就走主表，否则走本地路径表（不猜 id）
    private static func legacyIdentity(forResourcePath path: String) -> MediaIdentity {
        let parts = path.split(separator: "/").map(String.init)
        guard parts.count >= 3, parts.last == "playlist.m3u8",
              let sort = DownloadManager.episodeSort(fromFolderName: parts[parts.count - 2]),
              let series = DramaCache.seriesIdentity(forSeriesName: parts[0]),
              let episodeID = series.episodeIDsBySort[sort] else {
            return .localPath(path)
        }
        return .episode(site: series.site, dramaID: series.dramaID, episodeID: episodeID)
    }

    private static func writeLegacy(_ db: OpaquePointer?, identity: MediaIdentity, record: LegacyRecord) {
        let now = ISO8601DateFormatter().string(from: Date())
        switch identity {
        case .episode(let site, let dramaID, let episodeID):
            execWrite(db, """
            INSERT INTO episode_actions (site, drama_id, episode_id, liked, saved, position_seconds, position_total, updated_at)
            VALUES (?,?,?,?,?,?,?,?)
            ON CONFLICT(site, drama_id, episode_id) DO UPDATE SET
              liked=MAX(liked, excluded.liked), saved=MAX(saved, excluded.saved),
              position_seconds=excluded.position_seconds, position_total=excluded.position_total
            """, what: "legacy ep \(episodeID)") { stmt in
                bind(stmt, 1, site)
                bind(stmt, 2, dramaID)
                sqlite3_bind_int64(stmt, 3, Int64(episodeID))
                sqlite3_bind_int(stmt, 4, record.liked ? 1 : 0)
                sqlite3_bind_int(stmt, 5, record.saved ? 1 : 0)
                sqlite3_bind_double(stmt, 6, record.seconds)
                sqlite3_bind_double(stmt, 7, record.total)
                bind(stmt, 8, now)
            }
        case .localPath(let path):
            execWrite(db, """
            INSERT INTO local_actions (media_path, liked, saved, position_seconds, position_total, updated_at)
            VALUES (?,?,?,?,?,?)
            ON CONFLICT(media_path) DO UPDATE SET
              liked=MAX(liked, excluded.liked), saved=MAX(saved, excluded.saved),
              position_seconds=excluded.position_seconds, position_total=excluded.position_total
            """, what: "legacy local") { stmt in
                bind(stmt, 1, path)
                sqlite3_bind_int(stmt, 2, record.liked ? 1 : 0)
                sqlite3_bind_int(stmt, 3, record.saved ? 1 : 0)
                sqlite3_bind_double(stmt, 4, record.seconds)
                sqlite3_bind_double(stmt, 5, record.total)
                bind(stmt, 6, now)
            }
        }
    }

    // MARK: 共用低层助手（两个 Service 都用这里的，不再各自复制一份）

    static func fail(_ db: OpaquePointer?, _ what: String) {
        print("CACHE FAIL[\(what)]: \(String(cString: sqlite3_errmsg(db)))")
    }

    static func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, (value as NSString).utf8String, -1, SQLITE_TRANSIENT)
    }

    static func text(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: c)
    }

    /// 执行一次性写语句（绑定后 step，失败打印不静默）
    static func execWrite(_ db: OpaquePointer?, _ sql: String, what: String,
                          bindValues: (OpaquePointer?) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            fail(db, "\(what) prepare")
            return
        }
        defer { sqlite3_finalize(stmt) }
        bindValues(stmt)
        if sqlite3_step(stmt) != SQLITE_DONE {
            fail(db, "\(what) step")
        }
    }

    /// 把一批写语句包进一个事务（详情落库要写几十列 + N 集 + 推荐列表，逐条 autocommit 太碎）
    static func transaction(_ db: OpaquePointer?, _ body: () -> Void) {
        sqlite3_exec(db, "BEGIN;", nil, nil, nil)
        body()
        sqlite3_exec(db, "COMMIT;", nil, nil, nil)
    }
}
