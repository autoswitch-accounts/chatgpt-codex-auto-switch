import SwiftUI

// MARK: - 消息中心

enum NoticeLook {
    static func icon(_ n: Notice) -> String {
        switch n.kind {
        case "billing": return n.level == "critical" ? "exclamationmark.creditcard" : "creditcard"
        case "member":  return "person.badge.plus"
        case "quota":   return "ticket"
        case "pay":     return "yensign.circle"
        case "switch":  return "arrow.triangle.2.circlepath"
        case "session": return "bubble.left.and.exclamationmark.bubble.right"
        default:        return "bell"
        }
    }
    static func kindText(_ k: String) -> String {
        switch k {
        case "billing": return L("续费#类别", zh: "续费")
        case "member":  return L("成员")
        case "quota":   return L("额度")
        case "pay":     return L("交费")
        case "switch":  return L("切号")
        case "session": return L("会话")
        default:        return L("系统")
        }
    }
}

struct MessagesPage: View {
    @ObservedObject var store: Store
    @State private var filter = "all"
    @State private var query = ""

    private var items: [Notice] {
        var l = store.notices
        switch filter {
        case "unread": l = l.filter { !$0.read }
        case "all": break
        default: l = l.filter { $0.kind == filter || (filter == "switch" && $0.kind == "session") }
        }
        if !query.isEmpty { l = l.filter { $0.title.localizedCaseInsensitiveContains(query) || $0.body.localizedCaseInsensitiveContains(query) } }
        return l
    }

    /// 按收到的日期分组：今天 / 昨天 / 更早
    private var groups: [(String, [Notice])] {
        let cal = Calendar.current
        var out: [(String, [Notice])] = []
        for n in items {
            let d = Date(timeIntervalSince1970: n.created)
            let key = cal.isDateInToday(d) ? L("今天") : cal.isDateInYesterday(d) ? L("昨天") : TimeText.date(n.created)
            if out.last?.0 == key { out[out.count - 1].1.append(n) } else { out.append((key, [n])) }
        }
        return out
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("", selection: $filter) {
                    Text("全部").tag("all")
                    Text("未读 \(store.unread)").tag("unread")
                    Text(L("续费#类别", zh: "续费")).tag("billing")
                    Text("交费").tag("pay")
                    Text("成员").tag("member")
                    Text("额度").tag("quota")
                    Text("切号").tag("switch")
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                Text("续费、成员交费、新成员、重置券过期：提前 3 天提醒，同时发系统通知")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            if items.isEmpty {
                EmptyHint(icon: "bell.slash", text: filter == "unread" ? L("没有未读消息") : L("暂无消息"))
                    .frame(maxHeight: .infinity)
            } else {
                List {
                    ForEach(groups, id: \.0) { g in
                        Section(g.0) {
                            ForEach(g.1) { n in
                                NoticeRow(n: n, now: store.now)
                                    .contentShape(Rectangle())
                                    .onTapGesture { if !n.read { store.markRead([n.id]) } }
                                    .contextMenu {
                                        if !n.read { Button("标为已读") { store.markRead([n.id]) } }
                                        Button("复制内容") { copyToPasteboard(n.title + "\n" + n.body) }
                                    }
                            }
                        }
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: false))
                .scrollContentBackground(.hidden)
            }
        }
        .navigationTitle("消息")
        .navigationSubtitle(store.unread > 0 ? "\(store.unread) 条未读" : "全部已读")
        .pageToolbar(search: $query, prompt: L("搜索消息")) {
            Button { store.markRead([]) } label: { Label("全部已读", systemImage: "checkmark.circle") }
                .disabled(store.unread == 0)
            Button { store.loadDirectory(refresh: true) } label: { Label("检查新消息", systemImage: "arrow.triangle.2.circlepath") }
                .disabled(store.syncing).help("立即同步续费、成员等信息并生成提醒")
        }
    }
}

struct NoticeRow: View {
    let n: Notice
    let now: Double
    var body: some View {
        let c = Palette.level(n.level)
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: NoticeLook.icon(n))
                .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(c.gradient))
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(n.title).font(.body.weight(n.read ? .regular : .semibold)).lineLimit(2)
                    Pill(text: NoticeLook.kindText(n.kind), color: c)
                }
                if !n.body.isEmpty { Text(n.body).font(.callout).foregroundStyle(.secondary).lineLimit(3) }
                Text(meta).font(.caption).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            if !n.read { Circle().fill(Palette.accent).frame(width: 8, height: 8).padding(.top, 6) }
        }
        .padding(.vertical, 4)
    }

    private var meta: String {
        var s = L("收到于 \(TimeText.short(n.created))")
        if n.at > now { s += " · \(TimeText.until(n.at, now: now))" }
        return s
    }
}
