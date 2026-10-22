import Foundation

// MARK: - 引擎输出的数据结构（engine.py / autoswitch.py 的 JSON）

/// 一个额度窗口（5 小时或每周）
struct UsageWindow: Decodable {
    let used: Double
    let resetAt: Double
    let window: Double?
    enum CodingKeys: String, CodingKey { case used, window; case resetAt = "reset_at" }

    /// 剩余百分比；重置时间已过就当已重置
    func remaining(now: Double) -> Double {
        resetAt > 0 && resetAt <= now ? 100 : max(0, min(100, 100 - used))
    }
    /// 查询时刻（Usage 解码时填进来），用来判断窗口是否已开始计时
    var fetchedAt: Double = 0
    /// 本机点「开始计时」成功的时刻（只填给 5 小时窗口）
    var startedAt: Double = 0

    /// 还没开始计时：服务端给的重置时间是「查询时刻 + 窗口长度」，每次查都会往后挪。
    /// 不能只看「已用 0%」：发过一句极短的请求后窗口已开始计时，已用仍可能显示 0%；
    /// 刚起算的几分钟里重置时间也仍约等于「查询时刻 + 窗口长度」，所以先看本机记的起算时刻
    var untouched: Bool {
        guard used <= 0 else { return false }
        guard let window, window > 0, fetchedAt > 0 else { return true }
        if startedAt > 0 && startedAt >= resetAt - window - 60 { return false }   // 起算发生在当前这个窗口里
        return resetAt - fetchedAt >= window - 120
    }
}

struct Usage: Decodable {
    let at: Double
    let primary: UsageWindow?
    let secondary: UsageWindow?
    let error: String
    let availableAt: Double      // 0 现在可用；>0 到那时恢复；-1 没数据
    let blockReason: String
    let limitType: String        // rate_limit_reached / workspace_owner_credits_depleted / 空
    let resets: Int              // 可用的免费额度重置券

    enum CodingKeys: String, CodingKey { case at, primary, secondary, error, availableAt, blockReason, limitType, resets, startedAt }

    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        at = try c.decode(Double.self, forKey: .at)
        var p = try c.decodeIfPresent(UsageWindow.self, forKey: .primary)
        var w = try c.decodeIfPresent(UsageWindow.self, forKey: .secondary)
        p?.fetchedAt = at
        w?.fetchedAt = at
        p?.startedAt = try c.decodeIfPresent(Double.self, forKey: .startedAt) ?? 0
        primary = p
        secondary = w
        error = try c.decode(String.self, forKey: .error)
        availableAt = try c.decode(Double.self, forKey: .availableAt)
        blockReason = try c.decode(String.self, forKey: .blockReason)
        limitType = try c.decode(String.self, forKey: .limitType)
        resets = try c.decode(Int.self, forKey: .resets)
    }
}

/// 一个账号槽位
struct Slot: Identifiable, Decodable, Equatable {
    let slot: String
    let name: String
    let workspace: String
    let email: String
    let acct: String
    let plan: String
    let current: Bool
    let days: Int
    let lastExit: String
    let ok: Bool
    let needsLogin: Bool
    let usage: Usage
    let wechat: String?
    var id: String { slot }

    static func == (a: Slot, b: Slot) -> Bool { a.slot == b.slot }

    /// 显示名：自定义名 > 官方 workspace 名 > 个人空间
    var title: String {
        if !name.isEmpty { return name }
        if !workspace.isEmpty { return workspace }
        return plan == "team" ? String(acct.prefix(8)) : "个人空间"
    }
    var planLabel: String { Slot.planLabel(plan) }
    static func planLabel(_ p: String) -> String {
        switch p {
        case "team": return "Business"
        case "plus": return "Plus"
        case "pro":  return "Pro"
        case "free": return "Free"
        case "": return "—"
        default:     return p.capitalized
        }
    }
    func remaining5h(_ now: Double) -> Double { usage.primary?.remaining(now: now) ?? -1 }
    func remainingWeek(_ now: Double) -> Double { usage.secondary?.remaining(now: now) ?? -1 }
    /// 5 小时窗口下次重置的时刻；已重置、还没开始计时、没数据的排最后（和 autoswitch.next_reset 一致）
    func nextReset5h(_ now: Double) -> Double {
        guard let w = usage.primary, w.resetAt > now, !w.untouched else { return .infinity }
        return w.resetAt
    }
    func exhaustedUntil(_ now: Double) -> Double? { usage.availableAt > now ? usage.availableAt : nil }
    /// 5 小时或本周窗口用满、还没到重置时间：恢复时刻以它为准
    func windowFull(_ now: Double) -> Bool {
        [usage.primary, usage.secondary].contains { w in w.map { $0.resetAt > now && $0.used >= 100 } ?? false }
    }
    /// 只因为空间 credits 用完而不可用（两个窗口都没满）：什么时候恢复要看空间所有者。
    /// 窗口满了时服务端也常报 workspace_owner_credits_depleted（意思是空间没 credits 让你超额续用），那种仍按重置时间恢复
    func creditsOnly(_ now: Double) -> Bool { usage.limitType == "workspace_owner_credits_depleted" && !windowFull(now) }
    func usable(_ now: Double) -> Bool { !needsLogin && usage.availableAt >= 0 && usage.availableAt <= now }
}

