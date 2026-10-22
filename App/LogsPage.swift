import SwiftUI
import AppKit

// MARK: - 日志页

struct LogsPage: View {
    @ObservedObject var store: Store
    @State private var source = "all"
    @State private var query = ""
    @State private var onlyImportant = false

    private var rows: [LogLine] {
        var l = store.logs
        if source == "auto" { l = l.filter { $0.source == .auto } }
        if source == "manager" { l = l.filter { $0.source == .manager } }
        if onlyImportant { l = l.filter { LogRow.tone($0.text) != nil } }
        if !query.isEmpty { l = l.filter { $0.text.localizedCaseInsensitiveContains(query) } }
        return l.reversed()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker("", selection: $source) {
                    Text("全部").tag("all"); Text("自动切号").tag("auto"); Text("账号操作").tag("manager")
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Toggle(isOn: $onlyImportant) { Text("只看要点").font(.callout) }.toggleStyle(SwitchStyle(on: Palette.accent))
                Spacer()
                Text("\(rows.count) 条 · 每 4 秒自动刷新").font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            List(rows) { l in LogRow(l: l) }
                .listStyle(.inset(alternatesRowBackgrounds: false))
                .scrollContentBackground(.hidden)
                .textSelection(.enabled)
        }
        .navigationTitle("日志")
        .navigationSubtitle("后台服务 + 账号操作，按时间倒序")
        .pageToolbar(search: $query, prompt: "搜索日志") {
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([Store.dataDir.appendingPathComponent("autoswitch.log")])
            } label: { Label("在访达中显示", systemImage: "folder") }
        }
    }
}

/// 一行日志：时间 · 来源 · 内容（按关键词上色）
struct LogRow: View {
    let l: LogLine
    var compact = false

    var body: some View {
        let tone = LogRow.tone(l.text)
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(compact ? String(l.time.dropFirst(5)) : l.time)
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: compact ? 90 : 128, alignment: .leading)
            Text(l.source.rawValue)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(l.source == .auto ? Palette.purple : Palette.gray)
                .frame(width: 50, alignment: .leading)
            Circle().fill(tone ?? .clear).frame(width: 6, height: 6)
            Text(l.text)
                .font(.callout).foregroundStyle(tone == Palette.red ? Palette.red : Palette.text)
                .lineLimit(compact ? 1 : nil)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 关键事件着色：失败红、等待橙、续答成功绿、切号蓝；普通行不标
    static func tone(_ t: String) -> Color? {
        if t.contains("ERROR") || t.contains("失败") || t.contains("放弃") || t.contains("错误") { return Palette.red }
        if t.contains("等待") || t.contains("已耗尽") || t.contains("停滞") || t.contains("没有新进展") { return Palette.orange }
        if t.contains("续答成功") || t.contains("已恢复") { return Palette.green }
        if t.contains("切到") || t.contains("切换") || t.contains("切号") { return Palette.accent }
        return nil
    }
}
