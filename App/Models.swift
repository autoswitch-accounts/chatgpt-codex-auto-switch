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
        return plan == "team" ? String(acct.prefix(8)) : L("个人空间")
    }
    var planLabel: String { Slot.planLabel(plan) }
    /// 这个人在空间里的席位档位：同一个团队空间里，有人是普通席位（plan_type team），
    /// 有人是 Pro Lite 席位（self_serve_business_prolite）。plan 取自这个槽位自己的凭证，所以按人区分
    var seatTier: String? { plan.hasSuffix("_prolite") ? "Pro Lite" : nil }
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
    /// 5 小时剩余；没有 5 小时限额、只有每周额度的套餐按每周剩余算（排序、图表用）
    func remaining5h(_ now: Double) -> Double { usage.primary?.remaining(now: now) ?? usage.secondary?.remaining(now: now) ?? -1 }
    /// 这个套餐没有 5 小时限额（服务端只给了每周窗口）
    var noFiveHour: Bool { usage.primary == nil && usage.secondary != nil }
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
    var lang: String? = nil      // 界面语言 zh / en，App 启动时同步过去（见 AppLanguage）
    static let empty = AutoConfig(enabled: false, prompt: "继续", stall_nudge: true, order: "alpha", auto_start: false,  // i18n-ignore
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
    let status: String          // running / stalled / limited / interrupted / paused（会话页暂停的）/ aborted / error / done / idle
    let error: String
    let turnStartedAt: Double
    let lastActivity: Double
    let subagents: Int
    let queued: Bool
    let slot: String?           // 跑在哪个账号（槽位字母）；按切号历史推算，可能为空
    let email: String?
    var model: String?          // 当前模型 / 推理强度 / 速度（priority = 快速），读自对话记录，可能为空
    var effort: String?
    var tier: String?
    var id: String { thread }
    var fast: Bool { tier == "priority" }
    var displayTitle: String { title.isEmpty ? L("未命名对话 · \(String(thread.prefix(8)))") : title }
    var isActive: Bool { status == "running" || status == "stalled" }
    /// 可以点「继续」：没在跑（运行中 / 疑似卡住的不打断）
    var canContinue: Bool { !isActive }
    /// 报错只取第一句（后面常跟「升级到 Pro（链接）」之类的推销）
    var shortError: String {
        guard let r = error.range(of: #"[.。!！](\s|$)"#, options: .regularExpression) else { return error }
        return String(error[..<r.upperBound]).trimmingCharacters(in: .whitespaces)
    }
    /// 可以点「暂停」：正在跑，或排在续答队列里
    var canPause: Bool { isActive || queued }
}

struct SessionsPayload: Decodable { let sessions: [Session] }

/// 可选模型（Codex 的 model/list）
struct ModelInfo: Decodable, Identifiable, Hashable {
    let id: String
    let name: String
    let efforts: [String]
    let `default`: String
    let fast: Bool          // 有没有「快速」档（service tier = priority）
    let speed: Double?      // 快速档几倍速（model/list 的说明里写的 2x / 1.5x）

    // 以下叫法照 ChatGPT 自己的中文界面（推理强度、速度菜单）
    static func effortName(_ e: String) -> String {
        switch e {
        case "none": return L("无")
        case "minimal": return L("极低")
        case "low": return L("轻度")
        case "medium": return L("中")
        case "high": return L("高")
        case "xhigh": return L("极高")
        case "max": return "Max"
        case "ultra": return "Ultra"
        default: return e
        }
    }

    static var speedTitle: String { L("速度") }
    static func tierName(_ t: String) -> String { t == "priority" ? L("快速") : L("标准") }
    /// 菜单里的一项：名称 · 说明（快速档写几倍速）
    static func tierLine(_ t: String, speed: Double?) -> String {
        guard t == "priority" else { return L("标准 · 默认速度") }
        guard let x = speed, x > 0 else { return L("快速 · 速度更快，用量更高") }
        return L("快速 · \(x.formatted(.number.precision(.fractionLength(0...1)))) 倍速度，用量更多")
    }
}

struct ModelsPayload: Decodable { let models: [ModelInfo] }

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
    var nextLabel: String { !active ? L("未订阅") : (willRenew && cancelsAt == 0 ? L("续费") : L("到期")) }
    var billingText: String {
        switch billing { case "monthly": return L("月付"); case "yearly", "annual": return L("年付"); default: return billing }
    }
    var platformText: String {
        switch platform {
        case "chatgpt_web": return L("网页")
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
    let local: Bool?            // 成员列表没拿到时，按本机登录过这个空间的账号补上的（没有加入时间）
    let viaSlot: String?
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
        return L("个人空间 · \(access.first?.email ?? "")")
    }
    /// 账号表、详情里用：每行已经有邮箱了，个人空间就不再带邮箱
    var shortName: String { isTeam || !name.isEmpty ? displayName : L("个人空间") }
    /// 空间的套餐名（官方名，没有就按 plan 推）。注意这是空间级的；同一空间里每个人的席位档位可能不同，见 Slot.seatTier
    var planTitle: String { planName.isEmpty ? Slot.planLabel(plan) : planName }
    var myRole: String { access.first.map { Workspace.roleText($0.role) } ?? "" }
    /// 所有者邮箱：成员里的 account-owner，查不到成员时用能进这个空间的我的账号
    var ownerEmail: String { members?.first { $0.isOwner && $0.active }?.email ?? access.first?.email ?? "" }
    var activeMembers: [Member] { (members ?? []).filter(\.active) }
    func newMembers(now: Double, days: Double = 3) -> [Member] {
        activeMembers.filter { $0.joined > 0 && now - $0.joined <= days * 86400 && $0.role != "account-owner" }
    }

    static func roleText(_ r: String) -> String {
        switch r {
        case "account-owner": return L("所有者")
        case "account-admin", "admin": return L("管理员")
        // 「成员」这个键在侧栏是页名（英文 Members），角色要单数
        case "standard-user": return L("成员#角色", zh: "成员")
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
    let wechat: String?
    var id: String { email }
}

struct Directory: Decodable {
    let at: Double
    let people: [Person]
    let workspaces: [Workspace]
    let errors: [String]
    var hidden: [String]? = nil          // 团队页里手动移除的空间 id（只是不显示）
    /// 槽位 → 重置券。券跟着账号（空间）走，同一邮箱的不同空间各有各的券，id 也不同
    var slotCredits: [String: [ResetCredit]]? = nil
    func credits(_ slot: String) -> [ResetCredit] { slotCredits?[slot] ?? [] }
    func availableResets(_ slot: String) -> [ResetCredit] { credits(slot).filter { $0.status == "available" } }
    var allAvailableResets: [ResetCredit] { (slotCredits ?? [:]).values.flatMap { $0 }.filter { $0.status == "available" } }
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

extension Notice {
    /// 按当前语言重写标题和正文（以前按另一种语言写下的消息）
    func localized() -> Notice {
        Notice(id: id, kind: kind, level: level, title: PhraseBook.shared.apply(title), body: PhraseBook.shared.apply(body),
               at: at, created: created, read: read, ws: ws, slot: slot)
    }
}

struct Simple: Decodable { let ok: Bool; let err: String?; let slot: String?; let email: String?; let plan: String? }
struct Current: Decodable {
    let acct: String; let user: String?; let email: String; let plan: String; let known: Bool
    /// 同一个团队空间里的不同成员 acct 相同，要连人一起比
    var who: String { acct.isEmpty ? "" : acct + "|" + (user ?? email.lowercased()) }
}

/// 一行日志
struct LogLine: Identifiable {
    enum Source: String { case auto = "自动切号", manager = "账号操作" }  // i18n-ignore  显示时由 LogsPage 查表
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
        // 英文「Tomorrow 18:52」在表格窄列里放不下，直接写日期（和别的日期列一样）
        if cal.isDateInTomorrow(d) && AppLanguage.active != "en" { return L("明天 \(hm.string(from: d))") }
        return mdhm.string(from: d)
    }

    static func date(_ epoch: Double) -> String { epoch > 0 ? ymd.string(from: Date(timeIntervalSince1970: epoch)) : "—" }
    /// 月-日 时:分（不换成「今天 / 明天」）
    static func dayTime(_ epoch: Double) -> String { epoch > 0 ? mdhm.string(from: Date(timeIntervalSince1970: epoch)) : "—" }
    /// 悬停说明用：完整日期时间 + 本机时区。接口给的是 UTC 时刻，这里按这台 Mac 的时区显示
    static func full(_ epoch: Double) -> String {
        guard epoch > 0 else { return "—" }
        let d = Date(timeIntervalSince1970: epoch), tz = TimeZone.current
        let h = Double(tz.secondsFromGMT(for: d)) / 3600
        let off = h == h.rounded() ? String(format: "%+d", Int(h)) : String(format: "%+.1f", h)
        return ymd.string(from: d) + " " + hm.string(from: d) + L("（本机时区 \(tz.identifier)，UTC\(off)）")
    }

    /// 「3 分钟前」「2 小时前」
    static func ago(_ epoch: Double, now: Double = Date().timeIntervalSince1970) -> String {
        let s = max(0, now - epoch)
        if s < 60 { return L("刚刚") }
        if s < 3600 { return L("\(Int(s / 60)) 分钟前") }
        if s < 86400 { return L("\(Int(s / 3600)) 小时前") }
        return L("\(Int(s / 86400)) 天前")
    }

    /// 「1 小时 5 分」
    static func span(_ seconds: Double) -> String {
        let m = Int(max(0, seconds) / 60)
        if m < 60 { return L("\(m) 分钟") }
        if m < 1440 { return L("\(m / 60) 小时 \(m % 60) 分") }
        return L("\(m / 1440) 天 \(m % 1440 / 60) 小时")
    }

    /// 「还有 1 小时 5 分」
    static func until(_ epoch: Double, now: Double) -> String {
        epoch <= now ? L("已到") : L("还有 \(span(epoch - now))")
    }

    /// 距今天数（向上取整），用于「3 天后续费」
    static func daysLeft(_ epoch: Double, now: Double) -> Int { Int(ceil((epoch - now) / 86400)) }
}
