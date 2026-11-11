import Foundation

// MARK: - 短剧详情核心数据模型
struct DramaDetailData: Codable {
    
    // MARK: - 基础信息
    /// 短剧唯一 ID
    let videoId: Int
    
    /// 短剧标题
    let title: String
    
    /// 评分（当前数据为 0）
    let score: Double?
    
    /// 封面图 URL
    let cover: String?
    
    /// 社交分享封面图 URL
    let socialCover: String?
    
    /// 剧情简介
    let description: String?
    
    /// 标签数组（如：反差、人妻、都市、大女主）
    let tags: [String]?
    
    /// 演员列表（当前为空数组）
    let actorList: [String]?
    
    /// 是否原创（1 表示原创）
    let original: Int?
    
    /// 连载状态（数字）
    let serializeStatus: Int?
    
    /// 连载状态文字（如：连载中）
    let serializeStatusText: String?
    
    /// 总集数
    let episodeCount: Int?
    
    // MARK: - 互动数据
    /// 播放量（原始数字）
    let playCount: Int?
    
    /// 播放量文字（如：16W）
    let playCountText: String?
    
    /// 点赞数
    let likeCount: Int?
    
    /// 追剧/收藏数
    let chaseCount: Int?
    
    /// 评论数
    let commentCount: Int?
    
    /// 收藏数（另一个统计）
    let collectCount: Int?
    
    // MARK: - 剧集相关
    /// 剧集列表
    let episodes: [Episode]?
    
    /// 当前正在播放的剧集 ID
    let currentEpisodeId: Int?
    
    /// 继续观看的剧集 ID
    let continueEpisodeId: Int?
    
    /// 已播放时长（秒）
    let playDuration: Int?
    
    // MARK: - 视频规格
    /// 分辨率文字（如：1080x1920）
    let resolution: String?
    
    /// 视频宽度
    let videoWidth: Int?
    
    /// 视频高度
    let videoHeight: Int?
    
    /// 视频方向（portrait / landscape）
    let videoOrientation: String?
    
    // MARK: - 分享相关
    /// 分享链接
    let shareUrl: String?
    
    /// 分享标题（通常与 title 相同）
    let shareTitle: String?
    
    /// 分享封面（通常与 cover 相同）
    let shareCover: String?
    
    // MARK: - 角标 / 状态展示
    /// 角标信息
    let badge: BadgeInfo?
    
    /// 是否显示热门角标
    let showHotBadge: Bool?
    
    /// App 内角标
    let appBadge: AppBadge?
    
    /// 新剧截止时间戳
    let newUntil: Int?
    
    /// 是否显示“新”标签
    let showNew: Bool?
    
    /// 是否显示“已完结”标签
    let showCompleted: Bool?
    
    /// 是否显示热门标签
    let showHot: Bool?
    
    /// 封面上的角标
    let coverBadge: CoverBadge?
    
    // MARK: - 付费与权限
    /// 内容访问类型（free / vip / coin 等）
    let contentAccessType: String?
    
    /// 金币价格
    let coinPrice: Int?
    
    /// 是否已收藏
    let isCollected: Bool?
    
    /// 是否已追剧
    let isChased: Bool?
    
    // MARK: - 其他
    /// 相关推荐列表
    let relatedList: [RelatedDrama]?
    
    /// 访问权限信息
    let access: AccessInfo?
    
    /// 催更信息
    let urge: UrgeInfo?
    
    /// SEO 信息
    let seo: SEOInfo?
    
    // MARK: - CodingKeys
    enum CodingKeys: String, CodingKey {
        case videoId = "video_id"
        case title
        case score
        case cover
        case socialCover = "social_cover"
        case description
        case tags
        case actorList = "actor_list"
        case original
        case serializeStatus = "serialize_status"
        case serializeStatusText = "serialize_status_text"
        case episodeCount = "episode_count"
        case playCount = "play_count"
        case playCountText = "play_count_text"
        case likeCount = "like_count"
        case chaseCount = "chase_count"
        case commentCount = "comment_count"
        case collectCount = "collect_count"
        case episodes
        case currentEpisodeId = "current_episode_id"
        case continueEpisodeId = "continue_episode_id"
        case playDuration = "play_duration"
        case resolution
        case videoWidth = "video_width"
        case videoHeight = "video_height"
        case videoOrientation = "video_orientation"
        case shareUrl = "share_url"
        case shareTitle = "share_title"
        case shareCover = "share_cover"
        case badge
        case showHotBadge = "show_hot_badge"
        case appBadge = "app_badge"
        case newUntil = "new_until"
        case showNew = "show_new"
        case showCompleted = "show_completed"
        case showHot = "show_hot"
        case coverBadge = "cover_badge"
        case contentAccessType = "content_access_type"
        case coinPrice = "coin_price"
        case isCollected = "is_collected"
        case isChased = "is_chased"
        case relatedList = "related_list"
        case access
        case urge
        case seo
    }
}

// MARK: - 剧集模型
struct Episode: Codable {
    /// 剧集 ID
    let id: Int
    
