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
        case "paused":      return ("本 App 暂停", Palette.purple)
        case "aborted":     return ("已手动停止", Palette.gray)
        case "error":       return ("出错停止", Palette.red)
        case "done":        return ("已完成", Palette.accent)
        default:            return ("空闲", Palette.gray)
        }
    }
    static func rank(_ status: String) -> Int {
        ["running": 0, "stalled": 1, "limited": 2, "interrupted": 3, "paused": 4, "error": 5, "aborted": 6, "done": 7][status] ?? 8
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
    @State private var order = [KeyPathComparator(\SessionTableRow.last, order: .reverse)]   // 默认最近活动在前
    @State private var selection: String? = nil
    @State private var askAll = false
    @State private var askPause = false
    @State private var bulk = false
    @State private var checked: Set<String> = []     // 行首勾选；批量按钮只作用于勾选的（没勾就是列表里全部）

    private var rows: [SessionTableRow] {
        var l = store.sessions
        if filter == "active" {
            l = l.filter { $0.isActive || $0.status == "limited" || $0.status == "interrupted" || $0.status == "paused" || $0.queued }
        }
        if !query.isEmpty {
            l = l.filter { $0.displayTitle.localizedCaseInsensitiveContains(query)
                || $0.project.localizedCaseInsensitiveContains(query) || $0.thread.hasPrefix(query) }
        }
        return l.map { SessionTableRow(s: $0, now: store.now) }.sorted(using: order)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("", selection: $filter) { Text("需关注").tag("active"); Text("近 48 小时全部").tag("all") }
                    .pickerStyle(.segmented).labelsHidden().fixedSize()
                let picked = rows.filter { checked.contains($0.id) }.map(\.s)
                let some = !picked.isEmpty
                Spacer()
                let target = some ? picked : rows.map(\.s)
                Button { bulk = true } label: { Label(some ? "调整所选模型" : "批量调整模型", systemImage: "slider.horizontal.3") }
                    .glassButton().controlSize(.small).disabled(target.isEmpty)
                    .help(some ? "把勾选的对话一起改成同一个模型 / 推理强度 / 速度" : "把列表里的对话一起改成同一个模型 / 推理强度 / 速度")
                    .sheet(isPresented: $bulk) {
                        BulkModelSheet(store: store, list: target.map(store.shown)) { bulk = false }.background(PageBackground())
                    }
                let pausable = target.filter(\.canPause)
                Button { askPause = true } label: { Label((some ? "暂停 " : "全部暂停 ") + "\(pausable.count)", systemImage: "pause.fill") }
                    .glassButton().controlSize(.small).disabled(pausable.isEmpty)
                    .help("停下正在跑的这一轮（同 ChatGPT 里的停止）；排在续答队列里的移出队列")
                    .alert("暂停 \(pausable.count) 个对话？", isPresented: $askPause) {
                        Button("暂停") { store.pauseNow(pausable); checked.removeAll() }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text(pausable.prefix(6).map { "· " + $0.displayTitle }.joined(separator: "\n")
                             + (pausable.count > 6 ? "\n… 等 \(pausable.count) 个" : "")
                             + "\n\n正在跑的这一轮会停下，之后可以点「继续」接着做。")
                    }
                let all = target.filter(\.canContinue)
                Button { askAll = true } label: { Label((some ? "继续 " : "全部继续 ") + "\(all.count)", systemImage: "play.fill") }
                    .glassProminentButton().controlSize(.small).disabled(all.isEmpty)
                    .help("在\(some ? "勾选的" : "列表里所有")没在跑的对话里发「\(store.config.prompt)」，后台进行，不切到 ChatGPT")
                    .alert("在 \(all.count) 个对话里发「\(store.config.prompt)」？", isPresented: $askAll) {
                        Button("继续") { store.continueNow(all); checked.removeAll() }
                        Button("取消", role: .cancel) {}
                    } message: {
                        Text(all.prefix(6).map { "· " + $0.displayTitle }.joined(separator: "\n")
                             + (all.count > 6 ? "\n… 等 \(all.count) 个" : "")
                             + "\n\n后台排进 ChatGPT 的待发队列，不会切到 ChatGPT；每个对话会用掉当前账号的额度。")
                    }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Table(rows, selection: $selection, sortOrder: $order) {
                TableColumn("") { r in
                    Toggle("", isOn: Binding(get: { checked.contains(r.id) },
                                             set: { if $0 { checked.insert(r.id) } else { checked.remove(r.id) } }))
                        .toggleStyle(.checkbox).labelsHidden()
                }
                .width(22)
                TableColumn("对话", value: \.title) { r in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 5) {
                            Text(r.title).font(.system(size: 14, weight: r.s.isActive ? .semibold : .regular)).lineLimit(1)
                            if r.s.queued { Pill(text: "排队续答", color: Palette.accent) }
                        }
                        Text(r.s.error.isEmpty ? r.s.thread.prefix(8) + " · " + (r.s.cwd.isEmpty ? "—" : r.s.cwd) : r.s.shortError)
                            .font(.caption).foregroundStyle(r.s.error.isEmpty ? Palette.text3 : Palette.red).lineLimit(1)
                            .help(r.s.error)
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
                TableColumn("模型") { r in ModelMenu(store: store, s: r.s) }
                    .width(min: 120, ideal: 150)
                TableColumn("子任务", value: \.subagents) { r in Text(r.subagents > 0 ? "\(r.subagents)" : "—").monospacedDigit() }
                    .width(min: 44, ideal: 54)
                TableColumn("已运行", value: \.runFor) { r in Text(r.runFor >= 0 ? TimeText.span(r.runFor) : "—").monospacedDigit() }
                    .width(min: 70, ideal: 90)
                TableColumn("最后活动", value: \.last) { r in Text(TimeText.ago(r.last, now: store.now)).foregroundStyle(.secondary) }
                    .width(min: 70, ideal: 90)
                TableColumn("") { r in
                    if r.s.isActive {
                        Button("暂停") { store.pauseNow([r.s]) }
                            .glassButton().controlSize(.small)
                            .help("停下正在跑的这一轮（同 ChatGPT 里的停止），之后可以点「继续」接着做")
                    } else if r.s.canContinue {
                        Button(r.s.queued ? "立即继续" : "继续") { store.continueNow([r.s]) }
                            .glassButton().controlSize(.small)
                            .help("后台在这个对话里发「\(store.config.prompt)」，不切到 ChatGPT"
                                  + (r.s.queued ? "；它已在续答队列里，点了会提到最前面马上处理" : ""))
                    }
                }
                .width(min: 72, ideal: 84)
            }
            .font(.system(size: 13.5))
            .alternatingRowBackgrounds(.disabled)   // 不要斑马纹：和概览、设置一样透出页面底色
            .scrollContentBackground(.hidden)
            // 全选框：表头里放不了控件（TableColumn 的标题只能是文字），叠在勾选列的表头位置上
            .overlay(alignment: .topLeading) {
                let ids = rows.map(\.id)
                Toggle("", isOn: Binding(get: { !ids.isEmpty && ids.allSatisfy(checked.contains) },
                                         set: { if $0 { checked.formUnion(ids) } else { checked.subtract(ids) } }))
                    .toggleStyle(.checkbox).labelsHidden().disabled(ids.isEmpty)
                    .help("全选 / 全不选")
                    .padding(.leading, SessionsPage.checkX).frame(height: SessionsPage.headerH)
            }
            .contextMenu(forSelectionType: String.self) { ids in
                if let id = ids.first, let s = store.sessions.first(where: { $0.thread == id }) {
                    Button("在 ChatGPT 中打开") { open(s) }.disabled(!store.appRunning)
                    Button("后台继续（发「\(store.config.prompt)」）") { store.continueNow([s]) }.disabled(!s.canContinue)
                    Button("暂停") { store.pauseNow([s]) }.disabled(!s.canPause)
                    Button("打开对话并发「\(store.config.prompt)」…") { store.confirmResume = s }.disabled(s.status == "running" || s.queued)
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
        .onAppear { store.loadModels() }
        .onAppear {   // 截图 / 演示用：--sessions-all 看全部、--demo-check 勾选前 3 行、--show-bulk 打开批量调整
            // （参数后面不能跟数字：跟了窗口就不出来）
            let args = CommandLine.arguments
            if args.contains("--sessions-all") { filter = "all" }
            if args.contains("--demo-check") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { checked = Set(rows.prefix(3).map(\.id)) }
            }
            if args.contains("--show-bulk") { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { bulk = true } }
        }
        .onAppear { if let f = store.focus, store.sessions.contains(where: { $0.thread == f }) { selection = f; filter = "all"; store.focus = nil } }
    }

    // 全选框的位置：和行里的勾选框同一条竖线、表头高度居中（按实际窗口量过）
    static let checkX: CGFloat = 16
    static let headerH: CGFloat = 28

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

/// 会话表里的「模型」格：显示 模型 · 推理强度（快速带 ⚡），点开直接改这一个对话；当前值打勾
struct ModelMenu: View {
    @ObservedObject var store: Store
    let s: Session

    var body: some View {
        let v = store.shown(s)
        let cur = store.models.first { $0.id == v.model }
        Menu {
            Picker("模型", selection: Binding(get: { v.model ?? "" }, set: { id in
                if let m = store.models.first(where: { $0.id == id }) { store.setThreads([s], model: id, effort: fit(v.effort, m)) }
            })) {
                ForEach(store.models) { Text($0.name).tag($0.id) }
            }
            .pickerStyle(.inline)
            if let cur {
                Picker("推理强度", selection: Binding(get: { v.effort ?? "" }, set: { store.setThreads([s], effort: $0) })) {
                    // 对话当前用的强度不在 ChatGPT 菜单里（比如在别处设成了 Max）也列出来，好打勾
                    let extra = (v.effort ?? "").isEmpty || cur.efforts.contains(v.effort!) ? [] : [v.effort!]
                    ForEach(cur.efforts + extra, id: \.self) { Text(ModelInfo.effortName($0)).tag($0) }
                }
                .pickerStyle(.inline)
                if cur.fast {
                    Picker(ModelInfo.speedTitle, selection: Binding(get: { v.fast ? "priority" : "default" },
                                                                   set: { store.setThreads([s], tier: $0) })) {
                        Text(ModelInfo.tierLine("default", speed: cur.speed)).tag("default")
                        Text(ModelInfo.tierLine("priority", speed: cur.speed)).tag("priority")
                    }
                    .pickerStyle(.inline)
                }
            }
            Divider()
            Text("下一轮起生效；没在 ChatGPT 里打开的对话会在后台打开一下")
        } label: {
            Text((v.fast ? "⚡ " : "") + store.modelName(v.model)
                 + ((v.effort ?? "").isEmpty ? "" : " · " + ModelInfo.effortName(v.effort!)))
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton).menuIndicator(.visible).fixedSize()
        .disabled(store.models.isEmpty)
        .help("改这个对话的模型 / 推理强度 / 速度")
    }

    /// 换模型时推理强度沿用原来的；新模型不支持就用它的默认值
    private func fit(_ e: String?, _ m: ModelInfo) -> String? {
        if let e, m.efforts.contains(e) { return nil }
        return m.default.isEmpty ? nil : m.default
    }
}

/// 批量调整：列表里的对话一起改模型 / 推理强度 / 速度，每项可选「不改」
struct BulkModelSheet: View {
    @ObservedObject var store: Store
    let list: [Session]
    let onClose: () -> Void
    @State private var model = ""
    @State private var effort = ""
    @State private var tier = ""

    var body: some View {
        let m = store.models.first { $0.id == model }
        let efforts = m?.efforts ?? Array(Set(store.models.flatMap(\.efforts))).sorted { order($0) < order($1) }
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(Palette.accent.opacity(0.15))
                    Image(systemName: "slider.horizontal.3").font(.system(size: 18, weight: .medium)).foregroundStyle(Palette.accent)
                }
                .frame(width: 42, height: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text("批量调整模型").font(.system(size: 14.5, weight: .semibold))
                    Text("改 \(list.count) 个对话，下一轮起生效；没在 ChatGPT 里打开的会在后台逐个打开一下")
                        .font(.system(size: 11.5)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20).padding(.top, 20).padding(.bottom, 16)
            Divider()
            // 不用 Form(.grouped)：它的分组底是白色的，和弹窗的页面底色对不上
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 12) {
                GridRow {
                    Text("模型").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                    Picker("模型", selection: $model) {
                    Text(keep(list.map { store.modelName($0.model) })).tag("")
                    ForEach(store.models) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text("推理强度").foregroundStyle(.secondary)
                    Picker("推理强度", selection: $effort) {
                    Text(keep(list.map { ($0.effort ?? "").isEmpty ? "—" : ModelInfo.effortName($0.effort!) })).tag("")
                    ForEach(efforts, id: \.self) { Text(ModelInfo.effortName($0)).tag($0) }
                    }
                    .labelsHidden()
                }
                GridRow {
                    Text(ModelInfo.speedTitle).foregroundStyle(.secondary)
                    Picker(ModelInfo.speedTitle, selection: $tier) {
                    Text(keep(list.map { ModelInfo.tierName($0.fast ? "priority" : "default") })).tag("")
                    Text(ModelInfo.tierLine("default", speed: m?.speed)).tag("default")
                    Text(ModelInfo.tierLine("priority", speed: m?.speed)).tag("priority")
                    }
                    .labelsHidden()
                }
            }
            .padding(.horizontal, 24).padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onChange(of: model) { _, _ in if !effort.isEmpty, !efforts.contains(effort) { effort = "" } }
            Divider()
            HStack {
                Spacer()
                Button("取消") { onClose() }.keyboardShortcut(.cancelAction)
                Button("应用到 \(list.count) 个对话") {
                    store.setThreads(list, model: model.isEmpty ? nil : model, effort: effort.isEmpty ? nil : effort,
                                     tier: tier.isEmpty ? nil : tier)
                    onClose()
                }
                .glassProminentButton().keyboardShortcut(.defaultAction)
                .disabled(model.isEmpty && effort.isEmpty && tier.isEmpty)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
        }
        .frame(width: 460)
    }

    /// 「不改」后面带上当前值：大家一样就显示这个值，不一样就写「各不相同」
    private func keep(_ values: [String]) -> String {
        let u = Set(values)
        return "不改（" + (u.count == 1 ? u.first! : "各不相同") + "）"
    }

    private func order(_ e: String) -> Int { ["low", "medium", "high", "xhigh", "max", "ultra"].firstIndex(of: e) ?? 9 }
}
