import SwiftUI
import AppKit
import Combine
import UserNotifications

// MARK: - 页面与侧栏

enum Page: String, CaseIterable, Identifiable {
    case overview, messages, accounts, teams, members, sessions, logs, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return L("概览")
        case .messages: return L("消息")
        case .accounts: return L("账号")
        case .teams:    return L("团队")
        case .members:  return L("成员")
        case .sessions: return L("会话")
        case .logs:     return L("日志")
        case .settings: return L("设置")
        }
    }
    var icon: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .messages: return "bell"
        case .accounts: return "person.crop.circle"
        case .teams:    return "building.2"
        case .members:  return "person.2"
        case .sessions: return "text.bubble"
        case .logs:     return "doc.text"
        case .settings: return "gearshape"
        }
    }
}

/// 侧栏：分组 + 角标，底部是当前账号和自动切号开关。
/// 不用 List：系统选中色在窗口失焦时几乎看不见，而且只有点到文字才切；这里整行是按钮，
/// 选中底块用 matchedGeometryEffect 在行间滑动
struct Sidebar: View {
    @ObservedObject var store: Store
    @Binding var page: Page
    @Namespace private var ns
    @State private var hovered: Page? = nil

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                header(L("工作台"), first: true)
                item(.overview)
                item(.messages, badge: store.unread > 0 ? "\(store.unread)" : nil)
                header(L("资源"))
                item(.accounts, badge: "\(store.slots.filter { $0.usable(store.now) }.count)/\(store.slots.count)")
                item(.teams, badge: store.teams.isEmpty ? nil : "\(store.teams.count)")
                let due = store.duePayments(days: 3).count
                item(.members, badge: due > 0 ? "\(due)" : nil)
                header(L("运行"))
                item(.sessions, badge: store.activeSessions.isEmpty ? nil : "\(store.activeSessions.count)")
                item(.logs)
                Color.clear.frame(height: 12)
                item(.settings)
            }
            .padding(.horizontal, 10)
        }
        .scrollIndicators(.never)
        .safeAreaInset(edge: .bottom) { footer }
        .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
    }

    /// 分组标题；第一组不留顶部空白，让第一行和右侧内容的顶边对齐
    private func header(_ t: String, first: Bool = false) -> some View {
        Text(t).font(.system(size: 11, weight: .semibold)).foregroundStyle(.tertiary)
            .padding(.leading, 10).padding(.top, first ? 2 : 14).padding(.bottom, 3)
    }

    /// 角标统一灰色数字，和系统侧栏一致；要紧的事进「消息」，不在侧栏里染色
    private func item(_ p: Page, badge: String? = nil) -> some View {
        let on = page == p
        return Button {
            withAnimation(.snappy(duration: 0.3)) { page = p }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: p.icon)
                    .font(.system(size: 14, weight: .medium))
                    .symbolVariant(on ? .fill : .none)
                    .frame(width: 22, height: 22)
                    .foregroundStyle(on ? Palette.accent : Palette.text2)
                Text(p.title).font(.system(size: 13.5, weight: on ? .semibold : .regular))
                    .foregroundStyle(on ? Palette.accent : Palette.text)
                Spacer(minLength: 4)
                if let badge {
                    Text(badge).font(.system(size: 11.5, weight: .medium).monospacedDigit())
                        .foregroundStyle(Palette.text2)
                }
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
            .background {
                if on {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.accent.opacity(0.14))
                        .matchedGeometryEffect(id: "selection", in: ns)
                } else if hovered == p {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Palette.fill)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { h in hovered = h ? p : (hovered == p ? nil : hovered) }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let c = store.current {
                HStack(spacing: 10) {
                    Avatar(letter: c.slot, size: 32)
                    VStack(alignment: .leading, spacing: 3) {
                        // 侧栏窄：放不下就换行，不省略（悬停提示在侧栏里不一定出得来）
                        // @ 后面插一个零宽空格：要换行就在 @ 处断，不把域名拆开
                        Text(c.email.replacingOccurrences(of: "@", with: "@\u{200B}")).font(.system(size: 13, weight: .semibold))
                            .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                        Text(store.workspace(of: c)?.shortName ?? c.title)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .help(c.email + (store.workspace(of: c).map { "\n" + $0.shortName } ?? ""))
                }
                // 有 5 小时额度的账号两条都有；只有周额度的套餐只显示本周
                VStack(spacing: 10) {
                    if !c.noFiveHour { quotaBar(L("5 小时"), c.usage.primary?.remaining(now: store.now)) }
                    quotaBar(L("本周"), c.usage.secondary?.remaining(now: store.now))
                }
                Divider()
            }
            HStack(spacing: 6) {
                Circle().fill(AutoCard.color(store.auto)).frame(width: 7, height: 7)
                Text(sideStatus).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer(minLength: 0)
                Toggle("", isOn: Binding(get: { store.config.enabled }, set: { store.setAuto($0) }))
                    .toggleStyle(SwitchStyle()).labelsHidden()
                    .help("自动切号并续答")
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 16)
        .glassPanel(cornerRadius: 16)
        .padding(10)
    }

    /// 侧栏卡片里的一条额度：名称 · 进度条（剩余）· 百分比
    private func quotaBar(_ title: String, _ left: Double?) -> some View {
        let l = max(0, min(100, left ?? 0))
        return HStack(spacing: 8) {
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .frame(width: AppLanguage.active == "en" ? 56 : 38, alignment: .leading)   // 英文「This week」更宽
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Palette.track)
                    Capsule().fill(Palette.quota(l)).frame(width: l > 0 ? max(6, g.size.width * l / 100) : 0)
                }
            }
            .frame(height: 6)
            Text(left == nil ? "—" : "\(Int(l.rounded()))%").font(.caption.monospacedDigit().weight(.medium))
                .foregroundStyle(l < 1 && left != nil ? Palette.red : Palette.text).frame(width: 34, alignment: .trailing)
        }
    }

    private var sideStatus: String {
        let a = store.auto
        if !a.enabled { return L("自动切号已关闭") }
        if !a.alive { return L("后台服务未运行") }
        switch a.phase {
        case "switching": return L("正在切号…")
        case "waiting":   return L("等待额度恢复 \(TimeText.short(a.waitUntil))")
        case "resuming":  return L("正在续答")
        default:          return L("自动切号监控中")
        }
    }
}