    /// 集数排序（第几集）
    let sort: Int
    
    /// 剧集标题
    let title: String
    
    /// 分辨率
    let resolution: String?
    
    /// 时长（秒）
    let duration: Int?
    
    /// 是否为新剧集
    let isNew: Bool?
    
    /// 新剧集过期时间
    let newExpiresAt: Int?
    
    /// 访问权限信息
    let access: EpisodeAccess?
    
    enum CodingKeys: String, CodingKey {
        case id, sort, title, resolution, duration
        case isNew = "is_new"
        case newExpiresAt = "new_expires_at"
        case access
    }
}

// MARK: - 剧集访问权限
struct EpisodeAccess: Codable {
    /// 状态（free / locked 等）
    let state: String?
    
    /// 是否可播放
    let canPlay: Bool?
    
    /// 内容类型（free / coin / vip）
    let contentType: String?
    
    /// 是否试看
    let isTrial: Bool?
    
    enum CodingKeys: String, CodingKey {
        case state
        case canPlay = "can_play"
        case contentType = "content_type"
        case isTrial = "is_trial"
    }
}

// MARK: - 角标信息
struct BadgeInfo: Codable {
    let type: String?
    let text: String?
    let expiresAt: Int?
    let serverTime: Int?
    
    enum CodingKeys: String, CodingKey {
        case type, text
        case expiresAt = "expires_at"
        case serverTime = "server_time"
    }
}

// MARK: - App 角标
struct AppBadge: Codable {
    let type: String?
    let text: String?
}

// MARK: - 封面角标
struct CoverBadge: Codable {
    let type: String?
    let text: String?
}

// MARK: - 相关推荐短剧
struct RelatedDrama: Codable {
    let videoId: Int?
    let title: String?
    let cover: String?
    let tags: [String]?
    let playCount: Int?
    let playCountText: String?
    let original: Int?
    let serializeStatus: Int?
    let serializeStatusText: String?
    let episodeId: Int?
    let isChased: Bool?
    let badge: BadgeInfo?
    let showHotBadge: Bool?
    let appBadge: AppBadge?
    let newUntil: Int?
    let showNew: Bool?
    let showCompleted: Bool?
    let showHot: Bool?
    let coverBadge: CoverBadge?
    let contentAccessType: String?
    let coinPrice: Int?
    
    enum CodingKeys: String, CodingKey {
        case videoId = "video_id"
        case title, cover, tags
        case playCount = "play_count"
        case playCountText = "play_count_text"
        case original
        case serializeStatus = "serialize_status"
        case serializeStatusText = "serialize_status_text"
        case episodeId = "episode_id"
        case isChased = "is_chased"
        case badge
        case showHotBadge = "show_hot_badge"
        case appBadge = "app_badge"
        case newUntil = "new_until"
        case showNew = "show_new"
        case showCompleted = "show_completed"
        case showHot = "show_hot"
        case coverBadge = "cover_badge"
        case contentAccessType = "content_access_type"
        case coinPrice = "coin_price"
    }
}

// MARK: - 访问权限信息
struct AccessInfo: Codable {
    let contentType: String?
    let state: String?
    let canPlay: Bool?
    let canUnlock: Bool?
    let reason: String?
    let nextAction: String?
    let trialEpisodeCount: Int?
    let coinPrice: Int?
    let isPurchased: Bool?
    let validUntil: Int?
    
    enum CodingKeys: String, CodingKey {
        case contentType = "content_type"
        case state
        case canPlay = "can_play"
        case canUnlock = "can_unlock"
        case reason
        case nextAction = "next_action"
        case trialEpisodeCount = "trial_episode_count"
        case coinPrice = "coin_price"
        case isPurchased = "is_purchased"
        case validUntil = "valid_until"
    }
}

// MARK: - 催更信息
struct UrgeInfo: Codable {
    let videoId: Int?
    let urgeDate: String?
    let urgedToday: Bool?
    let urgeEnabled: Bool?
    let canUrge: Bool?
    let urgeCount: Int?
    
    enum CodingKeys: String, CodingKey {
        case videoId = "video_id"
        case urgeDate = "urge_date"
        case urgedToday = "urged_today"
        case urgeEnabled = "urge_enabled"
        case canUrge = "can_urge"
        case urgeCount = "urge_count"
    }
}

// MARK: - SEO 信息
struct SEOInfo: Codable {
    let title: String?
    let description: String?
    let robots: String?
    let keywords: String?
    let ogTitle: String?
    let ogDescription: String?
    let ogType: String?
    let ogSiteName: String?
    let ogLocale: String?
    let ogImageAlt: String?
    let twitterCard: String?
    let twitterSite: String?
    let twitterTitle: String?
    let twitterDescription: String?
    let ogImage: String?
    let twitterImage: String?
    
    enum CodingKeys: String, CodingKey {
        case title, description, robots, keywords
        case ogTitle, ogDescription, ogType, ogSiteName, ogLocale, ogImageAlt
        case twitterCard, twitterSite, twitterTitle, twitterDescription
        case ogImage, twitterImage
    }
}
