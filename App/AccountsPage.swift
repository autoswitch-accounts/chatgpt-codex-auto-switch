import SwiftUI
import AppKit

// MARK: - 账号页：表格 + 右侧详情

/// 表格一行：槽位 + 它所在空间的订阅 + 邮箱的资料，排序键都在这里
struct AccountRow: Identifiable {
    let s: Slot
    let ws: Workspace?
    let person: Person?
    let now: Double
    var id: String { s.slot }

    var letter: String { s.slot }
    var email: String { s.email }
    var space: String { ws?.displayName ?? s.title }
    /// 套餐名：去掉「ChatGPT」前缀、按量计费的缩短，套餐列很窄，长名字会压到旁边的额度列
    var plan: String {
        guard let n = ws?.planName, !n.isEmpty else { return s.planLabel }
        return n.replacingOccurrences(of: "ChatGPT ", with: "")
            .replacingOccurrences(of: "Business Usage Based", with: "Business 按量")
    }
    var r5h: Double { s.remaining5h(now) }
    var rWeek: Double { s.remainingWeek(now) }
    var reset5h: Double { s.usage.primary?.resetAt ?? .infinity }
    var resetWeek: Double { s.usage.secondary?.resetAt ?? .infinity }
    var renew: Double { let t = ws?.sub.nextDate ?? 0; return t > 0 ? t : .infinity }
    var resets: Int { person?.availableResets.count ?? s.usage.resets }
    /// 状态排序：使用中 < 可用 < 未知 < 已用完 < 需登录
    var statusRank: Int {
        if s.current { return 0 }
        if s.needsLogin { return 4 }
        if s.exhaustedUntil(now) != nil { return 3 }
        return s.usage.availableAt == 0 ? 1 : 2
    }
}

struct AccountsPage: View {
    @ObservedObject var store: Store
    @State private var selection: String? = nil
    @State private var order = [KeyPathComparator(\AccountRow.letter)]
    @State private var query = ""
    @State private var filter = "all"

    private var rows: [AccountRow] {
        var r = store.slots.map { AccountRow(s: $0, ws: store.workspace(of: $0), person: store.person(of: $0), now: store.now) }
        switch filter {
        case "usable": r = r.filter { $0.s.usable(store.now) }
        case "out":    r = r.filter { !$0.s.usable(store.now) }
        case "renew":  r = r.filter { $0.renew - store.now <= 7 * 86400 }
        default: break
        }
        if !query.isEmpty {
            r = r.filter { $0.email.localizedCaseInsensitiveContains(query) || $0.space.localizedCaseInsensitiveContains(query)
                || ($0.s.wechat ?? "").localizedCaseInsensitiveContains(query)
                || $0.letter.caseInsensitiveCompare(query) == .orderedSame }
        }
        return r.sorted(using: order)
    }
    // 有账号设成「不参与自动轮换」时，表格分两组显示
    private var rotationRows: [AccountRow] { rows.filter { !store.skipped($0.s) } }
    private var skippedRows: [AccountRow] { rows.filter { store.skipped($0.s) } }

    var body: some View {
        VStack(spacing: 0) {
            filterBar
            table
        }
        // 详情是盖在表格上的玻璃面板，不用 inspector：inspector 会把表格列挤成「…」
        .overlay(alignment: .trailing) {
            if let id = selection, let s = store.slots.first(where: { $0.slot == id }) {
                FloatingPanel(onClose: { selection = nil }) { AccountInspector(store: store, s: s) }
            }
        }
        .animation(.snappy(duration: 0.28), value: selection)
        .navigationTitle("账号")
        .navigationSubtitle(subtitle)
        .pageToolbar(search: $query, prompt: "搜索邮箱 / 空间 / 微信名") {
            Button { store.refreshUsage() } label: { Label("刷新额度", systemImage: "arrow.clockwise") }
                .disabled(store.refreshing)
                .help("联网刷新全部账号的额度")
            Button { store.beginAdd(); store.adding = true } label: { Label("添加账号", systemImage: "plus") }
                .help("添加账号 / workspace")
        }
        .onAppear { if let f = store.focus, store.slots.contains(where: { $0.slot == f }) { selection = f; store.focus = nil } }
    }