// MARK: - 主界面

struct RootView: View {
    @ObservedObject var store: Store
    @AppStorage("page") private var pageRaw = Page.overview.rawValue
    @AppStorage("appearance") private var appearance = "system"
    @State private var draft = ""
    private let tick = Timer.publish(every: 20, on: .main, in: .common).autoconnect()

    private var page: Binding<Page> {
        Binding(get: { Page(rawValue: pageRaw) ?? .overview }, set: { pageRaw = $0.rawValue })
    }

    var body: some View {
        NavigationSplitView {
            Sidebar(store: store, page: page)
        } detail: {
            detail.id(page.wrappedValue)
                .transition(.opacity)
                .background(PageBackground())
        }
        .overlay(alignment: .bottom) { toast }
        .frame(minWidth: 1080, minHeight: 680)
        .onAppear {
            store.start()
            if CommandLine.arguments.contains("--demo-add") { store.beginAdd(); store.adding = true }
            if let i = CommandLine.arguments.firstIndex(of: "--page"), i + 1 < CommandLine.arguments.count {
                pageRaw = CommandLine.arguments[i + 1]
            }
            // 调试 / 截图用：打开时直接选中某个槽位 / 空间 / 对话
            if let i = CommandLine.arguments.firstIndex(of: "--focus"), i + 1 < CommandLine.arguments.count {
                store.focus = CommandLine.arguments[i + 1]
            }
            if CommandLine.arguments.contains("--show-resets") {   // 晚一点再弹：弹窗先出来的话窗口进不了全屏
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { store.showResets = true }
            }
            // 截图用：目录加载完后打开某个成员的编辑框
            if let i = CommandLine.arguments.firstIndex(of: "--edit-member"), i + 1 < CommandLine.arguments.count {
                let mail = CommandLine.arguments[i + 1].lowercased()
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    store.editingMember = store.memberRows.first { $0.email.lowercased() == mail }
                }
            }
        }
        .onReceive(tick) { _ in store.now = Date().timeIntervalSince1970 }
        .onChange(of: appearance, initial: true) { _, v in AppWindow.setAppearance(v) }
        .alert("用一张额度重置券？", isPresented: Binding(get: { store.confirmReset != nil },
                                                    set: { if !$0 { store.confirmReset = nil } }), presenting: store.confirmReset) { a in
            Button("立即重置") { store.useReset(a) }
            Button("取消", role: .cancel) {}
        } message: { a in
            let left = max(0, store.directory.availableResets(a.slot.slot).count - 1)
            Text(L("\(a.slot.email)（槽 \(a.slot.slot)）\n会立即清空这个账号的 5 小时和本周用量。\n这张券 \(TimeText.short(a.credit.expiresAt)) 过期，用掉后不能撤销；这个账号还剩 \(left) 张。"))
        }
        .alert("让 5 小时额度开始计时？", isPresented: Binding(get: { store.confirmStart != nil },
                                                      set: { if !$0 { store.confirmStart = nil } }), presenting: store.confirmStart) { s in
            Button("开始计时") { store.startWindow(s) }
            Button("取消", role: .cancel) {}
        } message: { s in
            Text(L("\(s.email)（槽 \(s.slot)）\n会用这个账号发一句极短的消息（不切号、不影响当前对话），5 小时窗口从现在开始，\(TimeText.short(store.now + 5 * 3600)) 前后重置。会用掉很少一点额度。"))
        }
        // 弹窗统一铺和正文页一样的渐变底色
        .sheet(item: $store.editingMember) { r in MemberEditSheet(store: store, row: r).background(PageBackground()) }
        .sheet(isPresented: $store.showResets) { ResetSheet(store: store).background(PageBackground()) }
        .alert(switchTitle, isPresented: Binding(get: { store.confirmSwitch != nil },
                                                 set: { if !$0 { store.confirmSwitch = nil } }), presenting: store.confirmSwitch) { s in
            let n = store.activeSessions.count
            if n > 0 {
                Button("切换，并在 \(n) 个对话里续答") { store.switchTo(s, resume: true) }
                Button("只切换") { store.switchTo(s) }
            } else {
                Button(s.current ? "重启" : "切换") { store.switchTo(s) }
            }
            Button("取消", role: .cancel) {}
        } message: { s in
            Text(switchMessage(s))
        }
        .alert("在这个对话里发「\(store.config.prompt)」？", isPresented: Binding(get: { store.confirmResume != nil },
                                                                     set: { if !$0 { store.confirmResume = nil } }),
               presenting: store.confirmResume) { s in
            Button("发送") { store.resume(s) }
            Button("取消", role: .cancel) {}
        } message: { s in
            Text("「\(s.displayTitle)」\n后台会打开这个对话并发送一条新消息，让它接着干。")
        }
        .alert("删除这个账号？", isPresented: Binding(get: { store.deleting != nil },
                                                    set: { if !$0 { store.deleting = nil } }), presenting: store.deleting) { s in
            Button("删除", role: .destructive) { store.remove(s) }
            Button("取消", role: .cancel) {}
        } message: { s in
            Text("只删除本机保存的 \(s.email) 凭证，云端账号不受影响，以后可以重新添加。")
        }
        .sheet(item: $store.renaming) { s in renameSheet(s).background(PageBackground()) }
        .sheet(isPresented: $store.adding) { AddSheet(store: store) { store.adding = false }.background(PageBackground()) }
    }

    @ViewBuilder private var detail: some View {
        switch page.wrappedValue {
        case .overview: OverviewPage(store: store) { page.wrappedValue = $0 }
        case .messages: MessagesPage(store: store)
        case .accounts: AccountsPage(store: store)
        case .teams:    TeamsPage(store: store)
        case .members:  MembersPage(store: store)
        case .sessions: SessionsPage(store: store)
        case .logs:     LogsPage(store: store)
        case .settings: SettingsPage(store: store)
        }
    }

    private var toast: some View {
        Group {
            if let t = store.toast {
                Text(t).font(.callout.weight(.medium))
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Palette.line.opacity(0.5), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: store.toast)
    }

    private var switchTitle: String {
        guard let s = store.confirmSwitch else { return "" }
        return s.current ? L("重启 ChatGPT？") : L("切换到 \(s.email)？")
    }

    private func switchMessage(_ s: Slot) -> String {
        var lines: [String] = []
        if !s.current {
            lines.append(L("\(store.workspace(of: s)?.displayName ?? s.title) · 槽 \(s.slot)"))
            if let p = s.usage.primary {
                lines.append(L("5 小时剩余 \(Int(p.remaining(now: store.now).rounded()))% · 本周剩余 \(Int(max(0, s.remainingWeek(store.now)).rounded()))%"))
            }
            if let until = s.exhaustedUntil(store.now) {
                lines.append(L("⚠️ 这个账号额度已用完，\(TimeText.short(until)) 才恢复"))
            }
            if s.needsLogin { lines.append(L("⚠️ 这个账号的凭证已失效，切过去需要重新登录")) }
        }
        lines.append(L("会退出并重新打开 ChatGPT。"))
        let n = store.activeSessions.count
        if n > 0 {
            lines.append(L("有 \(n) 个对话正在回复，会被打断；选「续答」会在切换后自动发「\(store.config.prompt)」让它们接着干。"))
        }
        return lines.joined(separator: "\n")
    }

    private func renameSheet(_ s: Slot) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 11) {
                Avatar(letter: s.slot, size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text("重命名").font(.headline)
                    Text(s.email).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            EndCursorField(text: $draft, placeholder: s.workspace.isEmpty ? L("显示名（留空用默认）") : L("留空则显示官方名「\(s.workspace)」"))
                .frame(height: 22)
            HStack {
                Spacer()
                Button("取消") { store.renaming = nil }
                Button("保存") { store.rename(s, to: draft); store.renaming = nil }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(width: 360)
        .onAppear { draft = s.name }
    }
}

// MARK: - 添加流程

struct AddSheet: View {
    @ObservedObject var store: Store
    let onClose: () -> Void
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Palette.accent.opacity(0.15))
                    Image(systemName: headIcon).font(.system(size: 19, weight: .medium)).foregroundStyle(Palette.accent)
                }
                .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headTitle).font(.system(size: 14.5, weight: .semibold))
                    Text(headSub).font(.system(size: 11.5)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 16)

            Divider()

            Group {
                switch store.addPhase {
                case .intro:          intro
                case .working(let t): working(t)
                case .naming:         naming
                case .failed(let e):  failed(e)
                }
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
            .frame(maxHeight: .infinity, alignment: .top)

            Divider()

            HStack {
                if case .naming = store.addPhase {} else {
                    Text("当前凭证会先存回槽位，不会丢").font(.system(size: 10.5)).foregroundStyle(.tertiary)
                }
                Spacer()
                if case .naming(let slot, _, _) = store.addPhase {
                    // 登录用的 ChatGPT 窗口就是新账号的，已经开着，不用再打开
                    Button("完成") { store.finishAdd(slot); onClose() }.keyboardShortcut(.defaultAction)
                } else {
                    Button("取消") { store.endAdd(); onClose() }
                }
                if case .intro = store.addPhase {
                    Button("开始") { store.runAdd() }.keyboardShortcut(.defaultAction)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        // 高度固定：登录时整个 App 会隐藏，期间内容变高变矮、窗口没跟着变，回来后顶部会露出一块黑边
        .frame(width: 420, height: 350)
        // 添加期间退回普通层（用户要在 ChatGPT 的登录窗里操作），结束再按设置恢复
        .onAppear { AppWindow.setAddFlow(true) }
        .onDisappear { AppWindow.setAddFlow(false) }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 13) {
            VStack(alignment: .leading, spacing: 9) {
                step(L("保存当前凭证并退出 ChatGPT"), auto: true)
                step(L("登出当前账号（codex logout）"), auto: true)
                step(L("用新槽位的独立 profile 开窗"), auto: true)
                step(L("在窗口里登录、选择 workspace"), auto: false)
                step(L("识别新账号和 workspace 名、存入槽位、重开 ChatGPT"), auto: true)
            }
            Text("只有第 4 步需要你操作，其余全自动。").font(.system(size: 11.5)).foregroundStyle(.secondary)
        }
    }

    private func step(_ t: String, auto: Bool) -> some View {
        HStack(spacing: 9) {
            Image(systemName: auto ? "bolt.fill" : "hand.point.up.left.fill").font(.system(size: 10.5))
                .foregroundStyle(auto ? Palette.accent : Palette.orange).frame(width: 16)
            Text(t).font(.system(size: 12.5))
            Spacer(minLength: 0)
            Text(auto ? "自动" : "需要你").font(.system(size: 10, weight: .medium))
                .foregroundStyle(auto ? Color.secondary : Palette.orange)
        }
    }

    private func working(_ t: String) -> some View {
        HStack(spacing: 9) {
            Spinner()
            Text(t).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.raised))
    }

    private var naming: some View {
        VStack(alignment: .leading, spacing: 13) {
            if case .naming(let slot, let email, let plan) = store.addPhase {
                let ws = store.slots.first { $0.slot == slot }?.workspace ?? ""
                HStack(spacing: 11) {
                    Avatar(letter: slot, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(email).font(.system(size: 12.5, weight: .medium))
                        Text(ws.isEmpty ? L("已存为槽位 \(slot)") : L("已存为槽位 \(slot) · \(ws)"))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Palette.green).font(.system(size: 16))
                }
                .padding(.horizontal, 12).padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Palette.raised))

                Text("空间名和套餐会自动读取（\(Slot.planLabel(plan))）。想另起显示名，之后在账号的右键菜单里「重命名」")
                    .font(.system(size: 10.5)).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func failed(_ e: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Palette.orange)
            Text(e).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.raised))
    }

    private var headIcon: String {
        switch store.addPhase {
        case .naming:  return "checkmark.circle"
        case .failed:  return "exclamationmark.triangle"
        case .working: return "arrow.triangle.2.circlepath"
        default:       return "person.badge.plus"
        }
    }
    private var headTitle: String {
        switch store.addPhase {
        case .naming:  return L("识别成功")
        case .failed:  return L("添加失败")
        case .working: return L("正在添加")
        default:       return L("添加账号 / workspace")
        }
    }
    private var headSub: String {
        switch store.addPhase {
        case .naming:  return L("已存好，空间名自动读取")
        case .failed:  return L("可以关掉重试")
        case .working: return L("过程中别关这个窗口")
        default:       return L("整个流程只有输账号密码需要你操作")
        }
    }
}

