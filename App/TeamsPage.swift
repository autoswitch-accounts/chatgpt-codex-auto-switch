import SwiftUI
import AppKit

// MARK: - 团队页：只列团队空间；点一行右侧浮出成员台账和订阅

struct SpaceRow: Identifiable {
    let w: Workspace
    let due: Int                 // 3 天内该交费的成员数
    let now: Double
    var id: String { w.id }
    var name: String { w.displayName }
    var owner: String { w.ownerEmail }
    var seats: Int { w.sub.seatsUsed }
    var members: Int { w.members.map { _ in w.activeMembers.count } ?? -1 }
    var newCount: Int { w.newMembers(now: now).count }
    var renew: Double { let t = w.sub.nextDate; return t > 0 ? t : .infinity }
    var statusRank: Int { w.deactivated ? 3 : (w.sub.delinquent ? 2 : (w.sub.active ? 0 : 1)) }
}

struct TeamsPage: View {
    @ObservedObject var store: Store
    @State private var selection: String? = nil
    @State private var order = [KeyPathComparator(\SpaceRow.renew)]
    @State private var query = ""
    @State private var scope = "all"
    @State private var hideAsk: Workspace? = nil

    private var rows: [SpaceRow] {
        let due = Dictionary(grouping: store.duePayments(days: 3), by: { $0.w.id }).mapValues(\.count)
        var ws = store.teams
        switch scope {
        case "renew": ws = ws.filter { $0.sub.nextDate > 0 && $0.sub.nextDate - store.now <= 30 * 86400 }
        case "due":   ws = ws.filter { (due[$0.id] ?? 0) > 0 || !$0.newMembers(now: store.now).isEmpty }
        default: break
        }
        if !query.isEmpty {
            ws = ws.filter { w in w.displayName.localizedCaseInsensitiveContains(query)
                || w.ownerEmail.localizedCaseInsensitiveContains(query)
                || (w.members ?? []).contains { $0.email.localizedCaseInsensitiveContains(query)
                    || ($0.wechat ?? "").localizedCaseInsensitiveContains(query) } }
        }
        return ws.map { SpaceRow(w: $0, due: due[$0.id] ?? 0, now: store.now) }.sorted(using: order)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("", selection: $scope) {
                    Text("全部团队").tag("all"); Text("30 天内续费").tag("renew"); Text("有新成员 / 待交费").tag("due")
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                let hidden = store.hiddenTeams
                if !hidden.isEmpty {
                    Menu {
                        ForEach(hidden) { w in Button("恢复「\(w.displayName)」") { store.hideTeam(w, false) } }
                    } label: { Text("已移除 \(hidden.count) 个") }
                    .menuStyle(.borderlessButton).fixedSize().foregroundStyle(.secondary)
                    .help("从列表移除的团队，点这里可以恢复显示")
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Table(rows, selection: $selection, sortOrder: $order) {
                TableColumn(L("团队#列", zh: "团队"), value: \.name) { r in
                    HStack(spacing: 9) {
                        Image(systemName: "building.2.fill")
                            .font(.system(size: 11)).foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Palette.purple.gradient))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(r.name).fontWeight(.medium).lineLimit(1)
                            Text(r.w.slots.isEmpty ? (r.w.planName.isEmpty ? "Business" : r.w.planName)
                                 : L("槽 \(r.w.slots.joined(separator: L("、")))"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 3)
                }
                .width(min: 160, ideal: 200)
                TableColumn("所有者", value: \.owner) { r in Text(r.owner).lineLimit(1).foregroundStyle(.secondary) }
                    .width(min: 150, ideal: 210)
                TableColumn("席位", value: \.seats) { r in
                    Text(r.w.sub.seatsTotal > 0 ? "\(r.w.sub.seatsUsed) / \(r.w.sub.seatsTotal)" : "—").monospacedDigit()
                }
                .width(min: 50, ideal: 60)
                TableColumn("成员", value: \.members) { r in
                    HStack(spacing: 5) {
                        Text(r.members < 0 ? "—" : AppLanguage.active == "en" ? "\(r.members)" : L("\(r.members) 人")).monospacedDigit()
                        if r.newCount > 0 { Pill(text: L("新 \(r.newCount)"), color: Palette.green) }
                    }
                }
                .width(min: 80, ideal: 96)
                TableColumn("待交费", value: \.due) { r in
                    if r.due > 0 { Pill(text: L("\(r.due) 人 3 天内"), color: Palette.orange) } else { Text("—").foregroundStyle(.tertiary) }
                }
                .width(min: 70, ideal: 90)
                TableColumn("续费 / 到期", value: \.renew) { r in RenewCell(ws: r.w, now: store.now) }
                    .width(min: 96, ideal: AppLanguage.active == "en" ? 130 : 116)   // 英文表头「Renews / Expires」更宽
                TableColumn("状态", value: \.statusRank) { r in
                    if r.w.deactivated {
                        HStack(spacing: 8) {
                            StatusChip(text: L("已停用"), color: Palette.red)
                            Button("移除") { hideAsk = r.w }.glassButton().controlSize(.small)
                                .help("从团队列表里拿掉（只改本机显示，不动 ChatGPT 那边）")
                        }
                    }
                    else if r.w.sub.delinquent { StatusChip(text: L("欠费"), color: Palette.red) }
                    else if r.w.sub.active { StatusChip(text: L("正常"), color: Palette.green) }
                    else { StatusChip(text: L("未订阅"), color: Palette.gray) }
                }
                .width(min: 120, ideal: AppLanguage.active == "en" ? 165 : 130)   // 英文「Deactivated」+「Remove」更宽
            }
            .alternatingRowBackgrounds(.disabled)   // 不要斑马纹：和概览、设置一样透出页面底色
            .scrollContentBackground(.hidden)
            .contextMenu(forSelectionType: String.self) { ids in
                if let id = ids.first, let w = store.directory.workspace(id), w.deactivated {
                    Button("从列表移除…") { hideAsk = w }
                }
            }
            .alert("从团队列表移除「\(hideAsk?.displayName ?? "")」？", isPresented: Binding(get: { hideAsk != nil }, set: { if !$0 { hideAsk = nil } })) {
                Button("移除") { if let w = hideAsk { store.hideTeam(w, true); if selection == w.id { selection = nil } } }
                Button("取消", role: .cancel) {}
            } message: {
                Text("这个空间已停用。只是在这里不再显示，不会动 ChatGPT 那边的空间；之后可以在右上角「已移除」里恢复。")
            }
        }
        .overlay(alignment: .trailing) {
            if let id = selection, let w = store.directory.workspace(id) {
                FloatingPanel(onClose: { selection = nil }) { SpaceInspector(store: store, w: w) }
            }
        }
        .animation(.snappy(duration: 0.28), value: selection)
        .navigationTitle("团队")
        .navigationSubtitle(L("\(store.teams.count) 个团队 · \(store.teams.reduce(0) { $0 + $1.activeMembers.count }) 名成员 · ")
                            + (store.syncing ? L("正在同步…") : store.directory.at > 0 ? L("同步于 \(TimeText.ago(store.directory.at, now: store.now))") : L("还没同步过")))
        .pageToolbar(search: $query, prompt: L("搜索团队 / 邮箱 / 微信名")) {
            Button { store.loadDirectory(refresh: true) } label: { Label("同步", systemImage: "arrow.triangle.2.circlepath") }
                .disabled(store.syncing).help("联网同步团队、订阅和成员")
        }
        .onAppear {
            if let f = store.focus, store.directory.workspace(f) != nil { selection = f; store.focus = nil }
        }
    }
}

/// 团队详情（浮动面板里）：订阅 + 成员台账
struct SpaceInspector: View {
    @ObservedObject var store: Store
    let w: Workspace
    @State private var showLeft = false

