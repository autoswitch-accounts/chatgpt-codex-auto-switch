import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - 配色
//
// 整体走系统语义色（跟随浅色 / 深色模式和系统强调色），只有「状态色」写死：
// 系统控件在窗口失焦时会把强调色画成灰色（开关、进度条变灰就是这个原因），
// 所以额度条、开关这类表达状态的控件自己画，颜色不跟窗口焦点走。

enum Palette {
    static let accent  = Color(nsColor: .systemBlue)
    static let green   = Color(nsColor: .systemGreen)
    static let orange  = Color(nsColor: .systemOrange)
    static let red     = Color(nsColor: .systemRed)
    static let purple  = Color(nsColor: .systemPurple)
    static let teal    = Color(nsColor: .systemTeal)
    static let indigo  = Color(nsColor: .systemIndigo)
    static let gray    = Color(nsColor: .systemGray)

    static let text    = Color(nsColor: .labelColor)
    static let text2   = Color(nsColor: .secondaryLabelColor)
    static let text3   = Color(nsColor: .tertiaryLabelColor)
    static let bg      = Color(nsColor: .windowBackgroundColor)
    static let card    = Color(nsColor: .controlBackgroundColor)
    static let line    = Color(nsColor: .separatorColor)
    static let track   = Color(nsColor: .quaternaryLabelColor)
    static let fill    = Color(nsColor: .quaternaryLabelColor).opacity(0.5)
    /// 弹窗里的内容块：铺在 PageBackground 上，和概览页的卡片一样偏白（深色下偏深灰）
    // 弹窗里的小块底色：在页面底色上压一层很淡的灰，不用白底（白底和弹窗的页面底色对不上）
    static let raised  = Color.primary.opacity(0.045)

    /// 剩余百分比对应的颜色
    static func quota(_ left: Double) -> Color {
        if left < 15 { return red }
        if left < 40 { return orange }
        return green
    }

    static func level(_ l: String) -> Color {
        switch l { case "critical": return red; case "warn": return orange; default: return accent }
    }

    /// 槽位字母对应的头像色
    static func slot(_ letter: String) -> Color {
        let all: [NSColor] = [.systemBlue, .systemPurple, .systemTeal, .systemOrange, .systemPink,
                              .systemGreen, .systemIndigo, .systemBrown, .systemCyan, .systemMint]
        let i = Int(letter.unicodeScalars.first.map { $0.value } ?? 65) - 65
        return Color(nsColor: all[((i % all.count) + all.count) % all.count])
    }
}

// MARK: - 基础组件

/// 页面底色：很淡的彩色渐变，让上面的玻璃卡片有东西可透（浅色 / 深色各一套）
struct PageBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        let dark = scheme == .dark
        LinearGradient(colors: dark
                       ? [Color(red: 0.10, green: 0.11, blue: 0.16), Color(red: 0.07, green: 0.09, blue: 0.12), Color(red: 0.11, green: 0.09, blue: 0.15)]
                       : [Color(red: 0.93, green: 0.95, blue: 1.0), Color(red: 0.96, green: 0.97, blue: 0.98), Color(red: 0.95, green: 0.93, blue: 0.99)],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
    }
}

/// 卡片：Liquid Glass 玻璃底 + 圆角
struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassPanel(cornerRadius: 16)
    }
}

/// 可点的卡片：悬停微微上浮，按下缩一点
struct CardButtonStyle: ButtonStyle {
    func makeBody(configuration c: Configuration) -> some View { CardButtonBody(c: c) }
    private struct CardButtonBody: View {
        let c: ButtonStyleConfiguration
        @State private var hover = false
        var body: some View {
            c.label
                .scaleEffect(c.isPressed ? 0.98 : (hover ? 1.01 : 1))
                .shadow(color: .black.opacity(hover ? 0.10 : 0), radius: 10, y: 4)
                .animation(.snappy(duration: 0.18), value: hover)
                .animation(.snappy(duration: 0.12), value: c.isPressed)
                .onHover { hover = $0 }
                .contentShape(Rectangle())
        }
    }
}

/// 可点的行：悬停时出淡底，整行都能点
struct HoverRow: ViewModifier {
    let action: () -> Void
    @State private var hover = false
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 8).padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(hover ? Palette.fill : .clear))
            .contentShape(Rectangle())
            .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hover = h } }
            .onTapGesture(perform: action)
            .padding(.horizontal, -8)
    }
}

extension View {
    func hoverRow(_ action: @escaping () -> Void) -> some View { modifier(HoverRow(action: action)) }

    /// 每页统一的工具栏：搜索框在左，操作按钮在最右（两组各自一块玻璃）
    func pageToolbar<B: View>(search: Binding<String>? = nil, prompt: String = "",
                              @ViewBuilder buttons: @escaping () -> B) -> some View {
        toolbar {
            if let search {
                ToolbarItem(placement: .primaryAction) { SearchField(text: search, prompt: prompt) }
                if #available(macOS 26, *) { ToolbarSpacer(.fixed, placement: .primaryAction) }
            }
            ToolbarItemGroup(placement: .primaryAction) { buttons() }
        }
    }
}

