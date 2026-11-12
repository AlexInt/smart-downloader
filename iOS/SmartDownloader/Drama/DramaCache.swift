import Foundation
import SQLite3
import Synchronization

// MARK: - 剧集元数据本地缓存（SQLite）
//
// 按 (站点, 剧 ID) 主键存剧集信息；集数逐集存 drama_episodes 表（含下载状态）。
// 磁盘是"是否已下载"的账本（playlist.m3u8 存在即已下载），数据库是镜像：
//   - 下载完成回调 markDownloaded 立即记入
//   - 选集面板每次打开 reconcileDownloaded 对账（删除/收编后的变化统一同步）
// 集数更新：网络刷新返回新集列表时按集 ID upsert，新增集合入、已下载标记保留。
// 每集播放直链带时效 auth_key，不缓存（下载前现取）。
// 不引入第三方依赖，直接用系统 libsqlite3。SQL 失败打印 errmsg，不静默。

private let SQLITE_TRANSIENT = unsafeBitCast(OpaquePointer(bitPattern: -1), to: sqlite3_destructor_type.self)

enum DramaCache {

    struct Entry {
        var name: String?
        var updateStatus: String?
        var cover: String?
        var intro: String?
        /// 话题标签（DOM 收割，空格分隔；P7）
        var tags: String?
        /// tags 来源（page_meta.tags_source）：api = 请求拦截定向提取；
        /// nil = 旧缓存（锚点法时代），harvestIfNeeded 视为缺失自动补采一次
        var tagsSource: String? = nil
        var episodes: [ApiDramaEpisode]  // 按 sort 升序，含 downloaded/folder
        var fetchedAt: String?
    }

    /// 数据库文件：跟随 SMARTDOWNLOADER_DIR（冒烟隔离），真机放 Documents（Finder 文件共享可见可拷出）
    static var dbURL: URL {
        let fm = FileManager.default
        if let custom = ProcessInfo.processInfo.environment["SMARTDOWNLOADER_DIR"] {
            return URL(fileURLWithPath: custom, isDirectory: true).appendingPathComponent("drama_cache.sqlite3")
        }
        let docs = fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("drama_cache.sqlite3")
    }

    private static func fail(_ db: OpaquePointer?, _ what: String) {
        print("CACHE FAIL[\(what)]: \(String(cString: sqlite3_errmsg(db)))")
    }

