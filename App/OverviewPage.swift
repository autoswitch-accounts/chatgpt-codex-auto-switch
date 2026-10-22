import SwiftUI
import Charts

// MARK: - 概览（工作台）

struct OverviewPage: View {
    @ObservedObject var store: Store
    let go: (Page) -> Void
    @State private var hovered: String? = nil      // 额度图上鼠标所在的账号（槽位字母）

    /// 额度图和自动切号卡片同高（取两者中高的那个）；下面四张列表卡片同高，行多了在卡片里滚动
    static let chartRowHeight: CGFloat = 380
    static let listHeight: CGFloat = 268
    static let chartVisible = 12               // 额度图一屏显示的账号数

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                metrics
                // 自动切号卡片内容多（当前 + 下一个账号的额度）时整行跟着长高，额度图至少 chartRowHeight
                HStack(alignment: .top, spacing: 16) {
                    quotaChart.frame(maxWidth: .infinity, minHeight: Self.chartRowHeight, maxHeight: .infinity)
                    AutoCard(store: store, go: go).frame(width: 340).frame(maxHeight: .infinity)
                }
                .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: 16) {
                    renewals.frame(maxWidth: .infinity)
                    duesCard.frame(maxWidth: .infinity)
                }
                HStack(alignment: .top, spacing: 16) {
                    sessionsCard.frame(maxWidth: .infinity)
                    noticesCard.frame(maxWidth: .infinity)
                }
            }
            .padding(20)
        }
        .defaultScrollAnchor(.top)
        .navigationTitle("概览")
        .navigationSubtitle((store.appRunning ? "ChatGPT 运行中" : "ChatGPT 未运行") + " · "
                            + (store.syncing || store.refreshing ? "正在同步…"
                               : store.directory.at > 0 ? "同步于 \(TimeText.ago(store.directory.at, now: store.now))，后台每 30 分钟自动同步" : "还没同步过"))
        .pageToolbar {
            Button { store.syncAll() } label: { Label("全部刷新", systemImage: "arrow.clockwise") }
                .disabled(store.syncing || store.refreshing)
                .help("刷新额度并同步团队、订阅、成员")
        }
    }

    // MARK: 指标（宽窗口一行 6 个，窄了 3×2，两种都和下面的卡片左右对齐）

    private var metrics: some View {
        let tiles = metricTiles
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { ForEach(tiles.indices, id: \.self) { tiles[$0].frame(minWidth: 168) } }
            Grid(horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow { ForEach(0..<3) { tiles[$0] } }
                GridRow { ForEach(3..<6) { tiles[$0] } }
            }
        }
    }

    private var metricTiles: [AnyView] {
        let now = store.now
        let usable = store.slots.filter { $0.usable(now) }.count
        let cur = store.current
        let members = store.teams.reduce(0) { $0 + $1.activeMembers.count }
        let newMembers = store.teams.reduce(0) { $0 + $1.newMembers(now: now).count }
        let soon = store.upcomingRenewals(days: 7)
        let dues = store.duePayments(days: 3)
        let credits = store.directory.people.flatMap(\.availableResets)
        let firstExpiry = credits.map(\.expiresAt).filter { $0 > now }.min()
        func tile(_ t: MetricTile, _ action: @escaping () -> Void) -> AnyView {
            AnyView(Button(action: action) { t }.buttonStyle(CardButtonStyle()))
        }
        return [
            tile(MetricTile(title: "可用账号", value: "\(usable)", unit: "/ \(store.slots.count)",
                            detail: cur.map { "当前 \($0.slot) · \($0.email.components(separatedBy: "@")[0])" } ?? "当前账号不在列表里",
                            icon: "person.2.fill", tint: usable > 0 ? Palette.green : Palette.red)) { go(.accounts) },
            tile(MetricTile(title: "当前 5 小时剩余", value: cur.map { "\(Int(max(0, $0.remaining5h(now)).rounded()))" } ?? "—", unit: "%",
                            detail: cur.map { "本周 \(Int(max(0, $0.remainingWeek(now)).rounded()))% · \(resetText($0.usage.primary, now: now)) 重置" } ?? "",
                            icon: "gauge.with.dots.needle.67percent", tint: Palette.quota(cur?.remaining5h(now) ?? 0))) {
                store.focus = cur?.slot; go(.accounts)
            },
            tile(MetricTile(title: "团队", value: "\(store.teams.count)", unit: "个",
                            detail: "\(members) 名成员" + (newMembers > 0 ? " · 新增 \(newMembers)" : ""),
                            icon: "building.2.fill", tint: Palette.purple)) { go(.teams) },
            tile(MetricTile(title: "7 天内续费", value: "\(soon.count)", unit: "个",
                            detail: soon.first.map { "\($0.displayName) \(TimeText.date($0.sub.nextDate).dropFirst(5))" } ?? "近期没有",
                            icon: "creditcard.fill", tint: soon.contains { $0.sub.nextDate - now <= 3 * 86400 } ? Palette.orange : Palette.indigo)) {
                if let f = soon.first { store.focus = f.id }
                go(.teams)
            },
            tile(MetricTile(title: "待交费", value: "\(dues.count)", unit: "人",
                            detail: dues.first.map { "\($0.wechat.isEmpty ? $0.email.components(separatedBy: "@")[0] : $0.wechat) \(TimeText.date($0.nextPay).dropFirst(5))" } ?? "近期没有",
                            icon: "yensign.circle.fill", tint: dues.isEmpty ? Palette.gray : Palette.orange)) { go(.members) },
            tile(MetricTile(title: "额度重置券", value: "\(credits.count)", unit: "张",
                            detail: firstExpiry.map { "最早 \(TimeText.short($0)) 过期 · 点击使用" } ?? "",
                            icon: "arrow.counterclockwise.circle.fill", tint: Palette.teal)) { store.showResets = true },
        ]
    }

    // MARK: 额度图

    private struct QuotaPoint: Identifiable {
        let slot: String; let window: String; let left: Double
        var id: String { slot + window }
    }

    private var quotaChart: some View {
        let pts = store.slots.flatMap { s -> [QuotaPoint] in
            [QuotaPoint(slot: s.slot, window: "5 小时", left: max(0, s.remaining5h(store.now))),
             QuotaPoint(slot: s.slot, window: "本周", left: max(0, s.remainingWeek(store.now)))]
        }
        return Card {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(title: "各账号剩余额度", icon: "chart.bar.xaxis") {
                    Button("账号管理") { go(.accounts) }.buttonStyle(.link)
                }
                Chart {
                    if let h = hovered {               // 鼠标所在的那组柱子垫一层底色
                        RectangleMark(x: .value("账号", h), yStart: .value("剩余", 0), yEnd: .value("剩余", 112))
                            .foregroundStyle(Color.primary.opacity(0.06))
                    }
                    ForEach(pts) { p in
                        BarMark(x: .value("账号", p.slot), y: .value("剩余", p.left), width: .ratio(0.8))
                            .foregroundStyle(by: .value("窗口", p.window))
                            .position(by: .value("窗口", p.window))
                            .cornerRadius(3)
                            .annotation(position: .top, spacing: 3) {
                                Text("\(Int(p.left.rounded()))")
                                    .font(.system(size: 10, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(p.window == "5 小时" ? Palette.accent : Palette.teal)
                            }
                    }
                }
                .chartForegroundStyleScale(["5 小时": Palette.accent, "本周": Palette.teal])
                // 横轴固定按槽位排：悬停底色画在柱子前面，不固定的话被悬停的账号会被挪到第一位
                .chartXScale(domain: store.slots.map(\.slot))
                .chartYScale(domain: 0...112)          // 顶上留出放数字的空间，刻度仍只到 100%
                .chartYAxis { AxisMarks(values: [0, 25, 50, 75, 100]) { v in
                    AxisGridLine(); AxisValueLabel { Text("\(v.as(Int.self) ?? 0)%") } } }
                .chartLegend(position: .top, alignment: .trailing)
                // 账号多了柱子不再挤扁：一屏最多 12 个账号，其余横向滚动，纵轴固定不动
                .chartScrollableAxes(store.slots.count > Self.chartVisible ? .horizontal : [])
                .chartXVisibleDomain(length: max(1, min(store.slots.count, Self.chartVisible)))
                .chartOverlay { proxy in hoverLayer(proxy) }
                .frame(maxHeight: .infinity)
                if let cur = store.current {
                    Text("当前账号 \(cur.slot) · 5 小时额度从第一次使用开始滚动计时，没用过的账号显示 100%"
                         + (store.slots.count > Self.chartVisible ? " · 左右滑动看其余账号" : ""))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    /// 悬停：鼠标下是哪个账号就浮出它的卡片（槽位、邮箱、空间、两个窗口的剩余和重置时间），点一下去账号页
    private func hoverLayer(_ proxy: ChartProxy) -> some View {
        GeometryReader { geo in
            let plot = proxy.plotFrame.map { geo[$0] } ?? .zero
            ZStack(alignment: .topLeading) {
                Rectangle().fill(.clear).contentShape(Rectangle())
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let pt):
                            let slot: String? = plot.contains(pt) ? proxy.value(atX: pt.x - plot.minX, as: String.self) : nil
                            if slot != hovered { hovered = slot }
                        case .ended:
                            hovered = nil
                        }
                    }
                    .onTapGesture { if let h = hovered { store.focus = h; go(.accounts) } }
                if let h = hovered, let s = store.slots.first(where: { $0.slot == h }),
                   let x = proxy.position(forX: h) {
                    let w: CGFloat = 250
                    // 卡片放在这组柱子右边，靠右放不下就放左边
                    let cx = plot.minX + x
                    let left = cx + 30 + w <= geo.size.width ? cx + 30 : cx - 30 - w
                    QuotaTip(s: s, ws: store.workspace(of: s), now: store.now)
                        .frame(width: w)
                        .offset(x: max(0, left), y: plot.minY + 8)
                        .allowsHitTesting(false)
                        .transition(.opacity)
                }
            }
        }
    }

    // MARK: 续费时间线

    private var renewals: some View {
        let list = store.upcomingRenewals(days: 31)
        return ListCard(title: "续费 / 到期时间线（30 天）", icon: "calendar",
                        empty: list.isEmpty ? (store.directory.at == 0 ? "还没同步过订阅信息" : "30 天内没有续费或到期") : nil) {
            Button("团队") { go(.teams) }.buttonStyle(.link)
        } rows: {
            ForEach(list) { w in
                let d = TimeText.daysLeft(w.sub.nextDate, now: store.now)
                let stop = w.sub.nextLabel == "到期"
                HStack(spacing: 10) {
                    VStack(spacing: 0) {
                        Text(TimeText.date(w.sub.nextDate).dropFirst(5)).font(.callout.weight(.semibold).monospacedDigit())
                        Text("\(d) 天后").font(.caption2).foregroundStyle(d <= 3 ? Palette.orange : .secondary)
                    }
                    .frame(width: 58)
                    Rectangle().fill(d <= 3 ? Palette.orange : Palette.line).frame(width: 2, height: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(w.displayName).font(.callout.weight(.medium)).lineLimit(1)
                        Text([w.planName, w.sub.billingText, w.sub.seatsTotal > 0 ? "\(w.sub.seatsUsed)/\(w.sub.seatsTotal) 席" : ""]
                            .filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Pill(text: stop ? "到期" : "自动续费", color: stop ? Palette.red : Palette.green)
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
                .hoverRow { store.focus = w.id; go(.teams) }
            }
        }
    }

    // MARK: 待交费成员

    private var duesCard: some View {
        let list = store.duePayments(days: 7)
        return ListCard(title: "待交费的成员（\(list.count)）", icon: "yensign.circle",
                        empty: list.isEmpty ? "7 天内没有人要交费，也没有逾期的" : nil) {
            Button("成员台账") { go(.members) }.buttonStyle(.link)
        } rows: {
            ForEach(list) { r in
                HStack(spacing: 10) {
                    PayText(epoch: r.nextPay, now: store.now, manual: r.m.payManual == true).frame(width: 64, alignment: .leading)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(r.wechat.isEmpty ? r.email : "\(r.wechat) · \(r.email)").font(.callout.weight(.medium)).lineLimit(1)
                        Text("\(r.team) · 所有者 \(r.owner)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
                .hoverRow { store.editingMember = r }
            }
        }
    }

    // MARK: 对话

    private var sessionsCard: some View {
        let list = store.activeSessions
        let shown = list.isEmpty ? Array(store.sessions.prefix(20)) : list
        return ListCard(title: list.isEmpty ? "最近的对话" : "进行中的对话（\(list.count)）", icon: "bubble.left.and.bubble.right",
                        empty: shown.isEmpty ? "48 小时内没有对话" : nil) {
            Button("全部") { go(.sessions) }.buttonStyle(.link)
        } rows: {
            ForEach(shown) { s in
                SessionLine(s: s, now: store.now).hoverRow { store.focus = s.thread; go(.sessions) }
            }
        }
    }

    // MARK: 消息 / 日志

    private var noticesCard: some View {
        ListCard(title: "最新消息", icon: "bell", empty: store.notices.isEmpty ? "暂无消息" : nil) {
            Button("全部消息") { go(.messages) }.buttonStyle(.link)
        } rows: {
            ForEach(store.notices.prefix(30)) { n in
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: NoticeLook.icon(n)).foregroundStyle(Palette.level(n.level)).frame(width: 16)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(n.title).font(.callout.weight(n.read ? .regular : .semibold)).lineLimit(1)
                        Text(TimeText.ago(n.created, now: store.now)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    if !n.read { Circle().fill(Palette.accent).frame(width: 6, height: 6).padding(.top, 5) }
                }
                .hoverRow { if !n.read { store.markRead([n.id]) }; go(.messages) }
            }
        }
    }
}

/// 额度图的悬停卡片
private struct QuotaTip: View {
    let s: Slot
    let ws: Workspace?
    let now: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Avatar(letter: s.slot, size: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.email).font(.callout.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                    Text([ws.map { $0.isTeam ? $0.displayName : "个人空间" } ?? s.title, s.planLabel, s.name,
                          (s.wechat ?? "").isEmpty ? "" : "微信 \(s.wechat!)"]
                            .filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Divider()
            row("5 小时", s.usage.primary, color: Palette.accent)
            row("本周", s.usage.secondary, color: Palette.teal)
            Text(status).font(.caption.weight(.medium)).foregroundStyle(statusColor)
        }
        .padding(12)
        .background(Palette.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Palette.line))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
    }

    private func row(_ title: String, _ w: UsageWindow?, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(w.map { "剩 \(Int(max(0, $0.remaining(now: now)).rounded()))%" } ?? "—").monospacedDigit()
            Text(resetText(w, now: now)).foregroundStyle(.secondary).monospacedDigit().frame(width: 74, alignment: .trailing)
        }
        .font(.caption)
    }

    private var status: String {
        if s.needsLogin { return "需要重新登录" }
        if s.current { return "正在使用 · 点击查看详情" }
        if let t = s.exhaustedUntil(now) { return "额度用完 · \(TimeText.short(t)) 恢复" }
        return s.usable(now) ? "可用 · 点击查看详情" : "额度未知 · 点击查看详情"
    }
    private var statusColor: Color {
        if s.needsLogin || s.exhaustedUntil(now) != nil { return Palette.red }
        return s.current ? Palette.accent : Palette.green
    }
}

/// 固定高度的列表卡片：标题不动，行多了在卡片里滚动，空的时候显示一句说明
private struct ListCard<Trailing: View, Rows: View>: View {
    let title: String
    let icon: String
    var empty: String? = nil
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var rows: Rows
    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                SectionTitle(title: title, icon: icon) { trailing }
                if let empty {
                    Text(empty).font(.callout).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 2) { rows }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                }
            }
            .frame(height: OverviewPage.listHeight, alignment: .top)
        }
    }
}

