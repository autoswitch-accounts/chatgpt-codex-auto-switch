import SwiftUI
import AppKit

/// 添加账号流程的阶段
enum AddPhase: Equatable {
    case intro                                // 说明，等你点「开始」
    case working(String)                      // 自动步骤进行中
    case naming(String, String, String)       // 已识别：槽位 / 邮箱 / 套餐
    case failed(String)
}

/// 「用哪张券给哪个账号重置」
struct ResetAsk: Identifiable {
    let slot: Slot
    let credit: ResetCredit
    var id: String { credit.id }
}

// MARK: - 引擎桥接

/// 所有数据都来自 Resources 里的 engine.py / autoswitch.py；界面只读它们的 JSON 输出
@MainActor
final class Store: ObservableObject {
    @Published var slots: [Slot] = []
    @Published var auto: AutoStatus = .empty
    @Published var config: AutoConfig = .empty
    @Published var appRunning = false
    @Published var sessions: [Session] = []
    @Published var directory: Directory = .empty
    @Published var notices: [Notice] = []
    @Published var unread = 0
    @Published var logs: [LogLine] = []
    @Published var busy: String? = nil
    @Published var refreshing = false
    @Published var syncing = false
    @Published var toast: String? = nil
    @Published var addPhase: AddPhase = .intro
    @Published var now = Date().timeIntervalSince1970
    // 各页面共用的弹窗：切号确认 / 重命名 / 删除 / 续答确认 / 添加
    @Published var confirmSwitch: Slot? = nil
    @Published var renaming: Slot? = nil
    @Published var deleting: Slot? = nil
    @Published var confirmResume: Session? = nil
    @Published var adding = false
    @Published var confirmReset: ResetAsk? = nil       // 用一张额度重置券
    @Published var confirmStart: Slot? = nil           // 让 5 小时窗口开始计时
    @Published var editingMember: MemberRow? = nil     // 改微信名 / 交费日
    /// 跳页时顺带要选中的对象（空间 id / 对话 id / 槽位），目标页出现时取走
    @Published var focus: String? = nil
    @Published var showResets = false                  // 重置券清单

    private var timers: [Timer] = []
    private var watch: Task<Void, Never>? = nil
    private var baseline = ""

    nonisolated static func resource(_ name: String) -> String {
        Bundle.main.resourceURL!.appendingPathComponent(name).path
    }

