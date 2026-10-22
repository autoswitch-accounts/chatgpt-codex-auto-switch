// 生成 App 图标：xcrun swiftc make_icon.swift -o /tmp/mkicon && /tmp/mkicon（输出 icon1024.png，再用 sips + iconutil 做成 appicon.icns）
// 造型：翠绿渐变圆角方块 + 玻璃高光；中间三张叠起来的账号卡片，右下角白色徽章里是切换箭头
import AppKit
let S: CGFloat = 1024
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let body = NSRect(x: 100, y: 100, width: 824, height: 824)
let path = NSBezierPath(roundedRect: body, xRadius: 186, yRadius: 186)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.28).cgColor)
NSColor.black.setFill(); path.fill()
ctx.restoreGState()
ctx.saveGState()
path.addClip()
NSGradient(colors: [NSColor(srgbRed: 0.36, green: 0.90, blue: 0.62, alpha: 1),
                    NSColor(srgbRed: 0.05, green: 0.66, blue: 0.55, alpha: 1),
                    NSColor(srgbRed: 0.02, green: 0.36, blue: 0.42, alpha: 1)])!.draw(in: body, angle: -60)
NSGradient(colors: [NSColor.white.withAlphaComponent(0.32), NSColor.white.withAlphaComponent(0.0)])!
    .draw(in: NSRect(x: 100, y: 540, width: 824, height: 384), angle: -90)
ctx.restoreGState()

// 叠起来的三张卡片（后两张半透明，像玻璃）
func card(_ r: NSRect, alpha: CGFloat, shadow: Bool) {
    let p = NSBezierPath(roundedRect: r, xRadius: 54, yRadius: 54)
    ctx.saveGState()
    if shadow { ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: NSColor.black.withAlphaComponent(0.25).cgColor) }
    NSColor.white.withAlphaComponent(alpha).setFill(); p.fill()
    ctx.restoreGState()
}
card(NSRect(x: 330, y: 560, width: 380, height: 150), alpha: 0.35, shadow: false)
card(NSRect(x: 290, y: 500, width: 460, height: 190), alpha: 0.55, shadow: false)
let front = NSRect(x: 240, y: 300, width: 544, height: 330)
card(front, alpha: 1, shadow: true)
// 卡片上的头像 + 两条文字线
let teal = NSColor(srgbRed: 0.04, green: 0.55, blue: 0.50, alpha: 1)
teal.setFill()
NSBezierPath(ovalIn: NSRect(x: 290, y: 395, width: 140, height: 140)).fill()
let personCfg = NSImage.SymbolConfiguration(pointSize: 82, weight: .bold).applying(.init(paletteColors: [.white]))
let person = NSImage(systemSymbolName: "person.fill", accessibilityDescription: nil)!.withSymbolConfiguration(personCfg)!
person.draw(in: NSRect(x: 360 - person.size.width / 2, y: 465 - person.size.height / 2, width: person.size.width, height: person.size.height))
teal.withAlphaComponent(0.85).setFill()
NSBezierPath(roundedRect: NSRect(x: 460, y: 485, width: 260, height: 34), xRadius: 17, yRadius: 17).fill()
teal.withAlphaComponent(0.35).setFill()
NSBezierPath(roundedRect: NSRect(x: 460, y: 420, width: 190, height: 30), xRadius: 15, yRadius: 15).fill()
// 右下角徽章：白圆 + 切换箭头
let badge = NSRect(x: 600, y: 210, width: 230, height: 230)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 20, color: NSColor.black.withAlphaComponent(0.3).cgColor)
NSColor.white.setFill(); NSBezierPath(ovalIn: badge).fill()
ctx.restoreGState()
let arrowCfg = NSImage.SymbolConfiguration(pointSize: 120, weight: .bold).applying(.init(paletteColors: [teal]))
let arrow = NSImage(systemSymbolName: "arrow.triangle.2.circlepath", accessibilityDescription: nil)!.withSymbolConfiguration(arrowCfg)!
arrow.draw(in: NSRect(x: badge.midX - arrow.size.width / 2, y: badge.midY - arrow.size.height / 2, width: arrow.size.width, height: arrow.size.height))
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "icon1024.png"))