    var body: some View {
        let sub = w.sub
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(w.displayName).font(.title3.weight(.semibold)).padding(.trailing, 36)
                    Text("所有者 \(w.ownerEmail)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }

                PanelGroup(title: L("订阅")) {
                    if sub.nextDate > 0 {
                        // 和 sub.nextLabel（未订阅 / 续费 / 到期）同样的分支，拼成整句查表
                        InfoRow(!sub.active ? L("下次未订阅") : sub.willRenew && sub.cancelsAt == 0 ? L("下次续费") : L("下次到期"),
                                L("\(TimeText.date(sub.nextDate))（\(TimeText.daysLeft(sub.nextDate, now: store.now)) 天后）"))
                    } else {
                        InfoRow(L("状态"), w.deactivated ? L("已停用") : L("未订阅"))
                    }
                    if sub.active { InfoRow(L("自动续费"), sub.cancelsAt > 0 || !sub.willRenew ? L("已关闭") : L("开启")) }
                    if !sub.billing.isEmpty { InfoRow(L("计费"), [sub.billingText, sub.currency, sub.platformText].filter { !$0.isEmpty }.joined(separator: " · ")) }
                    if sub.seatsTotal > 0 { InfoRow(L("席位"), L("已用 \(sub.seatsUsed) / 共 \(sub.seatsTotal)")) }
                    if !sub.discount.isEmpty { InfoRow(L("优惠"), PhraseBook.shared.apply(sub.discount)) }
                    if sub.activeStart > 0 { InfoRow(L("开通于"), TimeText.date(sub.activeStart)) }
                    if !w.slots.isEmpty { InfoRow(L("槽位#多个", zh: "槽位"), w.slots.joined(separator: L("、"))) }
                    if !w.errors.isEmpty { InfoRow(L("同步问题"), w.errors.map { PhraseBook.shared.apply($0) }.joined(separator: L("；"))) }
                }

                if let members = w.members {
                    let active = members.filter(\.active).sorted { ($0.isOwner ? 0 : 1, -$0.joined) < ($1.isOwner ? 0 : 1, -$1.joined) }
                    let left = members.filter { !$0.active }
                    PanelGroup(title: L("成员 \(active.count)"), trailing: {
                        Button("导出") { export(members) }.glassButton().controlSize(.small)
                    }) {
                        ForEach(active) { m in
                            MemberLine(m: m, wechat: store.wechat(m.email), now: store.now)
                                .hoverRow { if !m.isOwner { store.editingMember = MemberRow(m: m, w: w) } }
                        }
                        if !left.isEmpty {
                            DisclosureGroup("已停用 \(left.count) 人", isExpanded: $showLeft) {
                                ForEach(left) { m in MemberLine(m: m, wechat: store.wechat(m.email), now: store.now) }
                            }
                            .font(.callout)
                        }
                        Text("点成员可以改微信名和交费日").font(.caption).foregroundStyle(.tertiary)
                    }
                } else {
                    Text(w.deactivated ? "空间已停用，无法查询成员" : "没有权限查看成员").font(.callout).foregroundStyle(.secondary)
                }

                if !w.invites.isEmpty {
                    PanelGroup(title: L("待接受邀请 \(w.invites.count)")) {
                        ForEach(w.invites) { i in
                            HStack {
                                Image(systemName: "envelope").foregroundStyle(.secondary)
                                Text(i.email).lineLimit(1)
                                Spacer()
                                Text(TimeText.date(i.created)).foregroundStyle(.secondary).monospacedDigit()
                            }
                            .font(.callout)
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private func export(_ members: [Member]) {
        let rows = members.map { [$0.email, store.wechat($0.email), Workspace.roleText($0.role), TimeText.date($0.joined),
                                  TimeText.date($0.nextPay ?? 0), $0.active ? L("在职") : L("已停用 \(TimeText.date($0.deactivatedAt))")] }
        if let url = exportCSV(name: L("\(w.displayName)-成员.csv"),
                               header: [L("邮箱"), L("微信名"), L("角色"), L("加入时间"), L("下次交费"), L("状态")], rows: rows) {
            store.say(L("已导出到 \(url.lastPathComponent)"))
        }
    }
}

/// 面板里的一组：小标题 + 内容
struct PanelGroup<Trailing: View, Content: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                trailing
            }
            content
        }
    }
}

extension PanelGroup where Trailing == EmptyView {
    init(title: String, @ViewBuilder content: () -> Content) {
        self.init(title: title, trailing: { EmptyView() }, content: content)
    }
}

/// 面板里的一位成员：邮箱 / 微信名 / 加入日 / 下次交费
struct MemberLine: View {
    let m: Member
    let wechat: String
    let now: Double
    var body: some View {
        let isNew = m.active && m.joined > 0 && now - m.joined <= 3 * 86400 && !m.isOwner
        HStack(spacing: 9) {
            ZStack {
                Circle().fill(m.isOwner ? Palette.accent.opacity(0.18) : Palette.fill)
                Text(String((wechat.isEmpty ? m.email : wechat).prefix(1)).uppercased())
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(m.isOwner ? Palette.accent : Palette.text2)
            }
            .frame(width: 26, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(m.email).lineLimit(1).truncationMode(.middle).strikethrough(!m.active)
                    if isNew { Pill(text: L("新"), color: Palette.green) }
                    if m.isOwner { Pill(text: L("所有者"), color: Palette.accent) }
                }
                Text([wechat.isEmpty ? "" : L("微信 \(wechat)"),
                      m.local == true ? L("本机已登录") + (m.viaSlot.map { $0.isEmpty ? "" : L("（槽 \($0)）") } ?? "") + L(" · 加入时间待同步")
                                      : L("\(String(TimeText.date(m.joined).dropFirst(2))) 加入")]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            if m.active, let p = m.nextPay { PayText(epoch: p, now: now, manual: m.payManual == true, compact: true) }
            else if !m.active { Text(L("停用于 \(String(TimeText.date(m.deactivatedAt).dropFirst(5)))")).font(.caption).foregroundStyle(.secondary) }
        }
        .font(.callout)
        .contextMenu { Button("复制邮箱") { copyToPasteboard(m.email) } }
    }
}

/// 下次交费日：今天 / 3 天内标橙红，手动改过的带「手动」
struct PayText: View {
    let epoch: Double
    let now: Double
    var manual = false
    var compact = false
    var dateOnly = false        // 只写日期（概览的待交费卡片：窄，颜色已经说明远近）
    @Environment(\.backgroundProminence) private var prominence