    private var subtitle: String {
        let ok = store.slots.filter { $0.usable(store.now) }.count
        var t = "\(store.slots.count) 个账号 · \(ok) 个可用"
        if store.refreshing { t += " · 正在刷新额度…" }
        else if let at = store.slots.map(\.usage.at).max(), at > 0 { t += " · 额度数据 " + TimeText.ago(at, now: store.now) }
        return t
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            Picker("", selection: $filter) {
                Text("全部").tag("all")
                Text("可用").tag("usable")
                Text("不可用").tag("out")
                Text("7 天内续费").tag("renew")
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            Spacer()
            // 这一栏不要放会出现 / 消失的东西（转圈、变长的文字）：曾和 inspector、表格一起
            // 让 AppKit 反复重排约束直到崩溃。刷新状态放在窗口副标题里
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var table: some View {
        Table(of: AccountRow.self, selection: $selection, sortOrder: $order) {
            TableColumn("账号", value: \.letter) { r in
                HStack(spacing: 9) {
                    Avatar(letter: r.s.slot, size: 26)
                        .overlay {   // 正在运行的账号：头像外一圈绿环
                            if r.s.current { Circle().strokeBorder(Palette.green, lineWidth: 2).padding(-3) }
                        }
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(r.s.email).fontWeight(r.s.current ? .semibold : .regular).lineLimit(1)
                            if r.s.current { Pill(text: "运行中", color: Palette.green) }
                        }
                        // 「不轮换」放在小字行里：放邮箱旁边会把邮箱挤成「…」
                        Text(["槽 \(r.s.slot)", r.s.name, (r.s.wechat ?? "").isEmpty ? "" : "微信 \(r.s.wechat!)",
                              store.skipped(r.s) ? "不轮换" : ""]
                                .filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            .help(store.skipped(r.s) ? "不参与自动轮换：撞限切号时不会切到这个账号" : "")
                    }
                }
                .padding(.vertical, 3)
            }
            .width(min: 200, ideal: 220)
            TableColumn("空间", value: \.space) { r in
                Text(r.space).lineLimit(1).foregroundStyle(r.ws?.isTeam == true ? Palette.text : Palette.text2)
            }
            .width(min: 80, ideal: 120)
            TableColumn("套餐", value: \.plan) { r in
                Pill(text: r.plan, color: r.ws?.isTeam == true || r.s.plan == "team" ? Palette.purple
                     : (r.s.plan == "plus" || r.s.plan == "pro" ? Palette.teal : Palette.gray))
                    .frame(maxWidth: .infinity, alignment: .leading).clipped()
            }
            .width(min: 70, ideal: 80)
            TableColumn("5 小时", value: \.r5h) { r in QuotaCell(window: r.s.usage.primary, now: store.now) }
                .width(min: 96, ideal: 104)
            TableColumn("5h 重置", value: \.reset5h) { r in
                if let w = r.s.usage.primary, w.untouched, w.resetAt > store.now, !r.s.needsLogin {
                    Button("开始计时") { store.confirmStart = r.s }
                        .glassButton().controlSize(.small)
                        .disabled(store.busy != nil)
                        .help("让这个账号的 5 小时窗口从现在开始计时")
                } else {
                    Text(resetText(r.s.usage.primary, now: store.now)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .width(min: 80, ideal: 90)
            TableColumn("本周", value: \.rWeek) { r in QuotaCell(window: r.s.usage.secondary, now: store.now) }
                .width(min: 96, ideal: 104)
            TableColumn("周重置", value: \.resetWeek) { r in
                Text(resetText(r.s.usage.secondary, now: store.now)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(min: 80, ideal: 92)
            TableColumn("续费 / 到期", value: \.renew) { r in RenewCell(ws: r.ws, now: store.now) }
                .width(min: 90, ideal: 104)
            TableColumn("重置券", value: \.resets) { r in
                if r.resets > 0, let c = r.person?.availableResets.min(by: { $0.expiresAt < $1.expiresAt }) {
                    Button { store.confirmReset = ResetAsk(slot: r.s, credit: c) } label: {
                        Label("\(r.resets) 张", systemImage: "arrow.counterclockwise").monospacedDigit()
                    }
                    .glassButton().controlSize(.small)
                    .disabled(store.busy != nil)
                    .help("用一张重置券，立即清空这个账号的 5 小时和本周用量")
                } else {
                    Text("—").foregroundStyle(Palette.text3)
                }
            }
            .width(min: 80, ideal: 88)
            TableColumn("状态", value: \.statusRank) { r in SlotStatus(s: r.s, busy: store.busy == r.s.slot, now: store.now) }
                .width(min: 80, ideal: 96)
        } rows: {
            let skipped = skippedRows
            if skipped.isEmpty {
                ForEach(rows) { TableRow($0) }
            } else {
                Section {
                    ForEach(rotationRows) { TableRow($0) }
                } header: {
                    Text("参与轮换 · \(rotationRows.count)")
                }
                Section {
                    ForEach(skipped) { TableRow($0) }
                } header: {
                    Text("不参与轮换 · \(skipped.count)　撞限自动切号时跳过，手动切换照常可用")
                }
            }
        }
        .alternatingRowBackgrounds(.disabled)   // 不要斑马纹：和概览、设置一样透出页面底色
        .scrollContentBackground(.hidden)
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let s = store.slots.first(where: { $0.slot == id }) {
                Button(s.current ? "重启 ChatGPT…" : "切换到这个账号…") { store.confirmSwitch = s }
                Button("刷新额度") { store.refreshUsage(s.slot) }
                if let c = store.person(of: s)?.availableResets.min(by: { $0.expiresAt < $1.expiresAt }) {
                    Button("用重置券清空额度…") { store.confirmReset = ResetAsk(slot: s, credit: c) }
                }
                if let w = s.usage.primary, w.untouched, w.resetAt > store.now {
                    Button("让 5 小时额度开始计时…") { store.confirmStart = s }
                }
                Button(store.skipped(s) ? "恢复参与自动轮换" : "不参与自动轮换") { store.setSkipped(s, !store.skipped(s)) }
                Button("复制邮箱") { copyToPasteboard(s.email) }
                Button("重命名…") { store.renaming = s }
                Divider()
                Button("删除…", role: .destructive) { store.deleting = s }
            }
        } primaryAction: { ids in
            if let id = ids.first, let s = store.slots.first(where: { $0.slot == id }) { store.confirmSwitch = s }
        }
    }
}

/// 续费 / 到期单元格：3 天内标橙，已关自动续费标红
struct RenewCell: View {
    let ws: Workspace?
    let now: Double
    var body: some View {
        if let s = ws?.sub, s.nextDate > 0 {
            let d = TimeText.daysLeft(s.nextDate, now: now)
            let warn = d <= 3
            let stop = s.nextLabel == "到期"
            HStack(spacing: 4) {
                Text(TimeText.date(s.nextDate).dropFirst(5)).monospacedDigit()
                Text(stop ? "到期" : "续费").font(.caption)
                    .foregroundStyle(stop ? Palette.red : .secondary)
            }
            .foregroundStyle(warn ? Palette.orange : Palette.text)
            .help("\(stop ? "到期" : "自动续费")：\(TimeText.date(s.nextDate))（\(d) 天后）")
        } else if let w = ws, !w.sub.active {
            Text(w.plan == "free" ? "免费版" : "未订阅").foregroundStyle(.tertiary)
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }
}

/// 账号状态（使用中 / 可用 / 已用完 … 恢复）
struct SlotStatus: View {
    let s: Slot
    let busy: Bool
    let now: Double
    var body: some View {
        if busy {
            HStack(spacing: 4) { Spinner(); Text("切换中").font(.caption) }
        } else if s.needsLogin {
            StatusChip(text: "需重新登录", color: Palette.red)
        } else if let until = s.exhaustedUntil(now) {
            StatusChip(text: s.creditsOnly(now) ? "空间无额度" : "\(TimeText.short(until)) 恢复", color: Palette.red)
                .help(!s.usage.blockReason.isEmpty ? s.usage.blockReason
                      : s.creditsOnly(now) ? "空间的 credits 用完了（5 小时和本周额度都没满），要等空间所有者充值"
                      : s.usage.limitType == "workspace_owner_credits_depleted" ? "额度用完，空间也没有 credits 可以超额续用；到点恢复"
                      : "额度已用完，到点恢复")
        } else if s.current {
            StatusChip(text: "使用中", color: Palette.accent)
        } else if s.usage.availableAt == 0 {
            StatusChip(text: "可用", color: Palette.green)
        } else {
            StatusChip(text: "未知", color: Palette.gray)
        }
    }
}

// MARK: - 账号详情面板

struct AccountInspector: View {
    @ObservedObject var store: Store
    let s: Slot
    @State private var editingWechat = false
    @State private var wechatDraft = ""

    var body: some View {
        let ws = store.workspace(of: s)
        let p = store.person(of: s)
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // 头部
                HStack(spacing: 12) {
                    Avatar(letter: s.slot, size: 44)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(s.email).font(.headline).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                            .padding(.trailing, 30)
                        HStack(spacing: 5) {
                            Pill(text: ws?.planName.isEmpty == false ? ws!.planName : s.planLabel, color: Palette.purple)
                            Text(ws?.displayName ?? s.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                }
                HStack(spacing: 8) {
                    Button(s.current ? "重启 ChatGPT" : "切换到此账号") { store.confirmSwitch = s }
                        .glassProminentButton().controlSize(.large)
                        .disabled(store.busy != nil)
                    Button("刷新额度") { store.refreshUsage(s.slot) }
                        .glassButton().controlSize(.large)
                    Menu {
                        Button("复制邮箱") { copyToPasteboard(s.email) }
                        Button("复制空间 ID") { copyToPasteboard(s.acct) }
                        Button("重命名…") { store.renaming = s }
                        Divider()
                        Button("删除…", role: .destructive) { store.deleting = s }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).fixedSize()
                }
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("不参与自动轮换")
                        Text("打开后，撞限自动切号时跳过这个账号；手动切过去照常能用")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Toggle("", isOn: Binding(get: { store.skipped(s) }, set: { store.setSkipped(s, $0) }))
                        .toggleStyle(SwitchStyle()).labelsHidden()
                }

                group("额度") {
                    BigQuota(label: "5 小时额度", window: s.usage.primary, now: store.now)
                    if let w = s.usage.primary, w.untouched, w.resetAt > store.now, !s.needsLogin {
                        Button { store.confirmStart = s } label: { Label("让 5 小时额度开始计时", systemImage: "timer") }
                            .glassButton().disabled(store.busy != nil)
                    }
                    BigQuota(label: "本周额度", window: s.usage.secondary, now: store.now)
                    if !s.usage.limitType.isEmpty {
                        InfoRow("撞限类型", s.creditsOnly(store.now) ? "空间 credits 用完（不是 5 小时限额）"
                                : s.usage.limitType == "workspace_owner_credits_depleted" ? "5 小时 / 每周额度用完，空间也没有 credits 续用"
                                : "5 小时 / 每周额度用完")
                    }
                    if !s.usage.blockReason.isEmpty { InfoRow("暂时跳过", s.usage.blockReason) }
                    if !s.usage.error.isEmpty { InfoRow("最近查询", s.usage.error) }
                    InfoRow("数据时间", s.usage.at > 0 ? TimeText.short(s.usage.at) + "（" + TimeText.ago(s.usage.at, now: store.now) + "）" : "—")
                }

                if let ws {
                    group("订阅") {
                        let sub = ws.sub
                        InfoRow(key: "状态") {
                            if sub.delinquent { StatusChip(text: "欠费", color: Palette.red) }
                            else if sub.active { StatusChip(text: sub.cancelsAt > 0 || !sub.willRenew ? "已关闭自动续费" : "自动续费中",
                                                            color: sub.cancelsAt > 0 || !sub.willRenew ? Palette.orange : Palette.green) }
                            else { StatusChip(text: ws.plan == "free" ? "免费版" : "未订阅", color: Palette.gray) }
                        }
                        if sub.nextDate > 0 {
                            InfoRow("下次\(sub.nextLabel)", "\(TimeText.date(sub.nextDate))（\(TimeText.daysLeft(sub.nextDate, now: store.now)) 天后）")
                        }
                        if sub.expiresAt > 0 && sub.expiresAt != sub.nextDate { InfoRow("有效期至", TimeText.date(sub.expiresAt)) }
                        if !sub.billing.isEmpty { InfoRow("计费", [sub.billingText, sub.currency, sub.platformText].filter { !$0.isEmpty }.joined(separator: " · ")) }
                        if sub.seatsTotal > 0 { InfoRow("席位", "\(sub.seatsUsed) / \(sub.seatsTotal)") }
                        if !sub.discount.isEmpty { InfoRow("优惠", sub.discount) }
                        if sub.activeStart > 0 { InfoRow("开通于", TimeText.date(sub.activeStart)) }
                    }
                    group("空间") {
                        InfoRow("名称", ws.displayName)
                        InfoRow("我的角色", ws.myRole)
                        InfoRow("创建于", TimeText.date(ws.created))
                        if let m = ws.members {
                            let n = ws.newMembers(now: store.now).count
                            InfoRow("成员", "\(ws.activeMembers.count) 人" + (n > 0 ? "，近 3 天新加入 \(n) 人" : "") + (m.count > ws.activeMembers.count ? "，\(m.count - ws.activeMembers.count) 人已停用" : ""))
                        }
                        InfoRow(key: "空间 ID") { Text(ws.id).font(.caption.monospaced()) }
                    }
                }

                group("微信") {
                    if editingWechat {
                        HStack {
                            TextField("微信名", text: $wechatDraft).textFieldStyle(.roundedBorder)
                                .onSubmit { saveWechat() }
                            Button("保存") { saveWechat() }.glassProminentButton()
                        }
                    } else {
                        let w = store.wechat(s.email)
                        HStack {
                            Text(w.isEmpty ? "未填写" : w).foregroundStyle(w.isEmpty ? .tertiary : .primary)
                            Spacer()
                            Button(w.isEmpty ? "填写" : "修改") { wechatDraft = w; editingWechat = true }.glassButton().controlSize(.small)
                        }
                        .font(.callout)
                    }
                }

                if let p {
                    group("用户") {
                        if !p.name.isEmpty { InfoRow("姓名", p.name) }
                        InfoRow("注册于", TimeText.date(p.created))
                        InfoRow("两步验证", p.mfa ? "已开启" : "未开启")
                        if !p.country.isEmpty { InfoRow("地区", p.country) }
                        InfoRow("同邮箱槽位", p.slots.joined(separator: "、"))
                    }
                    if !p.resetCredits.isEmpty {
                        group("额度重置券") {
                            ForEach(p.resetCredits.sorted { $0.expiresAt < $1.expiresAt }) { c in
                                HStack {
                                    Image(systemName: c.status == "available" ? "ticket" : "ticket.fill")
                                        .foregroundStyle(c.status == "available" ? Palette.accent : Palette.text3)
                                    Text(c.title.isEmpty ? "额度重置" : c.title).lineLimit(1)
                                    Spacer()
                                    let d = TimeText.daysLeft(c.expiresAt, now: store.now)
                                    Text(c.status == "available" ? "\(TimeText.date(c.expiresAt).dropFirst(5)) 过期" : "已使用")
                                        .monospacedDigit()
                                        .foregroundStyle(c.status == "available" && d <= 3 ? Palette.orange : Palette.text2)
                                    if c.status == "available" {
                                        Button("使用") { store.confirmReset = ResetAsk(slot: s, credit: c) }
                                            .glassButton().controlSize(.small)
                                            .disabled(store.busy != nil)
                                    }
                                }
                                .font(.callout)
                            }
                            Text("同一邮箱的券通用，用一张立即清空这个账号的 5 小时和本周用量")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                group("本机凭证") {
                    InfoRow("槽位", s.slot)
                    InfoRow("凭证", s.needsLogin ? "已失效，需要重新登录" : (s.ok ? "有效" : "异常"))
                    if !s.lastExit.isEmpty { InfoRow("上次切走", s.lastExit) }
                }
            }
            .padding(20)
        }
        .onChange(of: s.slot) { _, _ in editingWechat = false }
    }

    private func saveWechat() {
        store.setWechat(s.email, wechatDraft.trimmingCharacters(in: .whitespaces))
        editingWechat = false
    }

    private func group<C: View>(_ title: String, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            c()
        }
    }
}

// MARK: - 重置券清单（概览点「额度重置券」打开）

struct ResetSheet: View {
    @ObservedObject var store: Store

    private struct Line: Identifiable {
        let s: Slot; let credit: ResetCredit; let count: Int
        var id: String { s.slot }
    }

    var body: some View {
        // 有券的账号，额度最紧的排前面；同一邮箱的券通用，每个槽位都列出来
        let rows = store.slots.compactMap { s -> Line? in
            guard let p = store.person(of: s), let c = p.availableResets.min(by: { $0.expiresAt < $1.expiresAt }) else { return nil }
            return Line(s: s, credit: c, count: p.availableResets.count)
        }
        .sorted { min($0.s.remaining5h(store.now), $0.s.remainingWeek(store.now)) < min($1.s.remaining5h(store.now), $1.s.remainingWeek(store.now)) }
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("额度重置券").font(.title2.weight(.semibold))
                    Text("用一张立即清空该账号的 5 小时和本周用量；同一邮箱下的槽位共用券。点「重置」后还会再确认一次。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Text("共 \(store.directory.people.flatMap(\.availableResets).count) 张").font(.headline).foregroundStyle(Palette.teal)
            }
            // 表头和每行用同一套固定列宽，竖向对齐
            HStack(spacing: 0) {
                Text("账号").frame(maxWidth: .infinity, alignment: .leading)
                Text("5 小时").frame(width: Col.quota, alignment: .leading)
                Text("本周").frame(width: Col.quota, alignment: .leading)
                Text("券").frame(width: Col.count, alignment: .trailing)
                Text("最早过期").frame(width: Col.expiry, alignment: .trailing)
                Color.clear.frame(width: Col.button, height: 1)   // 不给高度的话 Color 会把表头撑高
            }
            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(rows) { r in
                        HStack(spacing: 0) {
                            HStack(spacing: 10) {
                                Avatar(letter: r.s.slot, size: 28)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(r.s.email).font(.callout.weight(.medium)).lineLimit(1)
                                    Text(store.workspace(of: r.s)?.displayName ?? r.s.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            QuotaCell(window: r.s.usage.primary, now: store.now).frame(width: Col.quota, alignment: .leading)
                            QuotaCell(window: r.s.usage.secondary, now: store.now).frame(width: Col.quota, alignment: .leading)
                            Text("\(r.count) 张").monospacedDigit().frame(width: Col.count, alignment: .trailing)
                            Text(TimeText.short(r.credit.expiresAt)).monospacedDigit()
                                .foregroundStyle(TimeText.daysLeft(r.credit.expiresAt, now: store.now) <= 3 ? Palette.orange : Palette.text)
                                .frame(width: Col.expiry, alignment: .trailing)
                            HStack {
                                Spacer()
                                Button("重置") { store.showResets = false; store.confirmReset = ResetAsk(slot: r.s, credit: r.credit) }
                                    .glassButton().disabled(store.busy != nil)
                            }
                            .frame(width: Col.button)
                        }
                        .font(.callout)
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Palette.fill.opacity(0.55)))
                    }
                    if rows.isEmpty { EmptyHint(icon: "ticket", text: "没有可用的重置券") }
                }
            }
            .scrollIndicators(.never)
            HStack { Spacer(); Button("关闭") { store.showResets = false }.keyboardShortcut(.cancelAction).controlSize(.large) }
        }
        .padding(24).frame(width: 860, height: 620)
    }

    private enum Col {
        static let quota: CGFloat = 112
        static let count: CGFloat = 50
        static let expiry: CGFloat = 112
        static let button: CGFloat = 90
    }
}