// MARK: - 窗口

/// 主窗口层级：设置里开了「窗口置顶」才浮动；添加账号期间一律退回普通层，
/// 因为用户要在 ChatGPT 自己的登录窗里操作，浮动层会挡路。
enum AppWindow {
    private(set) static var addFlowActive = false
    static var pinned: Bool { UserDefaults.standard.bool(forKey: "pinOnTop") }

    static func setAddFlow(_ on: Bool) {
        addFlowActive = on
        apply()
        DispatchQueue.main.async { apply() }
    }

    /// 外观：system 跟随系统，light / dark 固定
    static func setAppearance(_ v: String) {
        NSApp.appearance = v == "light" ? NSAppearance(named: .aqua) : v == "dark" ? NSAppearance(named: .darkAqua) : nil
    }

    /// 按当前状态刷新所有窗口的层级（sheet 是独立 NSWindow，不能只改主窗口）
    static func apply() {
        for w in NSApp.windows where w.isVisible {
            w.level = pinned && !addFlowActive ? .floating : .normal
        }
    }

    /// 登录那一步整个 app 让位：只降层级不够，活跃 app 的窗口天然压在别人上面
    static func stepAsideForLogin() {
        addFlowActive = true
        apply()
        NSApp.hide(nil)
        // hide 之后系统会自己挑一个 app 激活，等这轮切换过去再把 ChatGPT 叫到前面
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { bringChatGPTForward() }
    }