/// 自动切号卡片：开关 + 状态 + 当前账号的额度 + 下一个账号
struct AutoCard: View {
    @ObservedObject var store: Store
    let go: (Page) -> Void
    var body: some View {
        let a = store.auto
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Image(systemName: "arrow.triangle.2.circlepath").foregroundStyle(.secondary)
                    Text("自动切号并续答").font(.headline)
                    Spacer()
                    Toggle("", isOn: Binding(get: { store.config.enabled }, set: { store.setAuto($0) }))
                        .toggleStyle(SwitchStyle()).labelsHidden()
                }
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: AutoCard.icon(a)).foregroundStyle(AutoCard.color(a))
                    Text(AutoCard.text(a, prompt: store.config.prompt)).font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(AutoCard.color(a).opacity(0.12)))

                if a.enabled && !a.alive {
                    Button("启动后台服务") { store.restartDaemon() }.buttonStyle(.borderedProminent)
                }
                if a.phase == "waiting" && a.waitUntil > store.now {
                    LabeledContent("等待恢复") {
                        Text("\(TimeText.short(a.waitUntil)) · \(TimeText.until(a.waitUntil, now: store.now))")
                            .foregroundStyle(Palette.orange).monospacedDigit()
                    }
                }
                Divider()
                if let c = store.current {
                    account(c, role: "当前账号", tint: Palette.green)
                } else {
                    roleTag("当前账号", Palette.green)
                    Text("当前登录的账号不在列表里").foregroundStyle(.secondary)
                }
                Divider()
                if let n = store.nextSlot() {
                    account(n, role: "下一个", tint: Palette.accent)
                } else {
                    roleTag("下一个", Palette.accent)
                    Text("没有可用账号，等最早恢复的").foregroundStyle(Palette.orange)
                }
                // 切号顺序、续答用语等设置只在设置页显示，这里只放账号
                if a.queue > 0 {
                    Divider()
                    LabeledContent("待续答", value: "\(a.queue) 个对话")
                }
            }
            .font(.callout)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    /// 当前 / 下一个账号：是谁、在哪个空间，5 小时 / 本周还剩多少、什么时候重置；点一下去账号详情
    /// （同一个邮箱可能有好几个空间，所以空间名和槽位都要写出来）
    private func account(_ c: Slot, role: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            roleTag(role, tint)
            HStack(spacing: 8) {
                Avatar(letter: c.slot, size: 26)
                    .overlay { Circle().strokeBorder(tint, lineWidth: 2).padding(-3) }
                VStack(alignment: .leading, spacing: 1) {
                    Text(c.email).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
                    Text(["槽 \(c.slot)", store.workspace(of: c).map { $0.isTeam ? $0.displayName : "个人空间" } ?? c.title, c.planLabel]
                            .filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
            }
            quotaLine("5 小时", c.usage.primary)
            quotaLine("本周", c.usage.secondary)
        }
        .contentShape(Rectangle())
        .onTapGesture { store.focus = c.slot; go(.accounts) }
        .help("查看\(role)账号的详情")
    }

    /// 「当前账号」「下一个」的彩色标签
    private func roleTag(_ text: String, _ tint: Color) -> some View {
        Text(text).font(.caption.weight(.bold)).foregroundStyle(tint)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(tint.opacity(0.15)))
    }

    private func quotaLine(_ title: String, _ w: UsageWindow?) -> some View {
        let left = w.map { max(0, $0.remaining(now: store.now)) }
        return HStack(spacing: 8) {
            Text(title).foregroundStyle(.secondary).frame(width: 40, alignment: .leading)
            QuotaBar(value: left ?? 0, height: 6)
            Text(left.map { "\(Int($0.rounded()))%" } ?? "—")
                .fontWeight(.semibold).monospacedDigit().foregroundStyle(left.map(Palette.quota) ?? Palette.text3)
                .frame(width: 38, alignment: .trailing)
            Text(resetLabel(w)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                .frame(width: 92, alignment: .trailing)
        }
    }

    private func resetLabel(_ w: UsageWindow?) -> String {
        let t = resetText(w, now: store.now)
        return t == "—" || t == "已重置" || t == "未使用" ? t : t + " 重置"
    }

    static func text(_ a: AutoStatus, prompt: String) -> String {
        if !a.enabled { return "已关闭：额度用完时不会自动换号，也不会自动续答" }
        if !a.alive { return "后台服务没有运行，自动切号暂时不会生效" }
        if a.phase == "idle" || a.text.isEmpty {
            return "监控中：当前账号额度用完会切到下一个可用账号，并在中断的对话里发「\(prompt)」"
        }
        return a.text
    }

    static func icon(_ a: AutoStatus) -> String {
        if !a.enabled { return "pause.circle.fill" }
        if !a.alive { return "exclamationmark.triangle.fill" }
        switch a.phase {
        case "switching": return "arrow.triangle.2.circlepath"
        case "waiting":   return "hourglass"
        case "resuming":  return "text.bubble.fill"
        default:          return "checkmark.shield.fill"
        }
    }

    static func color(_ a: AutoStatus) -> Color {
        if !a.enabled { return Palette.gray }
        if !a.alive { return Palette.orange }
        switch a.phase {
        case "waiting":   return Palette.orange
        case "switching", "resuming": return Palette.accent
        default:          return Palette.green
        }
    }
}