    /// 同步跑一个脚本命令，返回 stdout
    nonisolated static func exec(_ script: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [resource(script)] + args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        do { try p.run() } catch { return "" }
        let d = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: d, encoding: .utf8) ?? ""
    }

    func engine(_ args: [String]) async -> String {
        await Task.detached { Store.exec("engine.py", args) }.value
    }

    static func decode<T: Decodable>(_ s: String, _ t: T.Type) -> T? {
        guard let d = s.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(t, from: d)
    }

    private func apply(_ out: String) {
        guard let r = Store.decode(out, ListPayload.self) else { return }
        slots = r.slots
        auto = r.auto
        config = r.config
        appRunning = r.running
        now = Date().timeIntervalSince1970
        if r.unread != unread { unread = r.unread; reloadNotices() }
    }

    /// 启动时同步取一次，首屏就有数据
    func loadNow() {
        apply(Store.exec("engine.py", ["--list-json"]))
        if let d = Store.decode(Store.exec("engine.py", ["--directory-json"]), Directory.self) { directory = d }
    }

    func reload() { Task { apply(await engine(["--list-json"])) } }

    func reloadSessions() {
        Task {
            let out = await Task.detached { Store.exec("autoswitch.py", ["--sessions-json"]) }.value
            if let r = Store.decode(out, SessionsPayload.self) { sessions = r.sessions }
        }
    }

    func start() {
        timers.forEach { $0.invalidate() }
        timers = [
            Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.reload() } },
            Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.reloadSessions() } },
            Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.reloadLogs() } },
            // 守护进程每 30 分钟同步一次目录；界面每分钟读一下缓存
            Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.loadDirectory(refresh: false) } },
        ]
        reloadSessions()
        reloadLogs()
        reloadNotices()
        Task { _ = await engine(["--ensure-daemon"]); reload() }
        refreshUsage()
        if directory.at == 0 || now - directory.at > 1800 { loadDirectory(refresh: true) }
    }

    func say(_ text: String) {
        toast = text
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if toast == text { toast = nil }
        }
    }

    // MARK: 便捷查询

    var current: Slot? { slots.first { $0.current } }
    func workspace(of s: Slot) -> Workspace? { directory.workspace(s.acct) }
    func person(of s: Slot) -> Person? { directory.person(s.email) }
    var teams: [Workspace] { directory.workspaces.filter(\.isTeam) }
    /// 正在回复中的对话：手动切号会把它们打断
    var activeSessions: [Session] { sessions.filter { $0.status == "running" || $0.status == "stalled" } }

    /// 所有团队的成员（台账用）
    var memberRows: [MemberRow] {
        teams.flatMap { w in (w.members ?? []).map { MemberRow(m: $0, w: w) } }
    }

    /// N 天内（含今天）该交费的成员，按日期排
    func duePayments(days: Double) -> [MemberRow] {
        let today = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: now)).timeIntervalSince1970
        // 过了应交日还没标记已交的（逾期）也算待交
        return memberRows.filter { $0.m.active && $0.nextPay <= today + days * 86400 }
            .sorted { $0.nextPay < $1.nextPay }
    }

    /// N 天内续费 / 到期的空间（按时间排）
    func upcomingRenewals(days: Double) -> [Workspace] {
        directory.workspaces
            .filter { let t = $0.sub.nextDate; return t > now && t - now <= days * 86400 }
            .sorted { $0.sub.nextDate < $1.sub.nextDate }
    }

    /// 下一个会被自动切到的账号（和守护进程同一套规则，只看缓存，不联网）
    func nextSlot() -> Slot? {
        let candidate = { (s: Slot) in s.usable(self.now) && !self.skipped(s) }
        guard let i = slots.firstIndex(where: { $0.current }) else { return slots.first(where: candidate) }
        var order = Array(slots[(i + 1)...] + slots[..<i])
        // 和守护进程一样要稳定排序（同分保持字母序）；Swift 的 sort 不保证稳定，带上原位置
        if config.order == "most" || config.order == "soon" {
            let soon = config.order == "soon"
            order = order.enumerated().sorted { a, b in
                let (x, y) = soon ? (a.element.nextReset5h(now), b.element.nextReset5h(now))
                                  : (-a.element.remaining5h(now), -b.element.remaining5h(now))
                return x != y ? x < y : a.offset < b.offset
            }.map(\.element)
        }
        return order.first(where: candidate)
    }

    /// 这个账号设成了「不参与轮换」：自动切号不会切到它
    func skipped(_ s: Slot) -> Bool { config.skip.contains(s.slot) }

    func setSkipped(_ s: Slot, _ on: Bool) {
        var l = config.skip.filter { $0 != s.slot }
        if on { l.append(s.slot) }
        config.skip = l.sorted()
        let json = (try? JSONEncoder().encode(config.skip)).flatMap { String(data: $0, encoding: .utf8) } ?? "[]"
        setConfig("skip", json)
    }

    // MARK: 额度 / 目录 / 设置

    /// 联网刷新额度：不传槽位就刷新全部
    func refreshUsage(_ slot: String? = nil) {
        guard !refreshing else { return }
        refreshing = true
        Task {
            _ = await engine(["--refresh-usage"] + (slot.map { [$0] } ?? []))
            refreshing = false
            reload()
        }
    }

    /// 空间 / 订阅 / 成员；refresh 为真时联网同步（约 15 秒）
    func loadDirectory(refresh: Bool) {
        if refresh {
            guard !syncing else { return }
            syncing = true
        }
        Task {
            let out = await engine(["--directory-json"] + (refresh ? ["--refresh"] : []))
            if let d = Store.decode(out, Directory.self), d.at >= directory.at { directory = d }
            if refresh {
                syncing = false
                say("已同步 \(directory.workspaces.count) 个空间、\(directory.people.count) 个邮箱")
                reload()
                reloadNotices()
            }
        }
    }

    func syncAll() {
        refreshUsage()
        loadDirectory(refresh: true)
    }

    func setConfig(_ key: String, _ jsonValue: String) {
        Task {
            let r = Store.decode(await engine(["--set-config", key, jsonValue]), Simple.self)
            if let r, !r.ok { say(r.err ?? "设置失败") }
            reload()
        }
    }

    func setAuto(_ on: Bool) {
        config.enabled = on
        setConfig("enabled", on ? "true" : "false")
    }

    func restartDaemon() {
        Task {
            let r = Store.decode(await engine(["--ensure-daemon", "--restart"]), Simple.self)
            say(r?.ok == true ? "后台服务已重启" : (r?.err ?? "重启失败"))
            reload()
        }
    }

    // MARK: 消息中心

    func reloadNotices() {
        Task {
            if let r = Store.decode(await engine(["--notices-json"]), NoticesPayload.self) {
                notices = r.items
                unread = r.unread
            }
        }
    }

    /// 标为已读；空数组表示全部
    func markRead(_ ids: [String]) {
        Task {
            _ = await engine(["--notice-read"] + ids)
            reloadNotices()
        }
    }

    // MARK: 账号操作

    /// 切到某个槽位；当前账号则强制重启一次 ChatGPT。
    /// resume 为真时，切完请后台在被打断的对话里发续答用语
    func switchTo(_ s: Slot, resume: Bool = false) {
        guard busy == nil else { return }
        busy = s.slot
        let threads = resume ? activeSessions.map(\.thread) : []
        let args = s.current ? ["--slot", s.slot, "--force"] : ["--slot", s.slot]
        Task {
            let r = Store.decode(await engine(args), Simple.self)
            if r?.ok == true {
                if !threads.isEmpty { _ = await engine(["--resume"] + threads) }
                say((s.current ? "已重启 ChatGPT" : "已切到 \(s.email)")
                    + (threads.isEmpty ? "" : "，稍后在 \(threads.count) 个对话里自动续答"))
            } else {
                say(r?.err ?? "切换失败")
            }
            busy = nil
            reload()
            reloadSessions()
        }
    }

    func rename(_ s: Slot, to name: String) {
        Task { _ = await engine(["--rename", s.slot, name]); reload() }
    }

    func remove(_ s: Slot) {
        Task {
            if let r = Store.decode(await engine(["--delete", s.slot]), Simple.self), !r.ok { say(r.err ?? "删除失败") }
            reload()
        }
    }

    func resume(_ s: Session) {
        Task {
            _ = await engine(["--resume", s.thread])
            say("已请后台在「\(s.displayTitle)」里发送「\(config.prompt)」")
            reloadSessions()
        }
    }

    // MARK: 额度操作

    /// 用一张重置券（不可撤销）：立即清空这个账号的 5 小时和本周用量
    func useReset(_ a: ResetAsk) {
        guard busy == nil else { return }
        busy = a.slot.slot
        Task {
            let r = Store.decode(await engine(["--reset-credit", a.slot.slot, a.credit.id]), Simple.self)
            say(r?.ok == true ? "\(a.slot.email) 的额度已重置" : "重置失败：\(r?.err ?? "没有返回")")
            busy = nil
            reload()
            loadDirectory(refresh: false)
        }
    }

    /// 发一句极短的请求，让没用过的账号的 5 小时窗口从现在开始计时
    func startWindow(_ s: Slot) {
        guard busy == nil else { return }
        busy = s.slot
        Task {
            let r = Store.decode(await engine(["--start-window", s.slot]), Simple.self)
            say(r?.ok == true ? "\(s.email) 的 5 小时额度已开始计时" : "没能开始计时：\(r?.err ?? "没有返回")")
            busy = nil
            reload()
        }
    }

    // MARK: 成员台账

    func setWechat(_ email: String, _ name: String) {
        Task {
            _ = await engine(["--meta-set", "wechat", email, name])
            loadDirectory(refresh: false)
            reload()
        }
    }

    /// 改某人在某空间的交费日；date 为 nil 表示恢复成按加入日自动推算
    func setPay(_ wid: String, _ email: String, _ date: Date?) {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        Task {
            _ = await engine(["--meta-set", "pay", "\(wid)|\(email)", date.map { f.string(from: $0) } ?? ""])
            loadDirectory(refresh: false)
            reloadNotices()
        }
    }

    /// 标记本期已交（下次交费顺延一个月）；undo 撤销上一次标记
    func markPaid(_ r: MemberRow, undo: Bool = false) {
        Task {
            var args = ["--mark-paid", "\(r.w.id)|\(r.email)"]
            if undo { args.append("--undo") }
            let res = Store.decode(await engine(args), Simple.self)
            if res?.ok == true {
                say(undo ? "已撤销 \(r.email) 上一期的已交标记"
                         : "\(r.wechat.isEmpty ? r.email : r.wechat) \(TimeText.date(r.nextPay).dropFirst(5)) 这期已交，下次顺延一个月")
            } else {
                say("没能标记：\(res?.err ?? "没有返回")")
            }
            loadDirectory(refresh: false)
            reloadNotices()
        }
    }

    /// 微信名：成员表、我的账号都按邮箱共用一份
    func wechat(_ email: String) -> String {
        let e = email.lowercased()
        if let p = directory.people.first(where: { $0.email.lowercased() == e }), let w = p.wechat, !w.isEmpty { return w }
        for w in directory.workspaces {
            if let m = w.members?.first(where: { $0.email.lowercased() == e }), let n = m.wechat, !n.isEmpty { return n }
        }
        return slots.first { $0.email.lowercased() == e }?.wechat ?? ""
    }

    /// 我自己的邮箱（槽位里的）：成员台账默认不列这些
    var myEmails: Set<String> { Set(slots.map { $0.email.lowercased() } + directory.people.map { $0.email.lowercased() }) }

    // MARK: 日志

    /// 演示模式（scripts/demo.sh）用 HOME 指向的假数据；平时是真实的家目录
    nonisolated static let home: URL = {
        let env = ProcessInfo.processInfo.environment
        if env["CGA_DEMO"] == "1", let h = env["HOME"] { return URL(fileURLWithPath: h) }
        return FileManager.default.homeDirectoryForCurrentUser
    }()
    nonisolated static let dataDir = home.appendingPathComponent("Library/Application Support/codex-profiles")

    func reloadLogs() {
        Task {
            let rows = await Task.detached { Store.readLogs() }.value
            if rows.count != logs.count || rows.last?.time != logs.last?.time || rows.last?.text != logs.last?.text {
                logs = rows
            }
        }
    }

    /// 读两份日志的末尾，按时间合并（新的在后）
    nonisolated static func readLogs(limit: Int = 1500) -> [LogLine] {
        var rows: [(String, String, LogLine.Source)] = []
        for (file, src) in [("autoswitch.log", LogLine.Source.auto), ("manager.log", .manager)] {
            let url = dataDir.appendingPathComponent(file)
            guard let h = try? FileHandle(forReadingFrom: url) else { continue }
            let size = (try? h.seekToEnd()) ?? 0
            try? h.seek(toOffset: size > 400_000 ? size - 400_000 : 0)
            let text = String(decoding: h.readDataToEndOfFile(), as: UTF8.self)
            try? h.close()
            for line in text.split(separator: "\n").suffix(limit) {
                let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
                guard parts.count == 3, parts[0].count == 10 else { continue }
                rows.append(("\(parts[0]) \(parts[1])", parts[2].trimmingCharacters(in: .whitespaces), src))
            }
        }
        rows.sort { $0.0 < $1.0 }                 // sort 稳定：同一秒内保持各自文件里的先后
        return rows.suffix(limit).enumerated().map { LogLine(id: $0.offset, time: $0.element.0,
                                                             text: $0.element.1, source: $0.element.2) }
    }

    // MARK: 添加账号

    func beginAdd() {
        addPhase = .intro
        baseline = Store.decode(Store.exec("engine.py", ["--current-json"]), Current.self)?.acct ?? ""
    }

    /// 存回当前凭证 → 退出 ChatGPT → codex logout → 用新槽位的 profile 开窗 → 等登录 → 自动收凭证
    func runAdd() {
        Task {
            // 先定下新槽位，才能用它自己的 profile 开窗登录（会话必须和凭证成对）
            let sl = Store.decode(await engine(["--next-slot"]), Simple.self)
            guard let sl, sl.ok, let slot = sl.slot else {
                addPhase = .failed(sl?.err ?? "没有空槽位"); return
            }
            addPhase = .working("正在保存当前凭证并退出 ChatGPT…")
            let out = await engine(["--auto-begin", slot])
            guard let r = Store.decode(out, Simple.self), r.ok else {
                addPhase = .failed(Store.decode(out, Simple.self)?.err ?? "退出或登出失败")
                return
            }
            addPhase = .working("已打开一个干净的 ChatGPT 窗口，请在里面登录并选择 workspace…")
            // 登录这一步整个让位给 ChatGPT，否则登录页被压在下面点不到；想中途取消就点 Dock 图标
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            AppWindow.stepAsideForLogin()
            startWatch()
        }
    }

    /// 盯着 auth.json 变化，登录一成功就收进槽位
    private func startWatch() {
        watch?.cancel()
        watch = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                guard let self else { return }
                let out = await self.engine(["--current-json"])
                guard let c = Store.decode(out, Current.self),
                      !c.acct.isEmpty, c.acct != self.baseline else { continue }
                self.addPhase = .working("已登录 \(c.email)，正在收取凭证…")
                AppWindow.comeBack()
                let r = Store.decode(await self.engine(["--capture"]), Simple.self)
                if let r, r.ok, let slot = r.slot {
                    self.reload()
                    self.loadDirectory(refresh: true)        // 顺便拿到官方 workspace 名和订阅
                    self.addPhase = .naming(slot, r.email ?? c.email, r.plan ?? c.plan)
                } else {
                    self.addPhase = .failed(r?.err ?? "收取凭证失败")
                }
                return
            }
        }
    }

    func endAdd() { watch?.cancel(); watch = nil }

    func finishAdd(_ slot: String) {
        endAdd()
        Task { _ = await engine(["--relaunch", slot]); reload() }
    }
}