    /// 收完凭证（或失败）后回到前台
    static func comeBack() {
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        apply()
    }

    /// 只激活已有的 ChatGPT 实例，不会另开一个默认 profile 的窗口
    private static func bringChatGPTForward() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") else { return }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = true
        cfg.createsNewApplicationInstance = false
        NSWorkspace.shared.openApplication(at: url, configuration: cfg, completionHandler: nil)
    }
}

// MARK: - 入口
//
// 用标准的 SwiftUI App + Window：工具栏、侧栏收起按钮、全屏时菜单栏 / 工具栏的滑出、
// 红绿灯在侧栏顶部的位置都交给系统，和系统自带的 App 一致（以前手搭 NSWindow，
// 全屏和「没有工具栏按钮的页面」都会错位）。

@main
enum Entry {
    static func main() {
        // 后台服务（Python）借本 App 发系统通知：不起界面，发完就退
        if CommandLine.arguments.count >= 2 && CommandLine.arguments[1] == "--notify" {
            exit(Notifier.post(Array(CommandLine.arguments.dropFirst(2))))
        }
        // 后台切号时 ChatGPT 自己跳到了最前面：隐藏它，焦点回到用户原来的 App（同 Cmd+H，不需要授权）
        if CommandLine.arguments.count >= 3 && CommandLine.arguments[1] == "--hide-app" {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: CommandLine.arguments[2])
            apps.forEach { _ = $0.hide() }       // hide() 对后台 App 常返回 false 但照样隐藏了，只看有没有这个 App
            exit(apps.isEmpty ? 1 : 0)
        }
        // 后台切号时 ChatGPT 抢了前台：把焦点还给用户原来在用的 App（不发 reopen，不会给它新开窗口）
        if CommandLine.arguments.count >= 3 && CommandLine.arguments[1] == "--activate-app" {
            let apps = NSRunningApplication.runningApplications(withBundleIdentifier: CommandLine.arguments[2])
            exit(apps.map { $0.activate(options: []) }.contains(true) ? 0 : 1)
        }
        // 后台服务被 Cloudflare 拦住时，借 WebKit 调 chatgpt.com 的接口（见 WebFetch.swift）
        if CommandLine.arguments.count >= 2 && CommandLine.arguments[1] == "--web-fetch" { WebFetch.run() }
        AccountsApp.main()
    }
}