/// 工具栏里的搜索框（放在操作按钮左边；系统 .searchable 只能排在最右）
struct SearchField: View {
    @Binding var text: String
    let prompt: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField(prompt, text: $text).textFieldStyle(.plain)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .frame(width: 230, height: 28)
    }
}

/// 右侧悬浮的玻璃详情面板：盖在表格上面，不挤压表格列宽
struct FloatingPanel<Content: View>: View {
    let onClose: () -> Void
    @ViewBuilder var content: Content
    var body: some View {
        content
            .frame(width: 370)
            .frame(maxHeight: .infinity)
            .overlay(alignment: .topTrailing) {
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).frame(width: 24, height: 24)
                }
                .glassButton().buttonBorderShape(.circle)
                .keyboardShortcut(.cancelAction)
                .padding(12)
            }
            .glassPanel(cornerRadius: 22)
            .shadow(color: .black.opacity(0.18), radius: 24, x: -4, y: 8)
            .padding(12)
            .transition(.move(edge: .trailing).combined(with: .opacity))
    }
}

/// 卡片标题行
struct SectionTitle<Trailing: View>: View {
    let title: String
    var icon: String? = nil
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 6) {
            if let icon { Image(systemName: icon).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary) }
            Text(title).font(.headline)
            Spacer(minLength: 0)
            trailing
        }
    }
}

extension SectionTitle where Trailing == EmptyView {
    init(title: String, icon: String? = nil) { self.init(title: title, icon: icon) { EmptyView() } }
}

/// KPI 指标卡：图标 + 大数字 + 说明
struct MetricTile: View {
    let title: String
    let value: String
    var unit: String = ""
    var detail: String = ""
    let icon: String
    var tint: Color = Palette.accent
    var body: some View {
        Card(padding: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: icon).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(tint))
                    Text(title).font(.subheadline).foregroundStyle(.secondary)
                }
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(value).font(.system(size: 26, weight: .semibold, design: .rounded).monospacedDigit())
                    if !unit.isEmpty { Text(unit).font(.subheadline).foregroundStyle(.secondary) }
                }
                Text(detail.isEmpty ? " " : detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }
}

/// 圆形头像：显示槽位字母，切号顺序一目了然
struct Avatar: View {
    let letter: String
    var size: CGFloat = 28
    var body: some View {
        ZStack {
            Circle().fill(Palette.slot(letter).gradient)
            Text(letter).font(.system(size: size * 0.45, weight: .semibold, design: .rounded)).foregroundStyle(.white)
        }
        .frame(width: size, height: size)
    }
}

/// 小胶囊标签。表格选中行（蓝底）里改成白字，否则彩色字看不清
struct Pill: View {
    let text: String
    var color: Color = Palette.gray
    /// false：放不下时截断成「…」（表格窄列用），不撑出去压到旁边的列
    var fit = true
    @Environment(\.backgroundProminence) private var prominence
    var body: some View {
        let onSelected = prominence == .increased
        Text(text)
            .font(.system(size: 10.5, weight: .semibold))
            .lineLimit(1).truncationMode(.tail)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Capsule().fill(onSelected ? Color.white.opacity(0.25) : color.opacity(0.15)))
            .foregroundStyle(onSelected ? Color.white : color)
            .fixedSize(horizontal: fit, vertical: true)
    }
}

/// 带圆点的状态标签（选中行里同样改白字）
struct StatusChip: View {
    let text: String
    let color: Color
    @Environment(\.backgroundProminence) private var prominence
    var body: some View {
        let c = prominence == .increased ? Color.white : color
        HStack(spacing: 4) {
            Circle().fill(c).frame(width: 6, height: 6)
            Text(text).font(.system(size: 11.5, weight: .medium))
        }
        .foregroundStyle(c)
        .fixedSize()
    }
}

/// 自绘进度条（系统 ProgressView 失焦会变灰）
struct QuotaBar: View {
    let value: Double          // 0...100
    var height: CGFloat = 5
    var color: Color? = nil
    // 不用 GeometryReader：放进 inspector / 表格里会让 AppKit 反复重排直到崩溃
    var body: some View {
        let v = CGFloat(min(100, max(0, value))) / 100
        Capsule().fill(Palette.track)
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .leading) {
                Capsule().fill(color ?? Palette.quota(value))
                    .scaleEffect(x: v, y: 1, anchor: .leading)
                    .opacity(v > 0 ? 1 : 0)
            }
    }
}

/// 表格里的额度单元格：百分比 + 细条
struct QuotaCell: View {
    let window: UsageWindow?
    let now: Double
    @Environment(\.backgroundProminence) private var prominence
    var body: some View {
        if let w = window {
            let left = w.remaining(now: now)
            let onSelected = prominence == .increased
            HStack(spacing: 6) {
                // 表格单元格里不能用 GeometryReader（会让 NSTableView 反复重排直到崩溃），按固定宽度画
                ZStack(alignment: .leading) {
                    Capsule().fill(onSelected ? Color.white.opacity(0.3) : Palette.track).frame(width: 46, height: 6)
                    Capsule().fill(onSelected ? Color.white : Palette.quota(left)).frame(width: left > 0 ? max(6, 46 * left / 100) : 0, height: 6)
                }
                Text("\(Int(left.rounded()))%").font(.system(size: 12.5, weight: .medium).monospacedDigit())
                    .foregroundStyle(onSelected ? Color.white : (left < 1 ? Palette.red : Palette.text))
                    .fixedSize()
            }
        } else {
            Text("—").foregroundStyle(.tertiary)
        }
    }
}