/// 自动切号守护进程的状态
struct AutoStatus: Decodable {
    let enabled: Bool
    let alive: Bool
    let phase: String
    let text: String
    let waitUntil: Double
    let queue: Int
    static let empty = AutoStatus(enabled: false, alive: true, phase: "", text: "", waitUntil: 0, queue: 0)
}

struct AutoConfig: Decodable {
    var enabled: Bool
    var prompt: String
    var stall_nudge: Bool
    var order: String
    var auto_start: Bool
    var auto_continue: Bool
    var continue_max: Int
    var quiet_switch: Bool
    var skip: [String]
    static let empty = AutoConfig(enabled: false, prompt: "继续", stall_nudge: true, order: "alpha", auto_start: false,
                                  auto_continue: false, continue_max: 5, quiet_switch: true, skip: [])
}

struct ListPayload: Decodable {
    let slots: [Slot]; let running: Bool; let auto: AutoStatus; let config: AutoConfig; let unread: Int
}

/// 一个主对话（Codex 线程）
struct Session: Identifiable, Decodable {
    let thread: String
    let title: String
    let project: String
    let cwd: String
    let status: String          // running / stalled / limited / interrupted / aborted / error / done / idle
    let error: String
    let turnStartedAt: Double
    let lastActivity: Double
    let subagents: Int
    let queued: Bool
    let slot: String?           // 跑在哪个账号（槽位字母）；按切号历史推算，可能为空
    let email: String?
    var id: String { thread }
    var displayTitle: String { title.isEmpty ? "未命名对话 · \(thread.prefix(8))" : title }
    var isActive: Bool { status == "running" || status == "stalled" }
}

struct SessionsPayload: Decodable { let sessions: [Session] }

// MARK: - 账号目录（空间 / 订阅 / 成员，全部来自接口）

struct Subscription: Decodable, Hashable {
    let active: Bool
    let plan: String
    let renewsAt: Double
    let expiresAt: Double
    let cancelsAt: Double
    let willRenew: Bool
    let billing: String
    let currency: String
    let activeStart: Double
    let seatsUsed: Int
    let seatsTotal: Int
    let discount: String
    let delinquent: Bool
    let platform: String
    let trial: Bool

    /// 下一个关键时刻：会续费就是续费日，否则是到期日
    var nextDate: Double {
        guard active else { return 0 }
        if cancelsAt > 0 { return cancelsAt }
        return willRenew ? renewsAt : expiresAt
    }
    var nextLabel: String { !active ? "未订阅" : (willRenew && cancelsAt == 0 ? "续费" : "到期") }
    var billingText: String {
        switch billing { case "monthly": return "月付"; case "yearly", "annual": return "年付"; default: return billing }
    }
    var platformText: String {
        switch platform {
        case "chatgpt_web": return "网页"
        case "chatgpt_mobile_android": return "Android"
        case "chatgpt_mobile_ios": return "iOS"
        default: return platform
        }
    }
}

struct Member: Identifiable, Decodable, Hashable {
    let id: String
    let email: String
    let name: String
    let role: String
    let seat: String
    let joined: Double
    let deactivatedAt: Double
    let wechat: String?
    let nextPay: Double?        // 下次交费日（当天 0 点）；所有者 / 自己的账号没有
    let payManual: Bool?        // 交费日是不是手动改过
    let paidThrough: Double?    // 已交到哪一期（那期的应交日）
    let paidMarked: Bool?       // 在台账里标记过已交（没标记过的按加入日推算默认值）
    var active: Bool { deactivatedAt == 0 }
    var isOwner: Bool { role == "account-owner" }
}

struct Invite: Identifiable, Decodable, Hashable {
    var id: String { email + "\(created)" }
    let email: String
    let role: String
    let created: Double
}

struct Workspace: Identifiable, Decodable, Hashable {
    struct Access: Decodable, Hashable { let email: String; let role: String; let viaSlot: String }
    let id: String
    let name: String
    let structure: String
    let plan: String
    let planName: String
    let deactivated: Bool
    let created: Double
    let slots: [String]
    let access: [Access]
    let sub: Subscription
    let members: [Member]?
    let invites: [Invite]
    let errors: [String]

