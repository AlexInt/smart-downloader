import Foundation
import SQLite3

// MARK: - 剧集元数据本地缓存（SQLite）
//
// 按 (站点, 剧 ID) 主键存剧集信息；集数逐集存 drama_episodes 表（含下载状态）。
// 磁盘是"是否已下载"的账本（playlist.m3u8 存在即已下载），数据库是镜像：
//   - 下载完成回调 markDownloaded 立即记入
//   - 选集面板每次打开 reconcileDownloaded 对账（删除/收编后的变化统一同步）
// 集数更新：网络刷新返回新集列表时按集 ID upsert，新增集合入、已下载标记保留。
// 每集播放直链带时效 auth_key，不缓存（下载前现取）。
// 不引入第三方依赖，直接用系统 libsqlite3。SQL 失败打印 errmsg，不静默。

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

    /// 建表与版本迁移统一由 DramaDatabase 负责（整库一个 user_version）
    private static func openDB() -> OpaquePointer? { DramaDatabase.open() }

    // MARK: 读

    /// 按剧名反查该剧全部集号。下载页只有剧名（无 site/dramaID），
    /// 单击播放时用它同步整部剧集数，让播放页能按全剧集号上下滑。
    static func allSorts(forSeriesName name: String) -> [Int] {
        guard let db = openDB() else {
            print("PLAYER_DBG [Service] DramaCache.allSorts FAIL reason=openDB name=\(name)")
            return []
        }
        defer { sqlite3_close(db) }
        guard let resolved = resolveDramaID(forSeriesName: name, db: db) else { return [] }
        let sorts = episodeSorts(site: resolved.site, dramaID: resolved.dramaID, db: db)
        print("PLAYER_DBG [Service] DramaCache.allSorts name=\(name) matchedBy=\(resolved.matchedBy) "
              + "\(resolved.site)#\(resolved.dramaID) rows=\(sorts.count) sorts=\(Array(sorts.prefix(20)))")
        return sorts
    }

    /// 全剧总集数（「选集 · 全 N 集」与面板应显示多少格用它）：
    /// 取详情接口的 `episode_count` 与已缓存最大集号的较大者。
    /// **下载页入口只有剧名**，这是「本剧一共多少集」唯一可离线得知的字段——
    /// 没有它，只下了第 7~11 集的剧在选集面板里就只剩 5 格（用户实报 2026-11-15）。
    /// 从未抓过详情（缓存行缺失）返回 nil：我们绝不凭空编一个总集数。
    static func episodeTotal(forSeriesName name: String) -> Int? {
        guard let db = openDB() else {
            print("PLAYER_DBG [Service] DramaCache.episodeTotal FAIL reason=openDB name=\(name)")
            return nil
        }
        defer { sqlite3_close(db) }
        guard let resolved = resolveDramaID(forSeriesName: name, db: db) else {
            print("PLAYER_DBG [Service] DramaCache.episodeTotal MISS reason=noDramaByName name=\(name)")
            return nil
        }
        return episodeTotal(site: resolved.site, dramaID: resolved.dramaID, db: db)
    }

    static func episodeTotal(site: String, dramaID: String) -> Int? {
        guard let db = openDB() else { return nil }
        defer { sqlite3_close(db) }
        return episodeTotal(site: site, dramaID: dramaID, db: db)
    }

    private static func episodeTotal(site: String, dramaID: String, db: OpaquePointer) -> Int? {
        var declared = 0
        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, "SELECT episode_count FROM drama_cache WHERE site=? AND drama_id=?;",
                              -1, &stmt, nil) == SQLITE_OK {
            DramaDatabase.bind(stmt, 1, site)
            DramaDatabase.bind(stmt, 2, dramaID)
            if sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_type(stmt, 0) != SQLITE_NULL {
                declared = Int(sqlite3_column_int(stmt, 0))
            }
            sqlite3_finalize(stmt)
        } else {
            DramaDatabase.fail(db, "episodeTotal prepare")
        }
        let maxSort = episodeSorts(site: site, dramaID: dramaID, db: db).max() ?? 0
        let total = max(declared, maxSort)
        print("PLAYER_DBG [Service] DramaCache.episodeTotal \(site)#\(dramaID) "
              + "declared=\(declared) maxSort=\(maxSort) → \(total)")
        return total > 0 ? total : nil
    }

    private static func episodeSorts(site: String, dramaID: String, db: OpaquePointer) -> [Int] {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT sort FROM drama_episodes WHERE site=? AND drama_id=? ORDER BY sort;",
                                 -1, &stmt, nil) == SQLITE_OK else {
            DramaDatabase.fail(db, "episodeSorts prepare")
            return []
        }
        DramaDatabase.bind(stmt, 1, site)
        DramaDatabase.bind(stmt, 2, dramaID)
        var sorts: [Int] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            // sort 列缺失（markDownloaded 早于 saveInfo 建的行）读出来是 NULL → 0，
            // 0 不是合法集号，直接跳过（否则面板第一格会显示「0」）
            guard sqlite3_column_type(stmt, 0) != SQLITE_NULL else { continue }
            let sort = Int(sqlite3_column_int(stmt, 0))
            if sort > 0 { sorts.append(sort) }
        }
        sqlite3_finalize(stmt)
        return sorts
    }

    /// 剧名 → (site, drama_id)。下载页入口只有「剧目录名」，而 `drama_cache.name` 存的是
    /// 接口原名：原名里带 `/ : （）` 之类字符时，落盘目录名会被 `DownloadEngine.sanitizeTitle`
    /// 改写，两者不再相等。只做精确匹配就会让整条反查落空（面板于是只剩磁盘上那几集）。
    /// 所以先精确匹配，未命中再按同一套安全化规则比对一次；同名多剧取最近抓取的一条。
    private static func resolveDramaID(forSeriesName name: String, db: OpaquePointer)
        -> (site: String, dramaID: String, matchedBy: String)? {
        let normalized = DownloadEngine.sanitizeTitle(name) ?? name
        var exact: (String, String)?
        var exactRows = 0
        var tolerant: (String, String)?
        var tolerantRows = 0
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT site, drama_id, name FROM drama_cache ORDER BY fetched_at DESC;",
                                 -1, &stmt, nil) == SQLITE_OK else {
            DramaDatabase.fail(db, "resolveDramaID prepare")
            return nil
        }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let site = DramaDatabase.text(stmt, 0) ?? ""
            let dramaID = DramaDatabase.text(stmt, 1) ?? ""
            let cachedName = DramaDatabase.text(stmt, 2) ?? ""
            if cachedName == name {
                exactRows += 1
                if exact == nil { exact = (site, dramaID) }
            } else if (DownloadEngine.sanitizeTitle(cachedName) ?? cachedName) == normalized {
                tolerantRows += 1
                if tolerant == nil { tolerant = (site, dramaID) }
            }
        }
        sqlite3_finalize(stmt)
        if let exact {
            if exactRows > 1 {
                print("PLAYER_DBG [Service] resolveDramaID AMBIGUOUS name=\(name) rows=\(exactRows) "
                      + "取最近抓取的一条 \(exact.0)#\(exact.1)")
            }
            return (exact.0, exact.1, "exact")
        }
        if let tolerant {
            print("PLAYER_DBG [Service] resolveDramaID MATCH reason=sanitizedName name=\(name) "
                  + "→ \(tolerant.0)#\(tolerant.1) rows=\(tolerantRows)")
            return (tolerant.0, tolerant.1, "sanitized")
        }
        print("PLAYER_DBG [Service] resolveDramaID MISS reason=noDramaByName name=\(name) normalized=\(normalized)")
        return nil
    }

    /// 剧的「行为数据身份」：按剧名反查 site/drama_id 与 集号→服务端集 id 映射。
    /// 下载页入口只有剧名，这是能拿到的最强身份；同名多剧（撞名/多站点）取最近抓取的一条并打日志，
    /// 剧集页入口应直接把 `DramaTarget` 传进来，不走这条歧义路径。
    struct SeriesIdentity {
        let site: String
        let dramaID: String
        let episodeIDsBySort: [Int: Int]
    }

    static func seriesIdentity(forSeriesName name: String) -> SeriesIdentity? {
        guard let db = openDB() else {
            print("PLAYER_DBG [Service] seriesIdentity FAIL reason=openDB name=\(name)")
            return nil
        }
        defer { sqlite3_close(db) }
        guard let resolved = resolveDramaID(forSeriesName: name, db: db) else { return nil }
        return seriesIdentity(site: resolved.site, dramaID: resolved.dramaID)
    }

    /// 已知 (site, drama_id) 时直接走这条：剧集页入口带 target 过来，不必按剧名猜
    static func seriesIdentity(site: String, dramaID: String) -> SeriesIdentity? {
        guard let db = openDB() else {
            print("PLAYER_DBG [Service] seriesIdentity FAIL reason=openDB \(site)#\(dramaID)")
            return nil
        }
        defer { sqlite3_close(db) }
        var ids: [Int: Int] = [:]
        var stmt: OpaquePointer?
        let epSQL = "SELECT episode_id, sort FROM drama_episodes WHERE site=? AND drama_id=?;"
        guard sqlite3_prepare_v2(db, epSQL, -1, &stmt, nil) == SQLITE_OK else {
            DramaDatabase.fail(db, "seriesIdentity episodes prepare")
            return nil
        }
        DramaDatabase.bind(stmt, 1, site)
        DramaDatabase.bind(stmt, 2, dramaID)
        while sqlite3_step(stmt) == SQLITE_ROW {
            ids[Int(sqlite3_column_int(stmt, 1))] = Int(sqlite3_column_int64(stmt, 0))
        }
        sqlite3_finalize(stmt)
        if ids.isEmpty {
            print("PLAYER_DBG [Service] seriesIdentity MISS reason=noEpisodes \(site)#\(dramaID)")
            return nil
        }
        print("PLAYER_DBG [Service] seriesIdentity \(site)#\(dramaID) episodes=\(ids.count)")
        return SeriesIdentity(site: site, dramaID: dramaID, episodeIDsBySort: ids)
    }

    static func load(site: String, dramaID: String) -> Entry? {
        guard let db = openDB() else { return nil }
        defer { sqlite3_close(db) }
        return readEntry(db, site: site, dramaID: dramaID)
    }

    /// 批量读取（审查 P1-④ 配套）：**一次连接**读多部剧——「我的」三分类装配此前
    /// 逐条 load，每条各开各关一次连接（上百部剧就是几百次开关，读放大）。
    /// 返回按 "site#dramaID" 键的字典；读不到的键缺席（与 load 返 nil 同语义）。
    static func rows(for keys: [(site: String, dramaID: String)]) -> [String: Entry] {
        guard !keys.isEmpty, let db = openDB() else { return [:] }
        defer { sqlite3_close(db) }
        var result: [String: Entry] = [:]
        for key in keys {
            let id = "\(key.site)#\(key.dramaID)"
            guard result[id] == nil else { continue }   // 同剧重复键只读一次
            if let entry = readEntry(db, site: key.site, dramaID: key.dramaID) {
                result[id] = entry
            }
        }
        return result
    }

    /// load 的逐剧读取体（连接由调用方开关）：load 单读与 rows 批量读共用一份 SQL
    private static func readEntry(_ db: OpaquePointer?, site: String, dramaID: String) -> Entry? {
        let infoSQL = "SELECT name, update_status, cover, intro, tags, fetched_at, page_meta FROM drama_cache WHERE site=? AND drama_id=?;"
        let epSQL = """
        SELECT episode_id, sort, playable, downloaded, folder, can_play, access_state
        FROM drama_episodes WHERE site=? AND drama_id=? ORDER BY sort;
        """
        var name: String?, status: String?, cover: String?, intro: String?, tags: String?, fetchedAt: String?
        var tagsSource: String?

        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, infoSQL, -1, &stmt, nil) == SQLITE_OK else {
            DramaDatabase.fail(db, "load info prepare"); return nil
        }
        DramaDatabase.bind(stmt, 1, site)
        DramaDatabase.bind(stmt, 2, dramaID)
        if sqlite3_step(stmt) == SQLITE_ROW {
            name = DramaDatabase.text(stmt, 0); status = DramaDatabase.text(stmt, 1); cover = DramaDatabase.text(stmt, 2)
            intro = DramaDatabase.text(stmt, 3); tags = DramaDatabase.text(stmt, 4); fetchedAt = DramaDatabase.text(stmt, 5)
            if let raw = DramaDatabase.text(stmt, 6),
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
            DramaDatabase.fail(db, "load episodes prepare"); return nil
        }
        DramaDatabase.bind(stmt, 1, site)
        DramaDatabase.bind(stmt, 2, dramaID)
        var accessNotes: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let id = Int(sqlite3_column_int64(stmt, 0))
            let sort = Int(sqlite3_column_int(stmt, 1))
            let playable = sqlite3_column_int(stmt, 2) != 0
            let downloaded = sqlite3_column_int(stmt, 3) != 0
            let folder = DramaDatabase.text(stmt, 4)
            // 详情接口侧的可播判定（saveDetail 落库）：与下载接口侧 playable 对照，
            // 两个源不一致时一眼定位是站点权限差异还是解析问题
            let detailCanPlay = sqlite3_column_type(stmt, 5) == SQLITE_NULL
                ? "?" : (sqlite3_column_int(stmt, 5) != 0 ? "1" : "0")
            let detailState = DramaDatabase.text(stmt, 6) ?? ""
            accessNotes.append("s\(sort):api=\(playable ? 1 : 0),dtl=\(detailCanPlay)/\(detailState.isEmpty ? "nil" : detailState)")
            episodes.append(ApiDramaEpisode(id: id, sort: sort, playable: playable,
                                         downloaded: downloaded, folder: folder))
        }
        sqlite3_finalize(stmt)
        if !episodes.isEmpty {
            print("PLAYER_DBG [CHECK] cacheLoad \(site)#\(dramaID) [\(accessNotes.joined(separator: " "))]")
        }
        return Entry(name: name, updateStatus: status, cover: cover, intro: intro, tags: tags,
                     tagsSource: tagsSource, episodes: episodes, fetchedAt: fetchedAt)
    }

    /// 追更行（审查 P1-④ 从 ProfileViewModel 下沉，AGENTS 5/7：VM 不写裸 SQL）：
    /// 「连载中」的剧（update_status 非完结），按最近抓取倒序，每剧附
    /// 「最后一集是否已下载」子查询——「已看完」筛选需要它，VM 只装配。
    struct ChasingRow {
        let site: String
        let dramaID: String
        let name: String
        let status: String
        let cover: String?
        /// 最后一集（sort 最大）是否已下载；无剧集行 → false
        let lastEpisodeDownloaded: Bool
    }

    static func chasingRows() -> [ChasingRow] {
        guard let db = openDB() else { return [] }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = """
        SELECT site, drama_id, name, update_status, cover, fetched_at,
               (SELECT e.downloaded FROM drama_episodes e
                 WHERE e.site = drama_cache.site AND e.drama_id = drama_cache.drama_id
                 ORDER BY e.sort DESC LIMIT 1) AS last_downloaded
        FROM drama_cache
        WHERE update_status IS NOT NULL AND update_status != ''
          AND update_status NOT LIKE '%完结%' AND update_status NOT LIKE '%全%'
        ORDER BY fetched_at DESC;
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            DramaDatabase.fail(db, "chasingRows prepare"); return []
        }
        defer { sqlite3_finalize(stmt) }
        var rows: [ChasingRow] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(ChasingRow(site: DramaDatabase.text(stmt, 0) ?? "",
                                   dramaID: DramaDatabase.text(stmt, 1) ?? "",
                                   name: DramaDatabase.text(stmt, 2) ?? "",
                                   status: DramaDatabase.text(stmt, 3) ?? "",
                                   cover: DramaDatabase.text(stmt, 4),
                                   // 无剧集行时 last_downloaded 为 NULL → 0 → 未看完，符合口径
                                   lastEpisodeDownloaded: sqlite3_column_int(stmt, 6) != 0))
        }
        return rows
    }

    /// 详情整包最近一次抓取时间（detail_fetched_at 列，ISO8601）；从未抓过/列为空返回 nil。
    /// 新鲜度判定用：15 天内不重抓详情（用户拍板 2026-11-13）， harvesting 据此闸门
    static func detailFetchedAt(site: String, dramaID: String) -> Date? {
        guard let db = openDB() else { return nil }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = "SELECT detail_fetched_at FROM drama_cache WHERE site=? AND drama_id=?;"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            // 关闭统一靠顶部 defer——这里再显式 close 是 double close（审查 P1-⑥）
            return nil
        }
        DramaDatabase.bind(stmt, 1, site)
        DramaDatabase.bind(stmt, 2, dramaID)
        var date: Date?
        if sqlite3_step(stmt) == SQLITE_ROW, let raw = DramaDatabase.text(stmt, 0) {
            date = ISO8601DateFormatter().date(from: raw)
        }
        sqlite3_finalize(stmt)
        return date
    }

    // MARK: 写 —— 剧集信息 + 集数列表（合并式 upsert，保留下载状态）

    /// 网络刷新返回的剧集信息落库；集数按集 ID 合并式 upsert：
    /// 新集合入、接口已不存在的集删除、既有集的 downloaded/folder 与每集元数据保留不动。
    /// 注意不能先 DELETE 全表再插（先删后插 ON CONFLICT 永不触发，会把下载标记与
    /// saveDetail 写入的每集元数据一起冲掉）。集列表以下载接口为准：详情接口多列的集
    /// （如广告集，DramaInfo 构造时已剔除）也一并清掉，下次进剧集页 saveDetail 会按接口现状重建。
    static func saveInfo(site: String, dramaID: String, info: DramaInfo) {
        guard let db = openDB() else { return }
        defer { sqlite3_close(db) }
        let now = ISO8601DateFormatter().string(from: Date())
        let newIDs = Set(info.episodes.map { $0.id })

        DramaDatabase.transaction(db) {
            DramaDatabase.execWrite(db, """
            INSERT INTO drama_cache (site, drama_id, name, update_status, fetched_at)
            VALUES (?,?,?,?,?)
            ON CONFLICT(site, drama_id) DO UPDATE SET
              name=excluded.name, update_status=excluded.update_status, fetched_at=excluded.fetched_at
            """, what: "info upsert") { stmt in
                DramaDatabase.bind(stmt, 1, site)
                DramaDatabase.bind(stmt, 2, dramaID)
                DramaDatabase.bind(stmt, 3, info.name)
                DramaDatabase.bind(stmt, 4, info.updateStatus ?? "")
                DramaDatabase.bind(stmt, 5, now)
            }

            // 以最新列表为准清掉接口已不存在的集：读现有 id 后逐个删，不 DELETE 全表
            var vanishedIDs: [Int64] = []
            var sel: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT episode_id FROM drama_episodes WHERE site=? AND drama_id=?;", -1, &sel, nil) == SQLITE_OK {
                DramaDatabase.bind(sel, 1, site)
                DramaDatabase.bind(sel, 2, dramaID)
                while sqlite3_step(sel) == SQLITE_ROW {
                    let id = sqlite3_column_int64(sel, 0)
                    if !newIDs.contains(Int(id)) { vanishedIDs.append(id) }
                }
            } else {
                DramaDatabase.fail(db, "saveInfo existing prepare")
            }
            sqlite3_finalize(sel)
            for id in vanishedIDs {
                DramaDatabase.execWrite(db, "DELETE FROM drama_episodes WHERE site=? AND drama_id=? AND episode_id=?;",
                                        what: "episode drop \(id)") { stmt in
                    DramaDatabase.bind(stmt, 1, site)
                    DramaDatabase.bind(stmt, 2, dramaID)
                    sqlite3_bind_int64(stmt, 3, id)
                }
            }

            for ep in info.episodes {
                DramaDatabase.execWrite(db, """
                INSERT INTO drama_episodes (site, drama_id, episode_id, sort, playable, downloaded, folder, updated_at)
                VALUES (?,?,?,?,?,0,NULL,?)
                ON CONFLICT(site, drama_id, episode_id) DO UPDATE SET
                  sort=excluded.sort, playable=excluded.playable, updated_at=excluded.updated_at
                """, what: "episode upsert \(ep.id)") { stmt in
                    DramaDatabase.bind(stmt, 1, site)
                    DramaDatabase.bind(stmt, 2, dramaID)
                    sqlite3_bind_int64(stmt, 3, Int64(ep.id))
                    sqlite3_bind_int(stmt, 4, Int32(ep.sort))
                    sqlite3_bind_int(stmt, 5, ep.playable ? 1 : 0)
                    DramaDatabase.bind(stmt, 6, now)
                }
            }
            print("PLAYER_DBG [Service] saveInfo \(site)#\(dramaID) episodes=\(info.episodes.count) dropped=\(vanishedIDs.count) droppedIDs=\(vanishedIDs.prefix(5))")
        }
    }

    /// 下载完成回调：该集标记已下载 + 记录落盘目录名（行不存在时补建）
    static func markDownloaded(site: String, dramaID: String, episodeID: Int, folder: String) {
        guard let db = openDB() else { return }
        defer { sqlite3_close(db) }
        DramaDatabase.execWrite(db, """
        INSERT INTO drama_episodes (site, drama_id, episode_id, downloaded, folder, updated_at)
        VALUES (?,?,?,?,?,?)
        ON CONFLICT(site, drama_id, episode_id) DO UPDATE SET
          downloaded=1, folder=excluded.folder, updated_at=excluded.updated_at
        """, what: "mark downloaded \(episodeID)") { stmt in
            DramaDatabase.bind(stmt, 1, site)
            DramaDatabase.bind(stmt, 2, dramaID)
            sqlite3_bind_int64(stmt, 3, Int64(episodeID))
            sqlite3_bind_int(stmt, 4, 1)
            DramaDatabase.bind(stmt, 5, folder)
            DramaDatabase.bind(stmt, 6, ISO8601DateFormatter().string(from: Date()))
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
            DramaDatabase.fail(db, "reconcile prepare"); return
        }
        DramaDatabase.bind(selectStmt, 1, site)
        DramaDatabase.bind(selectStmt, 2, dramaID)
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
            DramaDatabase.execWrite(db, "UPDATE drama_episodes SET downloaded=?, folder=?, updated_at=? WHERE site=? AND drama_id=? AND episode_id=?;",
                      what: "reconcile ep \(sort)") { stmt in
                sqlite3_bind_int(stmt, 1, downloaded ? 1 : 0)
                if let folder = folders[sort] {
                    DramaDatabase.bind(stmt, 2, folder)
                } else {
                    sqlite3_bind_null(stmt, 2)
                }
                DramaDatabase.bind(stmt, 3, now)
                DramaDatabase.bind(stmt, 4, site)
                DramaDatabase.bind(stmt, 5, dramaID)
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
            DramaDatabase.bind(sel, 1, site)
            DramaDatabase.bind(sel, 2, dramaID)
            if sqlite3_step(sel) == SQLITE_ROW, let raw = DramaDatabase.text(sel, 0),
               let old = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] {
                pageMeta = old
            }
        }
        sqlite3_finalize(sel)
        for (key, value) in update { pageMeta[key] = value }
        let metaJSON = (try? JSONSerialization.data(withJSONObject: pageMeta, options: [.sortedKeys]))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        DramaDatabase.execWrite(db, """
        INSERT INTO drama_cache (site, drama_id, cover, intro, tags, page_meta, fetched_at)
        VALUES (?,?,?,?,?,?,?)
        ON CONFLICT(site, drama_id) DO UPDATE SET
          cover=excluded.cover, intro=excluded.intro, tags=excluded.tags, page_meta=excluded.page_meta
        """, what: "page meta upsert") { stmt in
            DramaDatabase.bind(stmt, 1, site)
            DramaDatabase.bind(stmt, 2, dramaID)
            DramaDatabase.bind(stmt, 3, cover)
            DramaDatabase.bind(stmt, 4, intro)
            if let tags {
                DramaDatabase.bind(stmt, 5, tags)
            } else {
                sqlite3_bind_null(stmt, 5)
            }
            DramaDatabase.bind(stmt, 6, metaJSON)
            DramaDatabase.bind(stmt, 7, ISO8601DateFormatter().string(from: Date()))
        }
    }

    // MARK: 写 —— 详情接口整包落库（schema v2）

    /// 把剧集详情接口的响应**整包**存进 `api_detail`，同时把常用字段提升为列便于查询/展示。
    /// 提升列只是索引方便，任何字段都不会因为「没提升」而丢失；站点以后加字段也无需迁移。
    ///
    /// 不动 `name / update_status / fetched_at / page_meta / tags`：它们分别由下载接口与 DOM 收割维护，
    /// 详情接口的标题另存 `api_title`，两个来源互不覆盖。
    /// `rawJSON` 传拿到的原始响应体（明文详情 / 解密后的信封 / Nuxt payload 结构化回写）。
    static func saveDetail(site: String, dramaID: String, rawJSON: String, detail: DramaDetailData) {
        guard let db = openDB() else { return }
        defer { sqlite3_close(db) }
        let now = ISO8601DateFormatter().string(from: Date())
        let episodes = detail.episodes ?? []
        let related = detail.relatedList ?? []

        DramaDatabase.transaction(db) {
            // 1) 剧级：整包 + 提升列
            var names = ["site", "drama_id"]
            var setters: [(OpaquePointer?, Int32) -> Void] = []
            func addText(_ column: String, _ value: String?) {
                names.append(column)
                setters.append { stmt, i in
                    if let value { DramaDatabase.bind(stmt, i, value) } else { sqlite3_bind_null(stmt, i) }
                }
            }
            func addInt(_ column: String, _ value: Int?) {
                names.append(column)
                setters.append { stmt, i in
                    if let value { sqlite3_bind_int64(stmt, i, Int64(value)) } else { sqlite3_bind_null(stmt, i) }
                }
            }
            func addBool(_ column: String, _ value: Bool?) { addInt(column, value.map { $0 ? 1 : 0 }) }
            func addDouble(_ column: String, _ value: Double?) {
                names.append(column)
                setters.append { stmt, i in
                    if let value { sqlite3_bind_double(stmt, i, value) } else { sqlite3_bind_null(stmt, i) }
                }
            }
            func addJSON<T: Encodable>(_ column: String, _ value: T?) {
                guard let value, let data = try? JSONEncoder().encode(value),
                      let text = String(data: data, encoding: .utf8) else {
                    addText(column, nil); return
                }
                addText(column, text)
            }

            addText("api_detail", rawJSON)
            addText("detail_fetched_at", now)
            addText("api_title", detail.title)
            addDouble("score", detail.score)
            addText("cover", detail.cover)
            addText("social_cover", detail.socialCover)
            addText("intro", detail.description)
            addJSON("actor_list", detail.actorList)
            addInt("original", detail.original)
            addInt("serialize_status", detail.serializeStatus)
            addText("serialize_status_text", detail.serializeStatusText)
            addInt("episode_count", detail.episodeCount)
            addInt("play_count", detail.playCount)
            addText("play_count_text", detail.playCountText)
            addInt("like_count", detail.likeCount)
            addInt("chase_count", detail.chaseCount)
            addInt("comment_count", detail.commentCount)
            addInt("collect_count", detail.collectCount)
            addInt("current_episode_id", detail.currentEpisodeId)
            addInt("continue_episode_id", detail.continueEpisodeId)
            addInt("play_duration", detail.playDuration)
            addText("resolution", detail.resolution)
            addInt("video_width", detail.videoWidth)
            addInt("video_height", detail.videoHeight)
            addText("video_orientation", detail.videoOrientation)
            addBool("is_collected", detail.isCollected)
            addBool("is_chased", detail.isChased)
            addText("content_access_type", detail.contentAccessType)
            addInt("coin_price", detail.coinPrice)
            addText("share_url", detail.shareUrl)
            addText("share_title", detail.shareTitle)
            addText("share_cover", detail.shareCover)
            addBool("show_hot_badge", detail.showHotBadge)
            addBool("show_new", detail.showNew)
            addBool("show_completed", detail.showCompleted)
            addBool("show_hot", detail.showHot)
            addJSON("access_json", detail.access)
            addJSON("urge_json", detail.urge)

            let placeholders = Array(repeating: "?", count: names.count).joined(separator: ",")
            let updates = names.dropFirst(2).map { "\($0)=excluded.\($0)" }.joined(separator: ", ")
            DramaDatabase.execWrite(db, """
            INSERT INTO drama_cache (\(names.joined(separator: ","))) VALUES (\(placeholders))
            ON CONFLICT(site, drama_id) DO UPDATE SET \(updates)
            """, what: "saveDetail \(dramaID)") { stmt in
                DramaDatabase.bind(stmt, 1, site)
                DramaDatabase.bind(stmt, 2, dramaID)
                for (offset, setter) in setters.enumerated() { setter(stmt, Int32(offset + 3)) }
            }

            // 2) 每集元数据：行不存在时补建（详情接口可能比下载接口多列几集）
            // [CHECK] 详情接口每集权限原值：与下载接口 fetchInfo 的 access 日志对照，
            // 两个源不一致时能一眼看出是站点侧差异还是解析问题
            let accessDump = episodes.prefix(14).map { ep -> String in
                let a = ep.access
                return "s\(ep.sort)=\(a?.state ?? "nil"),cp=\(a?.canPlay.map { $0 ? "1" : "0" } ?? "?"),ct=\(a?.contentType ?? "nil")"
            }
            print("PLAYER_DBG [CHECK] saveDetail \(site)#\(dramaID) access [\(accessDump.joined(separator: " "))] trial=\(detail.access?.trialEpisodeCount ?? -1) reason=\(detail.access?.reason ?? "nil")")
            for ep in episodes {
                DramaDatabase.execWrite(db, """
                INSERT INTO drama_episodes (site, drama_id, episode_id, sort, title, duration, resolution,
                                            is_new, access_state, can_play, content_type, is_trial, updated_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(site, drama_id, episode_id) DO UPDATE SET
                  sort=excluded.sort, title=excluded.title, duration=excluded.duration,
                  resolution=excluded.resolution, is_new=excluded.is_new, access_state=excluded.access_state,
                  can_play=excluded.can_play, content_type=excluded.content_type,
                  is_trial=excluded.is_trial, updated_at=excluded.updated_at
                """, what: "saveDetail ep \(ep.id)") { stmt in
                    DramaDatabase.bind(stmt, 1, site)
                    DramaDatabase.bind(stmt, 2, dramaID)
                    sqlite3_bind_int64(stmt, 3, Int64(ep.id))
                    sqlite3_bind_int(stmt, 4, Int32(ep.sort))
                    DramaDatabase.bind(stmt, 5, ep.title)
                    sqlite3_bind_int64(stmt, 6, Int64(ep.duration ?? 0))
                    if let resolution = ep.resolution { DramaDatabase.bind(stmt, 7, resolution) } else { sqlite3_bind_null(stmt, 7) }
                    sqlite3_bind_int(stmt, 8, (ep.isNew ?? false) ? 1 : 0)
                    if let state = ep.access?.state { DramaDatabase.bind(stmt, 9, state) } else { sqlite3_bind_null(stmt, 9) }
                    sqlite3_bind_int(stmt, 10, (ep.access?.canPlay ?? false) ? 1 : 0)
                    if let type = ep.access?.contentType { DramaDatabase.bind(stmt, 11, type) } else { sqlite3_bind_null(stmt, 11) }
                    sqlite3_bind_int(stmt, 12, (ep.access?.isTrial ?? false) ? 1 : 0)
                    DramaDatabase.bind(stmt, 13, now)
                }
            }

            // 3) 推荐剧：整份快照替换（列表顺序有意义，用 position 保留）
            DramaDatabase.execWrite(db, "DELETE FROM drama_related WHERE site=? AND drama_id=?;",
                                    what: "saveDetail related clear") { stmt in
                DramaDatabase.bind(stmt, 1, site)
                DramaDatabase.bind(stmt, 2, dramaID)
            }
            for (index, item) in related.enumerated() {
                guard let videoID = item.videoId else { continue }
                DramaDatabase.execWrite(db, """
                INSERT INTO drama_related (site, drama_id, related_video_id, title, cover, tags,
                                           play_count, play_count_text, serialize_status_text,
                                           content_access_type, position, updated_at)
                VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(site, drama_id, related_video_id) DO UPDATE SET
                  title=excluded.title, cover=excluded.cover, tags=excluded.tags,
                  play_count=excluded.play_count, play_count_text=excluded.play_count_text,
                  serialize_status_text=excluded.serialize_status_text,
                  content_access_type=excluded.content_access_type,
                  position=excluded.position, updated_at=excluded.updated_at
                """, what: "saveDetail related \(videoID)") { stmt in
                    DramaDatabase.bind(stmt, 1, site)
                    DramaDatabase.bind(stmt, 2, dramaID)
                    sqlite3_bind_int64(stmt, 3, Int64(videoID))
                    if let title = item.title { DramaDatabase.bind(stmt, 4, title) } else { sqlite3_bind_null(stmt, 4) }
                    if let cover = item.cover { DramaDatabase.bind(stmt, 5, cover) } else { sqlite3_bind_null(stmt, 5) }
                    if let tags = item.tags { DramaDatabase.bind(stmt, 6, tags.joined(separator: " ")) } else { sqlite3_bind_null(stmt, 6) }
                    sqlite3_bind_int64(stmt, 7, Int64(item.playCount ?? 0))
                    if let text = item.playCountText { DramaDatabase.bind(stmt, 8, text) } else { sqlite3_bind_null(stmt, 8) }
                    if let status = item.serializeStatusText { DramaDatabase.bind(stmt, 9, status) } else { sqlite3_bind_null(stmt, 9) }
                    if let access = item.contentAccessType { DramaDatabase.bind(stmt, 10, access) } else { sqlite3_bind_null(stmt, 10) }
                    sqlite3_bind_int(stmt, 11, Int32(index))
                    DramaDatabase.bind(stmt, 12, now)
                }
            }
        }
        print("CACHE OK[saveDetail] \(site)#\(dramaID) bytes=\(rawJSON.count) episodes=\(episodes.count) related=\(related.count)")
    }

    /// 读回整包详情原文（后续要用未提升的字段时从这里解析，不必再发请求）
    static func rawDetail(site: String, dramaID: String) -> String? {
        guard let db = openDB() else { return nil }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT api_detail FROM drama_cache WHERE site=? AND drama_id=?;", -1, &stmt, nil) == SQLITE_OK else {
            DramaDatabase.fail(db, "rawDetail prepare"); return nil
        }
        defer { sqlite3_finalize(stmt) }
        DramaDatabase.bind(stmt, 1, site)
        DramaDatabase.bind(stmt, 2, dramaID)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return DramaDatabase.text(stmt, 0)
    }

    /// 该剧的推荐剧快照（按接口给的顺序），「为你推荐」专区与本地推荐算法共用。
    /// 8 列全读：卡片角标/播放量文案/权限都在表里，不需要再解析整包（整包是权威，提升列只为查询）。
    static func relatedDramas(site: String, dramaID: String) -> [RecommendedDrama] {
        guard let db = openDB() else { return [] }
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        let sql = """
        SELECT related_video_id, title, cover, tags, play_count,
               play_count_text, serialize_status_text, content_access_type
        FROM drama_related
        WHERE site=? AND drama_id=? ORDER BY position;
        """
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            DramaDatabase.fail(db, "relatedDramas prepare"); return []
        }
        defer { sqlite3_finalize(stmt) }
        DramaDatabase.bind(stmt, 1, site)
        DramaDatabase.bind(stmt, 2, dramaID)
        var result: [RecommendedDrama] = []
        var localCoverHits = 0
        while sqlite3_step(stmt) == SQLITE_ROW {
            let tags = (DramaDatabase.text(stmt, 3) ?? "").split(separator: " ").map(String.init)
            let videoID = Int(sqlite3_column_int64(stmt, 0))
            var cover = DramaDatabase.text(stmt, 2)
            // 封面列存的是密文图床 URL（站点 JS 解密后才能展示），AsyncImage 直连必败：
            // 收割器已把解密后的图按推荐剧 id 落了本地缓存，命中则换成本地文件 URL
            if let remote = cover, !remote.isEmpty,
               let local = DramaCoverCache.validLocalURL(site: site, dramaID: String(videoID)) {
                cover = local.absoluteString
                localCoverHits += 1
            }
            result.append(RecommendedDrama(
                videoID: videoID,
                title: DramaDatabase.text(stmt, 1),
                cover: cover,
                tags: tags,
                playCount: Int(sqlite3_column_int64(stmt, 4)),
                playCountText: DramaDatabase.text(stmt, 5),
                serializeStatusText: DramaDatabase.text(stmt, 6),
                contentAccessType: DramaDatabase.text(stmt, 7)))
        }
        print("CACHE OK[relatedDramas] \(site)#\(dramaID) rows=\(result.count) coverLocal=\(localCoverHits)/\(result.count)")
        return result
    }

    /// 读回整包详情并解码，供「剧集档案」展示那些没提升为列的字段（权限 / 催更 / 分享 / 角标等）。
    /// 明文与信封形态存的是真原文；Nuxt payload 形态存的是模型结构化回写，只含模型声明的字段。
    /// 解码失败只打日志返回 nil，VM 据此隐藏档案区，绝不编造字段值。
    static func detailData(site: String, dramaID: String) -> DramaDetailData? {
        guard let raw = rawDetail(site: site, dramaID: dramaID),
              let data = raw.data(using: .utf8) else { return nil }
        do {
            return try JSONDecoder().decode(DramaDetailData.self, from: data)
        } catch {
            print("CACHE FAIL[detailData] \(site)#\(dramaID) error=\(error.localizedDescription)")
            return nil
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