/// 额度重置时刻：没用过的窗口不显示具体时刻（服务端给的是「现在 + 窗口长度」，每次都会往后挪）
func resetText(_ w: UsageWindow?, now: Double) -> String {
    guard let w, w.resetAt > 0 else { return "—" }
    if w.resetAt <= now { return "已重置" }
    if w.untouched { return "未使用" }
    return TimeText.short(w.resetAt)
}

/// 大号额度条（概览、详情面板用）
struct BigQuota: View {
    let label: String
    let window: UsageWindow?
    let now: Double
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                if let w = window {
                    let left = w.remaining(now: now)
                    Text("\(Int(left.rounded()))%").font(.system(size: 20, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(Palette.quota(left))
                } else {
                    Text("暂无数据").font(.caption).foregroundStyle(.tertiary)
                }
            }
            QuotaBar(value: window?.remaining(now: now) ?? 0, height: 8)
            if let w = window {
                Text(detail(w)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
        }
    }
    private func detail(_ w: UsageWindow) -> String {
        if w.resetAt <= 0 { return " " }
        if w.resetAt <= now { return "已重置" }
        if w.untouched { return "还没用过 · 从第一次使用开始计时" }
        return "\(TimeText.short(w.resetAt)) 重置 · \(TimeText.until(w.resetAt, now: now))"
    }
}

/// 自绘开关（外形照着系统开关画；系统开关失焦会变灰）
struct SwitchStyle: ToggleStyle {
    var on: Color = Palette.green
    func makeBody(configuration c: Configuration) -> some View {
        HStack(spacing: 8) {
            c.label
            ZStack(alignment: c.isOn ? .trailing : .leading) {
                Capsule().fill(c.isOn ? on : Color(nsColor: .tertiaryLabelColor).opacity(0.5))
                Circle().fill(.white).shadow(color: .black.opacity(0.25), radius: 1, y: 0.5)
                    .padding(1.5)
            }
            .frame(width: 32, height: 18)
            .animation(.easeOut(duration: 0.15), value: c.isOn)
            .contentShape(Rectangle())
            .onTapGesture { c.isOn.toggle() }
        }
    }
}

/// 详情面板里的一行「键：值」
struct InfoRow<V: View>: View {
    let key: String
    @ViewBuilder var value: V
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(key).foregroundStyle(.secondary).frame(width: 78, alignment: .leading)
            value.frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
        }
        .font(.callout)
    }
}

extension InfoRow where V == Text {
    init(_ key: String, _ value: String) { self.init(key: key) { Text(value) } }
}

/// 空状态
struct EmptyHint: View {
    let icon: String
    let text: String
    var body: some View {
        ContentUnavailableView(text, systemImage: icon)
            .frame(maxWidth: .infinity).padding(.vertical, 20)
    }
}

struct Spinner: View {
    var body: some View { ProgressView().controlSize(.small) }
}

func copyToPasteboard(_ s: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(s, forType: .string)
}

/// 输入框：聚焦时光标停在末尾而不是全选
struct EndCursorField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var autofocus = true

    func makeNSView(context: Context) -> NSTextField {
        let f = NSTextField(string: text)
        f.placeholderString = placeholder
        f.delegate = context.coordinator
        f.bezelStyle = .roundedBezel
        f.font = .systemFont(ofSize: 13)
        if autofocus {
            // 只取焦点、把光标放到末尾；不要动窗口层级（会把 sheet 的宿主窗口弄没）
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                f.window?.makeFirstResponder(f)
                f.currentEditor()?.selectedRange = NSRange(location: f.stringValue.count, length: 0)
            }
        }
        return f
    }

    func updateNSView(_ v: NSTextField, context: Context) {
        if v.stringValue != text { v.stringValue = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        private let parent: EndCursorField
        init(_ p: EndCursorField) { parent = p }
        func controlTextDidChange(_ n: Notification) {
            if let f = n.object as? NSTextField { parent.text = f.stringValue }
        }
    }
}

/// CSV 导出（带 BOM，Excel 打开中文不乱码）
@MainActor
func exportCSV(name: String, header: [String], rows: [[String]]) -> URL? {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.commaSeparatedText]
    panel.nameFieldStringValue = name
    guard panel.runModal() == .OK, let url = panel.url else { return nil }
    func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
    let lines = [header.map(q).joined(separator: ",")] + rows.map { $0.map(q).joined(separator: ",") }
    do {
        try ("\u{FEFF}" + lines.joined(separator: "\n")).write(to: url, atomically: true, encoding: .utf8)
        return url
    } catch { return nil }
}