    var isTeam: Bool { structure == "workspace" }
    var displayName: String {
        if !name.isEmpty { return name }
        return "个人空间 · \(access.first?.email ?? "")"
    }
    var myRole: String { access.first.map { Workspace.roleText($0.role) } ?? "" }
    /// 所有者邮箱：成员里的 account-owner，查不到成员时用能进这个空间的我的账号
    var ownerEmail: String { members?.first { $0.isOwner && $0.active }?.email ?? access.first?.email ?? "" }
    var activeMembers: [Member] { (members ?? []).filter(\.active) }
    func newMembers(now: Double, days: Double = 3) -> [Member] {
        activeMembers.filter { $0.joined > 0 && now - $0.joined <= days * 86400 && $0.role != "account-owner" }
    }

    static func roleText(_ r: String) -> String {
        switch r {
        case "account-owner": return "所有者"
        case "account-admin", "admin": return "管理员"
        case "standard-user": return "成员"
        default: return r
        }
    }
}

struct ResetCredit: Decodable, Hashable, Identifiable {
    let id: String
    let title: String
    let status: String
    let expiresAt: Double
    let grantedAt: Double
}

struct Person: Decodable, Hashable, Identifiable {
    let email: String
    let name: String
    let userId: String
    let created: Double
    let mfa: Bool
    let country: String
    let slots: [String]
    let resetCredits: [ResetCredit]
    let wechat: String?
    var id: String { email }
    var availableResets: [ResetCredit] { resetCredits.filter { $0.status == "available" } }
}

struct Directory: Decodable {
    let at: Double
    let people: [Person]
    let workspaces: [Workspace]
    let errors: [String]
    static let empty = Directory(at: 0, people: [], workspaces: [], errors: [])

    func workspace(_ id: String) -> Workspace? { workspaces.first { $0.id == id } }
    func person(_ email: String) -> Person? { people.first { $0.email == email } }
}

// MARK: - 消息中心

struct Notice: Identifiable, Decodable, Hashable {
    let id: String
    let kind: String            // billing / member / quota / switch / session
    let level: String           // info / warn / critical
    let title: String
    let body: String
    let at: Double
    let created: Double
    let read: Bool
    let ws: String
    let slot: String
}

struct NoticesPayload: Decodable { let items: [Notice]; let unread: Int }

struct Simple: Decodable { let ok: Bool; let err: String?; let slot: String?; let email: String?; let plan: String? }
struct Current: Decodable { let acct: String; let email: String; let plan: String; let known: Bool }

/// 一行日志
struct LogLine: Identifiable {
    enum Source: String { case auto = "自动切号", manager = "账号操作" }
    let id: Int
    let time: String
    let text: String
    let source: Source
}

// MARK: - 时间显示

enum TimeText {
    private static let hm: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm"; return f }()
    private static let mdhm: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MM-dd HH:mm"; return f }()
    private static let ymd: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()

    /// 今天只显示时刻，明天加「明天」，更远显示日期
    static func short(_ epoch: Double) -> String {
        let d = Date(timeIntervalSince1970: epoch)
        let cal = Calendar.current
        if cal.isDateInToday(d) { return hm.string(from: d) }
        if cal.isDateInTomorrow(d) { return "明天 " + hm.string(from: d) }
        return mdhm.string(from: d)
    }

    static func date(_ epoch: Double) -> String { epoch > 0 ? ymd.string(from: Date(timeIntervalSince1970: epoch)) : "—" }

    /// 「3 分钟前」「2 小时前」
    static func ago(_ epoch: Double, now: Double = Date().timeIntervalSince1970) -> String {
        let s = max(0, now - epoch)
        if s < 60 { return "刚刚" }
        if s < 3600 { return "\(Int(s / 60)) 分钟前" }
        if s < 86400 { return "\(Int(s / 3600)) 小时前" }
        return "\(Int(s / 86400)) 天前"
    }

    /// 「1 小时 5 分」
    static func span(_ seconds: Double) -> String {
        let m = Int(max(0, seconds) / 60)
        if m < 60 { return "\(m) 分钟" }
        if m < 1440 { return "\(m / 60) 小时 \(m % 60) 分" }
        return "\(m / 1440) 天 \(m % 1440 / 60) 小时"
    }

    /// 「还有 1 小时 5 分」
    static func until(_ epoch: Double, now: Double) -> String {
        epoch <= now ? "已到" : "还有 " + span(epoch - now)
    }

    /// 距今天数（向上取整），用于「3 天后续费」
    static func daysLeft(_ epoch: Double, now: Double) -> Int { Int(ceil((epoch - now) / 86400)) }
}
