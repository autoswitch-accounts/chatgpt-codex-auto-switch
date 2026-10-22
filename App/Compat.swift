import SwiftUI

// MARK: - 新旧系统兼容
// macOS 26 用 Liquid Glass；macOS 14 / 15 没有这些接口，退回系统原有的按钮样式和毛玻璃材质

extension View {
    /// 玻璃按钮；旧系统用描边按钮
    @ViewBuilder func glassButton() -> some View {
        if #available(macOS 26, *) { buttonStyle(.glass) } else { buttonStyle(.bordered) }
    }

    /// 强调色玻璃按钮；旧系统用实心强调色按钮
    @ViewBuilder func glassProminentButton() -> some View {
        if #available(macOS 26, *) { buttonStyle(.glassProminent) } else { buttonStyle(.borderedProminent) }
    }

    /// 玻璃底板；旧系统用常规毛玻璃材质
    @ViewBuilder func glassPanel(cornerRadius: CGFloat) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        if #available(macOS 26, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(.regularMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.primary.opacity(0.08)))
        }
    }

    /// 全屏时工具栏常显（macOS 15 起才有这个设置，14 上保持系统默认）
    @ViewBuilder func fullScreenToolbarVisible() -> some View {
        if #available(macOS 15, *) { windowToolbarFullScreenVisibility(.visible) } else { self }
    }
}