    static func daysAway(_ epoch: Double, now: Double) -> Int {
        let cal = Calendar.current
        return cal.dateComponents([.day], from: cal.startOfDay(for: Date(timeIntervalSince1970: now)),
                                  to: cal.startOfDay(for: Date(timeIntervalSince1970: epoch))).day ?? 0
    }

    var body: some View {
        let d = PayText.daysAway(epoch, now: now)
        let color: Color = prominence == .increased ? .white : (d <= 0 ? Palette.red : d <= 3 ? Palette.orange : Palette.text)
        let when = d < 0 ? L("逾期 \(-d) 天") : d == 0 ? L("今天") : d == 1 ? L("明天") : L("\(d) 天后")
        let sub: Color = prominence == .increased ? .white.opacity(0.8) : (d <= 3 ? color : .secondary)
        Group {
            if dateOnly {
                Text(TimeText.date(epoch).dropFirst(5)).monospacedDigit().lineLimit(1)
            } else if compact {
                // 团队面板里靠右的两行
                VStack(alignment: .trailing, spacing: 1) {
                    Text(TimeText.date(epoch).dropFirst(5)).monospacedDigit()
                    Text(when).font(.caption).foregroundStyle(sub)
                }
            } else {
                // 表格里一行写完：两行的格子会比同一行别的列偏上，看着没对齐；字重也不变，免得宽窄不一
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(TimeText.date(epoch).dropFirst(5)).monospacedDigit()
                    Text(when).font(.caption).foregroundStyle(sub)
                    if manual { Text("手动").font(.caption2).foregroundStyle(.secondary) }
                }
                .lineLimit(1)
            }
        }
        .foregroundStyle(color)
        .help((d < 0 ? L("过了应交日还没标记已交；标记后顺延到下个月。") : "")
              + (manual ? L("手动设置的交费日，之后每月同一天") : L("按加入日期每月同一天推算")))
    }
}

// MARK: - 成员页：所有团队成员的交费台账

struct MemberRow: Identifiable {
    let m: Member
    let w: Workspace
    var id: String { w.id + "|" + m.email.lowercased() }
    var email: String { m.email }
    var wechat: String { m.wechat ?? "" }
    var owner: String { w.ownerEmail }
    var team: String { w.displayName }
    var joined: Double { m.joined }
    var nextPay: Double { m.nextPay ?? .infinity }
    var state: Int { m.active ? 0 : 1 }
}

struct MembersPage: View {
    @ObservedObject var store: Store
    @State private var order = [KeyPathComparator(\MemberRow.nextPay)]
    @State private var query = ""
    @State private var range = "members"
    @State private var selection = Set<String>()

