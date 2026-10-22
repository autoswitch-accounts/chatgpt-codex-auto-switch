import SwiftUI
import AppKit

// MARK: - 设置页：两列玻璃卡片铺满内容区（系统 Form 只占中间一窄条）

struct SettingsPage: View {
    @ObservedObject var store: Store
    @AppStorage("pinOnTop") private var pinOnTop = false
    @AppStorage("appearance") private var appearance = "system"
    @State private var prompt = ""
    @State private var promptLoaded = false

    var body: some View {
        ScrollView {
            // 两列按行对齐：同一行的两张卡片一样高（全屏时左右两列不再高低错开）
            ViewThatFits(in: .horizontal) {
                Grid(horizontalSpacing: 16, verticalSpacing: 16) {
                    GridRow { autoCard.frame(minWidth: 420); noticeCard.frame(minWidth: 420) }
                    GridRow { windowCard; serviceCard }
                }
                VStack(spacing: 16) { autoCard; noticeCard; serviceCard; windowCard }
            }
            .padding(20)
        }
        .defaultScrollAnchor(.top)
        .navigationTitle("设置")
        .navigationSubtitle(store.auto.alive ? "后台服务运行中" : "后台服务未运行")
        .onAppear { if !promptLoaded { prompt = store.config.prompt; promptLoaded = true } }
        .onChange(of: pinOnTop) { _, _ in AppWindow.apply() }
    }

    // MARK: 各组

    private var orderHint: String {
        switch store.config.order {
        case "most": return "每次挑 5 小时剩余最多的账号；全部用完则等最早恢复的那个"
        case "soon": return "每次挑 5 小时窗口最快重置的账号，先把快作废的额度用掉；还没开始计时的排最后；全部用完则等最早恢复的那个"
        default: return "从当前账号往后按字母 A→Z 轮转，跳过已用完的；全部用完则等最早恢复的那个"
        }
    }

