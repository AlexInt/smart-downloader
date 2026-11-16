import Foundation
import SQLite3

/// 剧集收藏持久化（Service）：按剧 id（site, drama_id）存 SQLite `drama_favorites` 表。
/// 用户拍板 2026-11-13：从 UserDefaults 迁到库——收藏是「关系」数据，入库后可与
/// drama_cache / episode_actions / drama_related JOIN（基于收藏的本地推荐、最近收藏排序）。
/// 语义：收藏 = 有行（created_at 记收藏时间），取消 = 删行；读写永不回退旧 UserDefaults 键。
/// AGENTS 第 5 条：Service 只做读写，无业务判断；第 7 条：建表与旧数据搬迁都在 DramaDatabase。
/// 主线程约定：调用点在主线程（与 DramaCache 同）。
struct DramaFavorites {

    /// 该剧是否已收藏
    func isFavorite(site: String, dramaID: String) -> Bool {
        guard let db = DramaDatabase.open() else { return false }
        // 连接必须关（审查 P1-③：三方法此前全不关，每次调用泄漏一个连接，
        // 长会话可致 fd 耗尽、收藏静默失效）；与 DramaCache 同款自开自关
        defer { sqlite3_close(db) }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT 1 FROM drama_favorites WHERE site=? AND drama_id=? LIMIT 1;",
                                 -1, &stmt, nil) == SQLITE_OK else { return false }
        DramaDatabase.bind(stmt, 1, site)
        DramaDatabase.bind(stmt, 2, dramaID)
        return sqlite3_step(stmt) == SQLITE_ROW
    }

    /// 收藏 / 取消收藏。收藏时间每次重置（重复收藏视为最近一次动作，供「最近收藏」排序）
    func setFavorite(_ value: Bool, site: String, dramaID: String) {
        guard let db = DramaDatabase.open() else {
            print("PLAYER_DBG [Service] dramaFavorite FAIL reason=noDB site=\(site) id=\(dramaID)")
            return
        }
        defer { sqlite3_close(db) }
        if value {
            let now = ISO8601DateFormatter().string(from: Date())
            DramaDatabase.execWrite(db, """
            INSERT INTO drama_favorites (site, drama_id, created_at) VALUES (?,?,?)
            ON CONFLICT(site, drama_id) DO UPDATE SET created_at=excluded.created_at
            """, what: "dramaFavorite upsert \(site)#\(dramaID)") { stmt in
                DramaDatabase.bind(stmt, 1, site)
                DramaDatabase.bind(stmt, 2, dramaID)
                DramaDatabase.bind(stmt, 3, now)
            }
            print("PLAYER_DBG [Service] dramaFavorite SET site=\(site) id=\(dramaID)")
        } else {
            DramaDatabase.execWrite(db, "DELETE FROM drama_favorites WHERE site=? AND drama_id=?;",
                                    what: "dramaFavorite delete \(site)#\(dramaID)") { stmt in
                DramaDatabase.bind(stmt, 1, site)
                DramaDatabase.bind(stmt, 2, dramaID)
            }
            print("PLAYER_DBG [Service] dramaFavorite UNSET site=\(site) id=\(dramaID)")
        }
    }

    /// 全部收藏（按收藏时间倒序）：关系查询入口——收藏列表 / 本地推荐算法从这里取，
    /// 剧名等展示字段用 (site, drama_id) JOIN drama_cache 获取，本表不冗余存
    func favoriteDramas() -> [(site: String, dramaID: String, createdAt: String?)] {
        guard let db = DramaDatabase.open() else { return [] }
        defer { sqlite3_close(db) }   // 与 isFavorite 同款：连接用完即关
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, """
        SELECT site, drama_id, created_at FROM drama_favorites ORDER BY created_at DESC;
        """, -1, &stmt, nil) == SQLITE_OK else { return [] }
        var result: [(site: String, dramaID: String, createdAt: String?)] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let site = DramaDatabase.text(stmt, 0) ?? ""
            let dramaID = DramaDatabase.text(stmt, 1) ?? ""
            let createdAt = DramaDatabase.text(stmt, 2)
            result.append((site: site, dramaID: dramaID, createdAt: createdAt))
        }
        return result
    }
}