    private var rows: [MemberRow] {
        let mine = store.myEmails
        let today = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: store.now)).timeIntervalSince1970
        var r = store.memberRows
        switch range {
        case "due":   r = r.filter { $0.m.active && $0.nextPay <= today + 3 * 86400 }   // 含逾期
        case "new":   r = r.filter { $0.m.active && !$0.m.isOwner && store.now - $0.joined <= 3 * 86400 }
        case "left":  r = r.filter { !$0.m.active }
        case "all":   break
        default:      r = r.filter { $0.m.active && !$0.m.isOwner && !mine.contains($0.email.lowercased()) }
        }
        if !query.isEmpty {
            r = r.filter { $0.email.localizedCaseInsensitiveContains(query) || $0.wechat.localizedCaseInsensitiveContains(query)
                || $0.team.localizedCaseInsensitiveContains(query) || $0.owner.localizedCaseInsensitiveContains(query) }
        }
        return r.sorted(using: order)
    }

    var body: some View {
        let shown = rows
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("", selection: $range) {
                    Text("成员").tag("members")
                    Text("待交费 \(store.duePayments(days: 3).count)").tag("due")
                    Text("近 3 天加入").tag("new")
                    Text("已停用").tag("left")
                    Text("全部（含所有者）").tag("all")
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                Text("双击一行改微信名 / 交费日；收到钱点「标记已交」").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Table(shown, selection: $selection, sortOrder: $order) {
                TableColumn("成员邮箱", value: \.email) { r in
                    HStack(spacing: 5) {
                        Text(r.email).lineLimit(1)
                        if r.m.active && store.now - r.joined <= 3 * 86400 && !r.m.isOwner { Pill(text: L("新"), color: Palette.green) }
                        if r.m.isOwner { Pill(text: L("所有者"), color: Palette.accent) }
                    }
                    .padding(.vertical, 10)        // 行高和账号页差不多，不挤
                }
                .width(min: 170, ideal: 220)
                TableColumn("微信名", value: \.wechat) { r in
                    Text(r.wechat.isEmpty ? L("未填") : r.wechat).foregroundStyle(r.wechat.isEmpty ? .tertiary : .primary)
                }
                .width(min: 80, ideal: 110)
                TableColumn("所有者邮箱", value: \.owner) { r in Text(r.owner).lineLimit(1).foregroundStyle(.secondary) }
                    .width(min: 140, ideal: 180)
                TableColumn(L("团队#列", zh: "团队"), value: \.team) { r in Text(r.team).lineLimit(1) }
                    .width(min: 80, ideal: 120)
                TableColumn("加入时间", value: \.joined) { r in Text(TimeText.date(r.joined)).monospacedDigit() }
                    .width(min: 86, ideal: 96)
                TableColumn("下次交费", value: \.nextPay) { r in
                    if r.m.active, let p = r.m.nextPay { PayText(epoch: p, now: store.now, manual: r.m.payManual == true) }
                    else { Text("—").foregroundStyle(.tertiary) }
                }
                .width(min: 120, ideal: 140)
                TableColumn("交费") { r in PaidCell(store: store, r: r) }
                    .width(min: 96, ideal: 110)
                TableColumn("状态", value: \.state) { r in
                    r.m.active ? StatusChip(text: L("在职"), color: Palette.green)
                               : StatusChip(text: L("停用 \(String(TimeText.date(r.m.deactivatedAt).dropFirst(5)))"), color: Palette.gray)
                }
                .width(min: 60, ideal: AppLanguage.active == "en" ? 120 : 84)   // 英文「Deactivated 10-03」更宽
            }
            .alternatingRowBackgrounds(.disabled)   // 不要斑马纹：和概览、设置一样透出页面底色
            .scrollContentBackground(.hidden)
            .contextMenu(forSelectionType: String.self) { ids in
                if ids.count == 1, let r = shown.first(where: { ids.contains($0.id) }) {
                    Button("编辑微信名 / 交费日…") { store.editingMember = r }
                    if r.m.active, r.m.nextPay != nil {
                        Button("标记 \(TimeText.date(r.nextPay).dropFirst(5)) 这期已交") { store.markPaid(r) }
                        if r.m.paidMarked == true { Button("撤销上一次已交标记") { store.markPaid(r, undo: true) } }
                    }
                    Divider()
                }
                Button("复制邮箱") {
                    copyToPasteboard(shown.filter { ids.contains($0.id) }.map(\.email).joined(separator: "\n"))
                }
            } primaryAction: { ids in
                if let r = shown.first(where: { ids.contains($0.id) }) { store.editingMember = r }
            }
        }
        .navigationTitle("成员")
        .navigationSubtitle("\(shown.count) 人 · 交费日默认按加入日期每月同一天，可手动改")
        .pageToolbar(search: $query, prompt: L("搜索邮箱 / 微信名 / 团队")) {
            Button {
                copyToPasteboard(shown.map(\.email).joined(separator: "\n"))
                store.say(L("已复制 \(shown.count) 个邮箱"))
            } label: { Label("复制邮箱", systemImage: "doc.on.doc") }
            Button {
                let data = shown.map { [$0.email, $0.wechat, $0.owner, $0.team, TimeText.date($0.joined),
                                        TimeText.date($0.m.nextPay ?? 0), $0.m.active ? L("在职") : L("已停用")] }
                if let url = exportCSV(name: L("成员台账.csv"),
                                       header: [L("成员邮箱"), L("微信名"), L("所有者邮箱"), L("团队#列", zh: "团队"), L("加入时间"), L("下次交费"), L("状态")], rows: data) {
                    store.say(L("已导出到 \(url.lastPathComponent)"))
                }
            } label: { Label("导出 CSV", systemImage: "square.and.arrow.up") }
            Button { store.loadDirectory(refresh: true) } label: { Label("同步", systemImage: "arrow.triangle.2.circlepath") }
                .disabled(store.syncing)
        }
    }
}