/// `ChatGPTAccounts --notify 标题 [正文]`：以本 App 的身份发一条系统通知。
/// osascript 发的通知图标是「脚本编辑器」，从本 App 的可执行文件发，图标和名字才是本 App。
/// 权限在 App 启动时申请（这里不弹窗，免得卡住后台服务）。
/// 退出码：0 已发出；2 用户关了本 App 的通知（调用方别再补发）；1 没权限 / 失败（调用方退回 osascript）
enum Notifier {
    private final class Result: @unchecked Sendable { var code: Int32 = 1 }

    static func post(_ args: [String]) -> Int32 {
        let title = args.first ?? "", body = args.count > 1 ? args[1] : ""
        let center = UNUserNotificationCenter.current()
        let result = Result(), done = DispatchSemaphore(value: 0)
        center.getNotificationSettings { s in
            switch s.authorizationStatus {
            case .denied:
                result.code = 2; done.signal()
            case .authorized, .provisional:
                let c = UNMutableNotificationContent()
                // 和以前 osascript 的样子一致：第一行是 App 名，下面是消息
                c.title = L("ChatGPT 账号")
                if body.isEmpty { c.body = title } else { c.subtitle = title; c.body = body }
                c.sound = .default
                center.add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)) { err in
                    result.code = err == nil ? 0 : 1; done.signal()
                }
            default:
                done.signal()
            }
        }
        _ = done.wait(timeout: .now() + 10)
        return result.code
    }
}

