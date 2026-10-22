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
            List(rows) { l in LogRow(l: l).padding(.vertical, 5) }
                .listStyle(.inset(alternatesRowBackgrounds: false))
                .scrollContentBackground(.hidden)
                .textSelection(.enabled)
        }
        .navigationTitle("日志")
        .navigationSubtitle("后台服务 + 账号操作，按时间倒序")
        .pageToolbar(search: $query, prompt: L("搜索日志")) {
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
            // 日志页字号放大、行距放宽；概览里的精简版（compact）保持原来的小字
            Text(compact ? String(l.time.dropFirst(5)) : l.time)
                .font(.system(size: compact ? 11 : 12.5).monospacedDigit()).foregroundStyle(.secondary)
                .frame(width: compact ? 90 : 150, alignment: .leading)
            Text(LogRow.sourceText(l.source))
                .font(.system(size: compact ? 10 : 11.5, weight: .medium))
                .foregroundStyle(l.source == .auto ? Palette.purple : Palette.gray)
                .lineLimit(1)
                // 英文「Auto-switch」比「自动切号」宽，来源列在英文界面放宽一点；中文维持原宽
                .frame(width: AppLanguage.active == "en" ? (compact ? 64 : 80) : (compact ? 50 : 64), alignment: .leading)
            Circle().fill(tone ?? .clear).frame(width: 7, height: 7)
            Text(l.text)
                .font(compact ? .callout : .system(size: 14)).lineSpacing(compact ? 0 : 3)
                .foregroundStyle(tone == Palette.red ? Palette.red : Palette.text)
                .lineLimit(compact ? 1 : nil)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 来源显示名：rawValue 是中文（不改），显示时查表
    static func sourceText(_ s: LogLine.Source) -> String {
        switch s {
        case .auto: return L("自动切号")
        case .manager: return L("账号操作")
        }
    }

    // 关键词：中文日志（含以前写下的旧日志）和英文日志都认，英文不区分大小写。
    // 英文词和 engine.py / autoswitch.py 的英文日志约定一致
    private static let red = ["失败", "放弃", "错误", "error", "failed", "gave up"]  // i18n-ignore
    private static let orange = ["等待", "已耗尽", "停滞", "没有新进展", "waiting", "exhausted", "stalled", "no new progress"]  // i18n-ignore
    private static let green = ["续答成功", "已恢复", "resume succeeded", "recovered"]  // i18n-ignore
    private static let blue = ["切到", "切换", "切号", "switched to", "switching", "switch"]  // i18n-ignore

    /// 关键事件着色：失败红、等待橙、续答成功绿、切号蓝；普通行不标
    static func tone(_ t: String) -> Color? {
        func has(_ ks: [String]) -> Bool { ks.contains { t.range(of: $0, options: .caseInsensitive) != nil } }
        if has(red) { return Palette.red }
        if has(orange) { return Palette.orange }
        if has(green) { return Palette.green }
        if has(blue) { return Palette.accent }
        return nil
    }
}