/// 成员表「交费」列：快到期 / 逾期的给「标记已交」按钮，标记过的显示已交到哪期
struct PaidCell: View {
    @ObservedObject var store: Store
    let r: MemberRow
    @Environment(\.backgroundProminence) private var prominence
    var body: some View {
        if r.m.active, r.m.nextPay != nil {
            if PayText.daysAway(r.nextPay, now: store.now) <= 7 {
                Button("标记已交") { store.markPaid(r) }
                    .glassButton().controlSize(.small)
                    .help("这期 \(TimeText.date(r.nextPay)) 的钱收到了：下次交费顺延一个月")
            } else if r.m.paidMarked == true, let p = r.m.paidThrough {
                Label("已交 \(TimeText.date(p).dropFirst(5))", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(prominence == .increased ? .white : Palette.green)
                    .help("已交到 \(TimeText.date(p)) 那期；右键可撤销")
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }
}

/// 改微信名和交费日
struct MemberEditSheet: View {
    @ObservedObject var store: Store
    let row: MemberRow
    @State private var wechat = ""
    @State private var manual = false      // 交费日是手动定的（否则按加入日每月推算）
    @State private var touched = false     // 这次改过交费日
    @State private var date = Date()
    @State private var showCal = false     // 点日期才展开日历

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.email).font(.headline)
                Text("\(row.team) · 所有者 \(row.owner) · \(TimeText.date(row.joined)) 加入").font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("微信名").font(.subheadline.weight(.semibold))
                TextField("", text: $wechat, prompt: Text("例如 张三")).textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("下次交费").font(.subheadline.weight(.semibold))
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { showCal.toggle() }
                    } label: {
                        HStack(spacing: 6) {
                            Text(TimeText.date(date.timeIntervalSince1970)).monospacedDigit()
                            Image(systemName: showCal ? "chevron.up" : "calendar").font(.caption)
                        }
                    }
                    .help("点开日历改交费日")
                    if !touched, let n = row.m.nextPay { PayText(epoch: n, now: store.now).fixedSize() }
                    Spacer()
                    if manual {
                        Button("恢复按加入日推算") { manual = false; touched = true; date = autoDate }
                            .buttonStyle(.link)
                    }
                }
                if showCal {
                    // 点日历上的某天就改成手动交费日；以后每月同一天，标记已交后顺延
                    DatePicker("", selection: pick, displayedComponents: .date)
                        .datePickerStyle(.graphical).labelsHidden()
                        .frame(maxWidth: .infinity)
                        .transition(.opacity)
                }
                Text(manual ? "手动：每月 \(day(date)) 号交费；收到钱后标记已交，才顺延到下个月"
                            : "按加入日期每月 \(day(Date(timeIntervalSince1970: row.joined))) 号；收到钱后标记已交，才顺延到下个月")
                    .font(.caption).foregroundStyle(.secondary)
                if !touched, row.m.nextPay != nil {
                    HStack(spacing: 10) {
                        Button {
                            store.markPaid(row); store.editingMember = nil
                        } label: { Label("标记 \(TimeText.date(row.nextPay).dropFirst(5)) 这期已交", systemImage: "checkmark.circle") }
                        .glassButton()
                        if row.m.paidMarked == true, let p = row.m.paidThrough {
                            Text("已交到 \(TimeText.date(p).dropFirst(5))").font(.caption).foregroundStyle(Palette.green)
                            Button("撤销") { store.markPaid(row, undo: true); store.editingMember = nil }.buttonStyle(.link)
                        }
                    }
                }
            }
            HStack {
                Spacer()
                Button("取消") { store.editingMember = nil }.keyboardShortcut(.cancelAction)
                Button("保存") { save() }.keyboardShortcut(.defaultAction).glassProminentButton()
            }
        }
        .padding(20).frame(width: 400)
        .onAppear {
            wechat = row.wechat.isEmpty ? store.wechat(row.email) : row.wechat
            manual = row.m.payManual == true
            date = row.m.nextPay.map { Date(timeIntervalSince1970: $0) } ?? autoDate
        }
    }

    /// 输入框和日历共用：改了就算手动交费日
    private var pick: Binding<Date> {
        Binding(get: { date }, set: { date = $0; manual = true; touched = true })
    }

    private func day(_ d: Date) -> Int { Calendar.current.component(.day, from: d) }

    /// 按加入日推算的下次交费日：加入日往后第一个「≥ 今天」的同日（和 engine.next_pay 一致）
    private var autoDate: Date {
        let cal = Calendar.current
        let joined = Date(timeIntervalSince1970: row.joined), today = cal.startOfDay(for: Date())
        var k = 1
        while let d = cal.date(byAdding: .month, value: k, to: joined), cal.startOfDay(for: d) < today { k += 1 }
        return cal.date(byAdding: .month, value: k, to: joined) ?? today
    }

    private func save() {
        let w = wechat.trimmingCharacters(in: .whitespaces)
        if w != store.wechat(row.email) { store.setWechat(row.email, w) }
        if touched { store.setPay(row.w.id, row.email, manual ? date : nil) }
        store.editingMember = nil
        store.say(L("已保存 \(row.email)"))
    }
}
