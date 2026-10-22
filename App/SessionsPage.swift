import SwiftUI
import AppKit

// MARK: - 会话页

enum SessionLook {
    static func of(_ status: String) -> (String, Color) {
        switch status {
        case "running":     return ("运行中", Palette.green)
        case "stalled":     return ("疑似卡住", Palette.orange)
        case "limited":     return ("额度用完中断", Palette.red)
        case "interrupted": return ("被中断", Palette.orange)
        case "aborted":     return ("已手动停止", Palette.gray)
        case "error":       return ("出错停止", Palette.red)
        case "done":        return ("已完成", Palette.accent)
        default:            return ("空闲", Palette.gray)
        }
    }
    static func rank(_ status: String) -> Int {
        ["running": 0, "stalled": 1, "limited": 2, "interrupted": 3, "error": 4, "aborted": 5, "done": 6][status] ?? 7
    }
}

struct SessionTableRow: Identifiable {
    let s: Session
    let now: Double
    var id: String { s.thread }
    var title: String { s.displayTitle }
    var project: String { s.project }
    var rank: Int { SessionLook.rank(s.status) }
    var subagents: Int { s.subagents }
    var last: Double { s.lastActivity }
    var runFor: Double { s.isActive && s.turnStartedAt > 0 ? now - s.turnStartedAt : -1 }
    var account: String { s.slot ?? "" }
}

struct SessionsPage: View {
    @ObservedObject var store: Store
    @State private var filter = "active"
    @State private var query = ""
    @State private var order = [KeyPathComparator(\SessionTableRow.rank)]
    @State private var selection: String? = nil

    private var rows: [SessionTableRow] {
        var l = store.sessions
        if filter == "active" {
            l = l.filter { $0.isActive || $0.status == "limited" || $0.status == "interrupted" || $0.queued }
        }
        if !query.isEmpty {
            l = l.filter { $0.displayTitle.localizedCaseInsensitiveContains(query)
                || $0.project.localizedCaseInsensitiveContains(query) || $0.thread.hasPrefix(query) }
        }
        return l.map { SessionTableRow(s: $0, now: store.now) }.sorted(using: order)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("", selection: $filter) { Text("需关注").tag("active"); Text("近 48 小时全部").tag("all") }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                Text("撞限中断的对话，切号后会自动发「\(store.config.prompt)」续上").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Table(rows, selection: $selection, sortOrder: $order) {
                TableColumn("对话", value: \.title) { r in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Text(r.title).font(.system(size: 14, weight: r.s.isActive ? .semibold : .regular)).lineLimit(1)
                            if r.s.queued { Pill(text: "排队续答", color: Palette.accent) }
                        }
                        Text(r.s.error.isEmpty ? r.s.thread.prefix(8) + " · " + (r.s.cwd.isEmpty ? "—" : r.s.cwd) : r.s.error)
                            .font(.caption).foregroundStyle(r.s.error.isEmpty ? Palette.text3 : Palette.red).lineLimit(1)
                    }
                    .padding(.vertical, 6)
                }
                .width(min: 240, ideal: 340)
                TableColumn("账号", value: \.account) { r in
                    if let slot = r.s.slot, !slot.isEmpty {
                        HStack(spacing: 7) {
                            Avatar(letter: slot, size: 24)
                            VStack(alignment: .leading, spacing: 0) {
                                Text((r.s.email ?? "").components(separatedBy: "@")[0]).lineLimit(1)
                                Text(r.s.isActive ? "正在用" : "当时所在").font(.caption2).foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Text("—").foregroundStyle(.tertiary)
                    }
                }
                .width(min: 110, ideal: 140)
                TableColumn("项目", value: \.project) { r in Text(r.project.isEmpty ? "—" : r.project).help(r.s.cwd) }
                    .width(min: 90, ideal: 130)
                TableColumn("状态", value: \.rank) { r in let (t, c) = SessionLook.of(r.s.status); StatusChip(text: t, color: c) }
                    .width(min: 80, ideal: 100)
                TableColumn("子任务", value: \.subagents) { r in Text(r.subagents > 0 ? "\(r.subagents)" : "—").monospacedDigit() }
                    .width(min: 44, ideal: 54)
                TableColumn("已运行", value: \.runFor) { r in Text(r.runFor >= 0 ? TimeText.span(r.runFor) : "—").monospacedDigit() }
                    .width(min: 70, ideal: 90)
                TableColumn("最后活动", value: \.last) { r in Text(TimeText.ago(r.last, now: store.now)).foregroundStyle(.secondary) }
                    .width(min: 70, ideal: 90)
            }
            .font(.system(size: 13.5))
            .alternatingRowBackgrounds(.disabled)   // 不要斑马纹：和概览、设置一样透出页面底色
            .scrollContentBackground(.hidden)
            .contextMenu(forSelectionType: String.self) { ids in
                if let id = ids.first, let s = store.sessions.first(where: { $0.thread == id }) {
                    Button("在 ChatGPT 中打开") { open(s) }.disabled(!store.appRunning)
                    Button("发送「\(store.config.prompt)」…") { store.confirmResume = s }.disabled(s.status == "running" || s.queued)
                    Button("复制对话 ID") { copyToPasteboard(s.thread) }
                }
            } primaryAction: { ids in
                if let id = ids.first, let s = store.sessions.first(where: { $0.thread == id }), store.appRunning { open(s) }
            }
        }
        .navigationTitle("会话")
        .navigationSubtitle("\(store.activeSessions.count) 个进行中 · 当前账号 \(store.current.map { "\($0.slot) · \($0.email)" } ?? "—") · 双击在 ChatGPT 中打开")
        .pageToolbar(search: $query, prompt: "搜索标题 / 项目") {
            Button { store.reloadSessions() } label: { Label("刷新", systemImage: "arrow.clockwise") }
        }
        .onAppear { if let f = store.focus, store.sessions.contains(where: { $0.thread == f }) { selection = f; filter = "all"; store.focus = nil } }
    }

    private func open(_ s: Session) {
        if let u = URL(string: "codex://threads/\(s.thread)") { NSWorkspace.shared.open(u) }
    }
}

/// 概览里的一行对话
struct SessionLine: View {
    let s: Session
    let now: Double
    var body: some View {
        let (label, color) = SessionLook.of(s.status)
        HStack(spacing: 10) {
            Circle().fill(color).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.displayTitle).font(.callout.weight(.medium)).lineLimit(1)
                Text([(s.slot ?? "").isEmpty ? "" : "账号 \(s.slot!)", s.project, s.subagents > 0 ? "\(s.subagents) 个子任务" : "",
                      s.isActive && s.turnStartedAt > 0 ? "已运行 " + TimeText.span(now - s.turnStartedAt)
                                                        : TimeText.ago(s.lastActivity, now: now)]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
            Text(label).font(.caption.weight(.medium)).foregroundStyle(color)
        }
    }
}