    private static func openDB() -> OpaquePointer? {
        var db: OpaquePointer?
        guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK else {
            fail(db, "open")
            return nil
        }
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
        """
        if sqlite3_exec(db, schema, nil, nil, nil) != SQLITE_OK {
            fail(db, "schema")
        }
        // v2 迁移：tags 列（话题标签，来自 DOM 收割 P7）。列已存在时 ALTER 报错，静默忽略；
        // 每进程只试一次。Swift 6 下全局可变状态必须显式同步，用 Mutex 表达所有权。
        let shouldMigrate = tagsMigrated.withLock { migrated -> Bool in
            if migrated { return false }
            migrated = true
            return true
        }
        if shouldMigrate {
            sqlite3_exec(db, "ALTER TABLE drama_cache ADD COLUMN tags TEXT;", nil, nil, nil)
        }
        return db
    }

    private static let tagsMigrated = Mutex(false)

    private static func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, (value as NSString).utf8String, -1, SQLITE_TRANSIENT)
    }

    private static func text(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard let c = sqlite3_column_text(stmt, index) else { return nil }
        return String(cString: c)
    }

    /// 执行一次性写语句（绑定后 step，错误打印）
    private static func execWrite(_ db: OpaquePointer?, _ sql: String, what: String,
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

    // MARK: 读

    /// 按剧名反查该剧全部集号。下载页只有剧名（无 site/dramaID），
    /// 单击播放时用它同步整部剧集数，让播放页能按全剧集号上下滑。
    static func allSorts(forSeriesName name: String) -> [Int] {
        guard let db = openDB() else {
            print("PLAYER_DBG [Service] DramaCache.allSorts FAIL reason=openDB name=\(name)")
            return []
        }
        defer { sqlite3_close(db) }
        let sql = """
        SELECT e.sort FROM drama_episodes e
        JOIN drama_cache c ON c.site = e.site AND c.drama_id = e.drama_id
        WHERE c.name = ? ORDER BY e.sort;
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            fail(db, "allSorts prepare")
            print("PLAYER_DBG [Service] DramaCache.allSorts FAIL reason=prepare name=\(name)")
            return []
        }
        bind(stmt, 1, name)
        var sorts: [Int] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            sorts.append(Int(sqlite3_column_int(stmt, 0)))
        }
        sqlite3_finalize(stmt)
        print("PLAYER_DBG [Service] DramaCache.allSorts name=\(name) rows=\(sorts.count) sorts=\(Array(sorts.prefix(20)))")
        return sorts
    }

    static func load(site: String, dramaID: String) -> Entry? {
        guard let db = openDB() else { return nil }
        defer { sqlite3_close(db) }
        let infoSQL = "SELECT name, update_status, cover, intro, tags, fetched_at, page_meta FROM drama_cache WHERE site=? AND drama_id=?;"
        let epSQL = """
        SELECT episode_id, sort, playable, downloaded, folder
        FROM drama_episodes WHERE site=? AND drama_id=? ORDER BY sort;
        """
        var name: String?, status: String?, cover: String?, intro: String?, tags: String?, fetchedAt: String?
        var tagsSource: String?

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, infoSQL, -1, &stmt, nil) == SQLITE_OK else {
            fail(db, "load info prepare"); return nil
        }
        bind(stmt, 1, site)
        bind(stmt, 2, dramaID)
        if sqlite3_step(stmt) == SQLITE_ROW {
            name = text(stmt, 0); status = text(stmt, 1); cover = text(stmt, 2)
            intro = text(stmt, 3); tags = text(stmt, 4); fetchedAt = text(stmt, 5)
            if let raw = text(stmt, 6),
               let meta = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] {
                tagsSource = meta["tags_source"] as? String
            }
        } else {
            sqlite3_finalize(stmt)
            return nil  // 剧不存在 → 视为无缓存
        }
        sqlite3_finalize(stmt)

        var episodes: [ApiDramaEpisode] = []
        guard sqlite3_prepare_v2(db, epSQL, -1, &stmt, nil) == SQLITE_OK else {
            fail(db, "load episodes prepare"); return nil
        }
        bind(stmt, 1, site)
        bind(stmt, 2, dramaID)
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = Int(sqlite3_column_int64(stmt, 0))
            let sort = Int(sqlite3_column_int(stmt, 1))
            let playable = sqlite3_column_int(stmt, 2) != 0
            let downloaded = sqlite3_column_int(stmt, 3) != 0
            let folder = text(stmt, 4)
            episodes.append(ApiDramaEpisode(id: id, sort: sort, playable: playable,
                                         downloaded: downloaded, folder: folder))
        }
        sqlite3_finalize(stmt)
        return Entry(name: name, updateStatus: status, cover: cover, intro: intro, tags: tags,
                     tagsSource: tagsSource, episodes: episodes, fetchedAt: fetchedAt)
    }

    // MARK: 写 —— 剧集信息 + 集数列表（合并式 upsert，保留下载状态）

    /// 网络刷新返回的剧集信息落库；集数按集 ID upsert：
    /// 新集合入、已消失的集删除、既有集的 downloaded/folder 保留不动
    static func saveInfo(site: String, dramaID: String, info: DramaInfo) {
        guard let db = openDB() else { return }
        defer { sqlite3_close(db) }
        let now = ISO8601DateFormatter().string(from: Date())

        execWrite(db, """
        INSERT INTO drama_cache (site, drama_id, name, update_status, fetched_at)
        VALUES (?,?,?,?,?)
        ON CONFLICT(site, drama_id) DO UPDATE SET
          name=excluded.name, update_status=excluded.update_status, fetched_at=excluded.fetched_at
        """, what: "info upsert") { stmt in
            bind(stmt, 1, site)
            bind(stmt, 2, dramaID)
            bind(stmt, 3, info.name)
            bind(stmt, 4, info.updateStatus ?? "")
            bind(stmt, 5, now)
        }

        // 以最新列表为准清掉接口已不存在的集
        execWrite(db, "DELETE FROM drama_episodes WHERE site=? AND drama_id=?", what: "episodes clear") { stmt in
            bind(stmt, 1, site)
            bind(stmt, 2, dramaID)
        }

        for ep in info.episodes {
            execWrite(db, """
            INSERT INTO drama_episodes (site, drama_id, episode_id, sort, playable, downloaded, folder, updated_at)
            VALUES (?,?,?,?,?,0,NULL,?)
            ON CONFLICT(site, drama_id, episode_id) DO UPDATE SET
              sort=excluded.sort, playable=excluded.playable, updated_at=excluded.updated_at
            """, what: "episode upsert \(ep.id)") { stmt in
                bind(stmt, 1, site)
                bind(stmt, 2, dramaID)
                sqlite3_bind_int64(stmt, 3, Int64(ep.id))
                sqlite3_bind_int(stmt, 4, Int32(ep.sort))
                sqlite3_bind_int(stmt, 5, ep.playable ? 1 : 0)
                bind(stmt, 6, now)
            }
        }
    }

    /// 下载完成回调：该集标记已下载 + 记录落盘目录名（行不存在时补建）
    static func markDownloaded(site: String, dramaID: String, episodeID: Int, folder: String) {
        guard let db = openDB() else { return }
        defer { sqlite3_close(db) }
        execWrite(db, """
        INSERT INTO drama_episodes (site, drama_id, episode_id, downloaded, folder, updated_at)
        VALUES (?,?,?,?,?,?)
        ON CONFLICT(site, drama_id, episode_id) DO UPDATE SET
          downloaded=1, folder=excluded.folder, updated_at=excluded.updated_at
        """, what: "mark downloaded \(episodeID)") { stmt in
            bind(stmt, 1, site)
            bind(stmt, 2, dramaID)
            sqlite3_bind_int64(stmt, 3, Int64(episodeID))
            sqlite3_bind_int(stmt, 4, 1)
            bind(stmt, 5, folder)
            bind(stmt, 6, ISO8601DateFormatter().string(from: Date()))
        }
    }

    /// 磁盘对账：以传入的 已下载集号->目录名 映射刷新全部集的 downloaded/folder 标记
    /// （删除单集/删全剧/收编之后统一走这里同步）
    static func reconcileDownloaded(site: String, dramaID: String, folders: [Int: String]) {
        guard let db = openDB() else { return }
        defer { sqlite3_close(db) }
        let sql = "SELECT episode_id, sort FROM drama_episodes WHERE site=? AND drama_id=?;"
        var selectStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &selectStmt, nil) == SQLITE_OK else {
            fail(db, "reconcile prepare"); return
        }
        bind(selectStmt, 1, site)
        bind(selectStmt, 2, dramaID)
        var episodeIDs: [Int64] = []
        var sorts: [Int] = []
        while sqlite3_step(selectStmt) == SQLITE_ROW {
            episodeIDs.append(sqlite3_column_int64(selectStmt, 0))
            sorts.append(Int(sqlite3_column_int(selectStmt, 1)))
        }
        sqlite3_finalize(selectStmt)

        let now = ISO8601DateFormatter().string(from: Date())
        for (index, id) in episodeIDs.enumerated() {
            let sort = sorts[index]
            let downloaded = folders[sort] != nil
            execWrite(db, "UPDATE drama_episodes SET downloaded=?, folder=?, updated_at=? WHERE site=? AND drama_id=? AND episode_id=?;",
                      what: "reconcile ep \(sort)") { stmt in
                sqlite3_bind_int(stmt, 1, downloaded ? 1 : 0)
                if let folder = folders[sort] {
                    bind(stmt, 2, folder)
                } else {
                    sqlite3_bind_null(stmt, 2)
                }
                bind(stmt, 3, now)
                bind(stmt, 4, site)
                bind(stmt, 5, dramaID)
                sqlite3_bind_int64(stmt, 6, id)
            }
        }
    }

    // MARK: 写 —— 页面元数据（封面/简介，DOM 提取）

    /// DOM 提取的页面元数据合并进已有行（cover/intro 存列，原始字段存 page_meta JSON 列）
    static func savePageMeta(site: String, dramaID: String, update: [String: Any]) {
        guard let db = openDB() else { return }
        defer { sqlite3_close(db) }
        let existing = load(site: site, dramaID: dramaID)
        let cover = (update["cover"] as? String) ?? (update["ogImage"] as? String) ?? existing?.cover ?? ""
        let intro = (update["intro"] as? String) ?? (update["desc"] as? String) ?? existing?.intro ?? ""
        // 本轮 DOM 没抓到 tags 时保留旧值、都没有则写 NULL，**绝不写空串**：
        // 空串会被 VM 当成「已缓存」而永久跳过收割（P7 采集失败不可恢复的 bug）。
        // 历史脏数据里的空串也一并归为「无」，让重进页/重启后能重新收割。
        let existingTags = existing?.tags.flatMap { $0.isEmpty ? nil : $0 }
        let newTags = (update["tags"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let tags = newTags ?? existingTags
        var pageMeta: [String: Any] = [:]
        let sql = "SELECT page_meta FROM drama_cache WHERE site=? AND drama_id=?;"
        var sel: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &sel, nil) == SQLITE_OK {
            bind(sel, 1, site)
            bind(sel, 2, dramaID)
            if sqlite3_step(sel) == SQLITE_ROW, let raw = text(sel, 0),
               let old = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] {
                pageMeta = old
            }
        }
        sqlite3_finalize(sel)
        for (key, value) in update { pageMeta[key] = value }
        let metaJSON = (try? JSONSerialization.data(withJSONObject: pageMeta, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        execWrite(db, """
        INSERT INTO drama_cache (site, drama_id, cover, intro, tags, page_meta, fetched_at)
        VALUES (?,?,?,?,?,?,?)
        ON CONFLICT(site, drama_id) DO UPDATE SET
          cover=excluded.cover, intro=excluded.intro, tags=excluded.tags, page_meta=excluded.page_meta
        """, what: "page meta upsert") { stmt in
            bind(stmt, 1, site)
            bind(stmt, 2, dramaID)
            bind(stmt, 3, cover)
            bind(stmt, 4, intro)
            if let tags {
                bind(stmt, 5, tags)
            } else {
                sqlite3_bind_null(stmt, 5)
            }
            bind(stmt, 6, metaJSON)
            bind(stmt, 7, ISO8601DateFormatter().string(from: Date()))
        }
    }

    // MARK: 缓存行 → 领域模型

    /// 从缓存行还原（集数列表为空视为无效缓存，走网络）。
    /// 转换归 Service：`DramaInfo` 保持纯数据，不再挂 `init?(entry:)` 这种依赖缓存结构的行为。
    static func dramaInfo(from entry: Entry) -> DramaInfo? {
        guard !entry.episodes.isEmpty else { return nil }
        return DramaInfo(name: entry.name ?? "未知剧集",
                         updateStatus: entry.updateStatus,
                         episodes: entry.episodes)
    }
}