    private var autoCard: some View {
        SettingsCard(title: "自动切号", icon: "arrow.triangle.2.circlepath", tint: Palette.green) {
            SettingRow("自动切号并续答", "当前账号 5 小时或本周额度用完时，切到下一个可用账号，并在被打断的对话里发续答用语") {
                Toggle("", isOn: Binding(get: { store.config.enabled }, set: { store.setAuto($0) }))
                    .toggleStyle(SwitchStyle()).labelsHidden()
            }
            SettingRow("后台切号，不打扰", "自动切号和续答都在后台进行：ChatGPT 重启后不抢到最前面，也不跳到被续答的对话，"
                       + "你手上的窗口保持不动。你在这里手动切号时照常把 ChatGPT 叫到前台") {
                Toggle("", isOn: Binding(get: { store.config.quiet_switch },
                                         set: { store.config.quiet_switch = $0; store.setConfig("quiet_switch", $0 ? "true" : "false") }))
                    .toggleStyle(SwitchStyle()).labelsHidden()
            }
            SettingRow("切号顺序", orderHint) {
                Picker("", selection: Binding(get: { store.config.order },
                                              set: { store.config.order = $0; store.setConfig("order", "\"\($0)\"") })) {
                    Text("字母顺序").tag("alpha"); Text("重置最近优先").tag("soon"); Text("剩余最多优先").tag("most")
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            SettingRow("续答用语", "切号后在被打断的对话里自动发送的内容") {
                HStack(spacing: 6) {
                    TextField("", text: $prompt).textFieldStyle(.roundedBorder).frame(width: 140)
                    Button("保存") { savePrompt() }
                        .glassButton()
                        .disabled(prompt.trimmingCharacters(in: .whitespaces).isEmpty || prompt == store.config.prompt)
                }
            }
            SettingRow("卡住时提醒并干预", "进行中的对话 15 分钟没有任何新输出时发通知；再过 10 分钟还没动静，就在对话里追加续答用语") {
                Toggle("", isOn: Binding(get: { store.config.stall_nudge },
                                         set: { store.config.stall_nudge = $0; store.setConfig("stall_nudge", $0 ? "true" : "false") }))
                    .toggleStyle(SwitchStyle()).labelsHidden()
            }
            SettingRow("回合结束后自动继续", "对话正常结束（模型自己停下，不是额度用完）3 分钟后还没有新消息，就自动发续答用语；"
                       + "同一个对话连续自动继续 \(store.config.continue_max) 次后停下并通知你，你发一条消息就重新计数") {
                HStack(spacing: 10) {
                    Stepper("最多 \(store.config.continue_max) 次", value: Binding(
                        get: { store.config.continue_max },
                        set: { store.config.continue_max = $0; store.setConfig("continue_max", "\($0)") }), in: 1...50)
                        .disabled(!store.config.auto_continue).fixedSize()
                    Toggle("", isOn: Binding(get: { store.config.auto_continue },
                                             set: { store.config.auto_continue = $0; store.setConfig("auto_continue", $0 ? "true" : "false") }))
                        .toggleStyle(SwitchStyle()).labelsHidden()
                }
            }
            SettingRow("自动开始计时", "5 小时额度剩 100% 且还没开始计时的账号，由后台逐个发一句极短的请求，让窗口从现在开始计时；"
                       + "每次一个、间隔至少 1 分钟，本周额度用完或需要重新登录的跳过。不受上面的总开关影响，不会使用重置券", last: true) {
                Toggle("", isOn: Binding(get: { store.config.auto_start },
                                         set: { store.config.auto_start = $0; store.setConfig("auto_start", $0 ? "true" : "false") }))
                    .toggleStyle(SwitchStyle()).labelsHidden()
            }
        }
    }

    private var noticeCard: some View {
        SettingsCard(title: "消息提醒", icon: "bell.badge", tint: Palette.red) {
            SettingRow("提醒范围", "续费 / 到期、成员交费日、新成员加入、成员停用、额度重置券过期，提前 3 天进消息并发系统通知") {
                Text("3 天").foregroundStyle(.secondary)
            }
            SettingRow("自动同步", (store.directory.at > 0 ? "上次同步 \(TimeText.ago(store.directory.at, now: store.now))。" : "还没同步过。")
                       + "后台每 30 分钟同步团队、订阅、成员；额度当前账号每 3 分钟、全部账号每 10 分钟刷新", last: true) {
                Button(store.syncing ? "同步中…" : "立即同步") { store.loadDirectory(refresh: true) }
                    .glassButton().disabled(store.syncing)
            }
        }
    }

    private var serviceCard: some View {
        SettingsCard(title: "服务", icon: "server.rack", tint: Palette.indigo) {
            SettingRow("后台服务", store.auto.alive ? "运行中（launchd 常驻，开机自动启动）" : "没有运行，自动切号和提醒不会生效") {
                HStack(spacing: 8) {
                    StatusChip(text: store.auto.alive ? "运行中" : "未运行", color: store.auto.alive ? Palette.green : Palette.red)
                    Button("重启") { store.restartDaemon() }.glassButton()
                }
            }
            SettingRow("数据文件夹", Store.dataDir.path, last: true) {
                Button("在访达中打开") { NSWorkspace.shared.open(Store.dataDir) }.glassButton()
            }
        }
    }

    private var windowCard: some View {
        SettingsCard(title: "窗口", icon: "macwindow", tint: Palette.accent) {
            SettingRow("外观", "深色模式可以跟随系统，也可以固定") {
                Picker("", selection: $appearance) {
                    Text("跟随系统").tag("system"); Text("浅色").tag("light"); Text("深色").tag("dark")
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
            }
            SettingRow("窗口置顶", "开启后本窗口总在其他窗口上面（添加账号时会自动暂时取消）", last: true) {
                Toggle("", isOn: $pinOnTop).toggleStyle(SwitchStyle(on: Palette.accent)).labelsHidden()
            }
        }
    }

    private func savePrompt() {
        let p = prompt.trimmingCharacters(in: .whitespaces)
        guard let d = try? JSONSerialization.data(withJSONObject: [p]),
              let arr = String(data: d, encoding: .utf8) else { return }
        store.config.prompt = p
        store.setConfig("prompt", String(arr.dropFirst().dropLast()))
        store.say("续答用语已改为「\(p)」")
    }
}

/// 设置里的一张卡片：彩色图标 + 标题 + 若干行
struct SettingsCard<Content: View>: View {
    let title: String
    let icon: String
    let tint: Color
    @ViewBuilder var content: Content
    var body: some View {
        Card(padding: 18) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint.gradient))
                    Text(title).font(.headline)
                }
                VStack(spacing: 0) { content }
            }
            .frame(maxHeight: .infinity, alignment: .top)   // 在 Grid 里撑满一行的高度
        }
    }
}

/// 设置的一行：左边标题 + 说明，右边控件；行间细分隔线
struct SettingRow<Control: View>: View {
    let title: String
    let sub: String
    var last = false
    @ViewBuilder var control: Control

    init(_ title: String, _ sub: String, last: Bool = false, @ViewBuilder control: () -> Control) {
        self.title = title; self.sub = sub; self.last = last; self.control = control()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.body.weight(.medium))
                    Text(sub).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                control
            }
            .padding(.vertical, 11)
            if !last { Divider() }
        }
    }
}