struct AccountsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store: Store

    init() {
        // 不做窗口状态恢复：否则调试时被结束一次，下次启动会先弹「意外退出，是否重新打开窗口」
        UserDefaults.standard.set(true, forKey: "ApplePersistenceIgnoreState")
        // 编辑菜单里系统自动加的「听写」「表情与符号」用不到
        UserDefaults.standard.set(true, forKey: "NSDisabledDictationMenuItem")
        UserDefaults.standard.set(true, forKey: "NSDisabledCharacterPaletteMenuItem")
        let s = Store()
        s.loadNow()
        _store = StateObject(wrappedValue: s)
    }

    var body: some Scene {
        Window("ChatGPT 账号", id: "main") {
            RootView(store: store)
                // 全屏时工具栏常显（和 Safari、访达一样）；否则没有工具栏按钮的页面会被系统收起标题栏、内容整体上移
                .fullScreenToolbarVisible()
        }
        .defaultSize(width: 1280, height: 820)
        .windowToolbarStyle(.unified)
        .commands {
            // 菜单栏只留用得到的：应用菜单（关于 / 隐藏 / 退出）和编辑菜单（剪切 / 拷贝 / 粘贴 / 全选，输入框要靠它）
            // 分两组：较早的 SDK（Xcode 26.0）里 commands 一层最多 10 项
            Group {
                CommandGroup(replacing: .newItem) {}
                CommandGroup(replacing: .saveItem) {}
                CommandGroup(replacing: .importExport) {}
                CommandGroup(replacing: .printItem) {}
                CommandGroup(replacing: .systemServices) {}
                CommandGroup(replacing: .appVisibility) {
                    Button("隐藏 ChatGPT 账号") { NSApp.hide(nil) }.keyboardShortcut("h")
                }
                CommandGroup(replacing: .undoRedo) {}
                CommandGroup(replacing: .textEditing) {}
            }
            Group {
                CommandGroup(replacing: .textFormatting) {}
                CommandGroup(replacing: .toolbar) {}
                CommandGroup(replacing: .sidebar) {}
                CommandGroup(replacing: .windowSize) {}
                CommandGroup(replacing: .windowList) {}
                CommandGroup(replacing: .windowArrangement) {}
                CommandGroup(replacing: .help) {}
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.activate(ignoringOtherApps: true)
        // 后台服务的通知借本 App 的身份发（Notifier），权限在这里申请一次；演示模式不弹
        if ProcessInfo.processInfo.environment["CGA_DEMO"] != "1" {
            UNUserNotificationCenter.current().delegate = self
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            // 别让工具栏搜索框一启动就抢到焦点
            NSApp.keyWindow?.makeFirstResponder(nil)
            // 不恢复上次的窗口状态（等同 SwiftUI 的 restorationBehavior(.disabled)，那个要 macOS 15）
            NSApp.windows.forEach { $0.isRestorable = false }
            AppWindow.apply()
            if CommandLine.arguments.contains("--fullscreen"), let w = NSApp.windows.first(where: { $0.canBecomeMain && $0.isVisible }) {
                // 截图用：固定在主屏（带菜单栏的那块）上全屏，接了外接显示器截出来的尺寸也和以前一样
                if let main = NSScreen.screens.first { w.setFrame(main.visibleFrame, display: true) }
                w.toggleFullScreen(nil)
            }
        }
        // 「显示」「窗口」「帮助」三个菜单系统会自己补上条目（进入全屏、最小化、帮助搜索），
        // commands 清不干净，整个菜单拿掉。SwiftUI 切页、切前台时会重建菜单，所以盯着主菜单的变化，
        // 但要等它这一轮改完再清：在通知回调里当场删，整个窗口会点不动（实测侧栏、按钮都失灵）
        NotificationCenter.default.addObserver(forName: NSMenu.didAddItemNotification, object: nil, queue: .main) { n in
            guard (n.object as? NSMenu) === NSApp.mainMenu else { return }
            MainActor.assumeIsolated { self.scheduleTrim() }
        }
        scheduleTrim()
        if CommandLine.arguments.contains("--dump-windows") {
            for t in stride(from: 4.0, through: 28, by: 4) { DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                print("--- t=\(t)")
                print("active", NSApp.isActive, "key", NSApp.keyWindow.map { "\($0.windowNumber)" } ?? "nil",
                      "main", NSApp.mainWindow.map { "\($0.windowNumber)" } ?? "nil", "modal", NSApp.modalWindow.map { "\($0.windowNumber)" } ?? "nil")
                for w in NSApp.windows {
                    print(w.windowNumber, type(of: w), "visible", w.isVisible, "key", w.isKeyWindow, "canKey", w.canBecomeKey,
                          "level", w.level.rawValue, "ignoresMouse", w.ignoresMouseEvents, "sheet", w.attachedSheet != nil,
                          "frame", w.frame, "fs", w.styleMask.contains(.fullScreen),
                          "firstResponder", w.firstResponder.map { "\(type(of: $0))" } ?? "nil")
                }
                fflush(stdout)
            } }
        }
        if CommandLine.arguments.contains("--dump-menu") {
            for t in [2.0, 12.0] { DispatchQueue.main.asyncAfter(deadline: .now() + t) {
                print("--- t=\(t) trims=\(AppDelegate.trims)")
                for m in NSApp.mainMenu?.items ?? [] where !m.isHidden {
                    print("[\(m.title)]", (m.submenu?.items ?? []).filter { !$0.isHidden }
                        .map { $0.isSeparatorItem ? "—" : $0.title }.joined(separator: " | "))
                }
                fflush(stdout)
            } }
        }
    }

    private var pendingTrim: DispatchWorkItem?

    private func scheduleTrim() {
        pendingTrim?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.trimMenu() }
        pendingTrim = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: w)
    }

    private(set) static var trims = 0

    /// 只隐藏不删除：删了 SwiftUI 会发现和它的菜单模型对不上，转头又加回来，来回拉锯
    private func trimMenu() {
        guard let main = NSApp.mainMenu else { return }
        AppDelegate.trims += 1
        func hide(_ it: NSMenuItem, _ h: Bool) { if it.isHidden != h { it.isHidden = h } }
        for item in main.items.dropFirst() {    // 第一个是应用菜单
            let sub = item.submenu
            let useless = sub == nil || sub === NSApp.windowsMenu || sub === NSApp.helpMenu
                || ["View", "显示", "Window", "窗口", "Help", "帮助", "File", "文件", "Format", "格式"].contains(item.title)  // i18n-ignore  系统菜单标题，两种语言都认
            hide(item, useless)
        }
        // 藏掉系统补的「自动填充」，再把连在一起 / 落在首尾的分隔线藏掉
        for menu in main.items.filter({ !$0.isHidden }).compactMap(\.submenu) {
            for it in menu.items where ["自动填充", "AutoFill"].contains(it.title) { hide(it, true) }  // i18n-ignore
            var prevSep = true
            var lastShown: NSMenuItem?
            for it in menu.items where !(it.isHidden && !it.isSeparatorItem) {
                if it.isSeparatorItem {
                    hide(it, prevSep)
                    if !prevSep { prevSep = true; lastShown = it }
                } else {
                    prevSep = false; lastShown = it
                }
            }
            if let l = lastShown, l.isSeparatorItem { hide(l, true) }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }

    /// 本 App 在前台时系统默认不弹横幅；后台服务的提醒照样要看得见
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler done: @escaping (UNNotificationPresentationOptions) -> Void) {
        done([.banner, .list, .sound])
    }
}
