// KeyDock 自有图标：按 2026-11-27 蓝紫玻璃钥匙坞概念绘制，可无损缩放。
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                    bytesPerRow: size * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.translateBy(x: 0, y: CGFloat(size))
ctx.scaleBy(x: 1, y: -1)
ctx.setAllowsAntialiasing(true)
ctx.setShouldAntialias(true)

func color(_ hex: UInt32, alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 255) / 255, green: CGFloat((hex >> 8) & 255) / 255,
            blue: CGFloat(hex & 255) / 255, alpha: alpha)
}
func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
func rounded(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> CGPath {
    CGPath(roundedRect: CGRect(x: x, y: y, width: w, height: h), cornerWidth: r, cornerHeight: r, transform: nil)
}
func fill(_ shape: CGPath, _ c: CGColor, evenOdd: Bool = false) {
    ctx.addPath(shape); ctx.setFillColor(c); ctx.drawPath(using: evenOdd ? .eoFill : .fill)
}
func stroke(_ shape: CGPath, _ c: CGColor, _ width: CGFloat) {
    ctx.addPath(shape); ctx.setStrokeColor(c); ctx.setLineWidth(width); ctx.setLineCap(.round); ctx.setLineJoin(.round); ctx.strokePath()
}
func shade(_ shape: CGPath, _ colors: [CGColor], _ locations: [CGFloat], from: CGPoint, to: CGPoint, evenOdd: Bool = false) {
    ctx.saveGState(); ctx.addPath(shape); ctx.clip(using: evenOdd ? .evenOdd : .winding)
    let gradient = CGGradient(colorsSpace: space, colors: colors as CFArray, locations: locations)!
    ctx.drawLinearGradient(gradient, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]); ctx.restoreGState()
}

// 外缘透明，保留 Dock/Finder 的系统图标留白；底层独立软阴影。
let body = rounded(89, 82, 846, 846, 192)
ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: -17), blur: 30, color: color(0x00102F, alpha: 0.38))
fill(body, color(0x08174B)); ctx.restoreGState()
shade(body, [color(0x1BDAF2), color(0x0874CF), color(0x142D8B), color(0x191558), color(0x5525C5)],
      [0, 0.22, 0.48, 0.78, 1], from: p(150, 90), to: p(895, 940))

ctx.saveGState(); ctx.addPath(body); ctx.clip()
let upper = CGMutablePath(); upper.move(to: p(74, 109)); upper.addLine(to: p(750, 82))
upper.addCurve(to: p(396, 282), control1: p(617, 97), control2: p(540, 221))
upper.addCurve(to: p(65, 430), control1: p(258, 336), control2: p(152, 332)); upper.closeSubpath()
shade(upper, [color(0xA1F7FF, alpha: 0.78), color(0x0BC8ED, alpha: 0.54), color(0x0B6CCE, alpha: 0.06)],
      [0, 0.44, 1], from: p(160, 84), to: p(481, 380))
let lower = CGMutablePath(); lower.move(to: p(944, 563))
lower.addCurve(to: p(564, 846), control1: p(834, 720), control2: p(731, 799))
lower.addCurve(to: p(238, 944), control1: p(419, 884), control2: p(313, 930)); lower.addLine(to: p(955, 957)); lower.closeSubpath()
shade(lower, [color(0x452EF6, alpha: 0.03), color(0x8147FC, alpha: 0.88), color(0x6A25B9, alpha: 0.78)],
      [0, 0.66, 1], from: p(629, 570), to: p(882, 922))
let arc = CGMutablePath(); arc.move(to: p(478, 343))
arc.addCurve(to: p(783, 292), control1: p(599, 228), control2: p(721, 238))
arc.addCurve(to: p(809, 448), control1: p(859, 347), control2: p(865, 393))
stroke(arc, color(0x70E7FF, alpha: 0.62), 8)
ctx.restoreGState()
stroke(rounded(94, 87, 836, 836, 187), color(0xC6EAFF, alpha: 0.40), 4)

// 主钥匙的外轮廓是连续路径，镂空处显示真正的底色。
let key = CGMutablePath()
key.move(to: p(462, 403))
key.addCurve(to: p(337, 310), control1: p(441, 344), control2: p(392, 310))
key.addCurve(to: p(189, 458), control1: p(255, 310), control2: p(189, 376))
key.addCurve(to: p(337, 606), control1: p(189, 540), control2: p(255, 606))
key.addCurve(to: p(466, 519), control1: p(394, 606), control2: p(443, 573))
key.addQuadCurve(to: p(489, 502), control: p(473, 502))
key.addLine(to: p(533, 502)); key.addQuadCurve(to: p(548, 517), control: p(548, 502))
key.addLine(to: p(548, 562)); key.addQuadCurve(to: p(566, 580), control: p(548, 580))
key.addLine(to: p(592, 580)); key.addQuadCurve(to: p(610, 562), control: p(610, 580))
key.addLine(to: p(610, 517)); key.addQuadCurve(to: p(625, 502), control: p(610, 502))
key.addLine(to: p(651, 502)); key.addQuadCurve(to: p(666, 517), control: p(666, 502))
key.addLine(to: p(666, 562)); key.addQuadCurve(to: p(684, 580), control: p(666, 580))
key.addLine(to: p(710, 580)); key.addQuadCurve(to: p(728, 562), control: p(728, 580))
key.addLine(to: p(728, 514)); key.addQuadCurve(to: p(744, 500), control: p(728, 503))
key.addCurve(to: p(780, 453), control1: p(764, 496), control2: p(780, 478))
key.addQuadCurve(to: p(735, 410), control: p(780, 410)); key.addLine(to: p(485, 410))
key.addQuadCurve(to: p(462, 403), control: p(472, 410)); key.closeSubpath()
key.addEllipse(in: CGRect(x: 269, y: 390, width: 136, height: 136))
ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 25, color: color(0x02D8FF, alpha: 0.40))
fill(key, color(0x9EEFFF), evenOdd: true); ctx.restoreGState()
shade(key, [color(0xFFFFFF), color(0xDAF7FF), color(0x94D9FB), color(0x46CBF4), color(0x9BDEFF)],
      [0, 0.25, 0.56, 0.85, 1], from: p(271, 311), to: p(641, 615), evenOdd: true)
stroke(key, color(0xE6FDFF, alpha: 0.8), 4)

// 智能星光，缩小后仍有清晰辨识度。
let star = CGMutablePath(); star.move(to: p(735, 218))
star.addQuadCurve(to: p(751, 264), control: p(742, 255)); star.addQuadCurve(to: p(790, 278), control: p(762, 270))
star.addQuadCurve(to: p(751, 293), control: p(764, 286)); star.addQuadCurve(to: p(735, 339), control: p(742, 301))
star.addQuadCurve(to: p(719, 293), control: p(728, 301)); star.addQuadCurve(to: p(680, 278), control: p(710, 286))
star.addQuadCurve(to: p(719, 264), control: p(710, 270)); star.addQuadCurve(to: p(735, 218), control: p(728, 255)); star.closeSubpath()
ctx.saveGState(); ctx.setShadow(offset: .zero, blur: 22, color: color(0x65E7FF, alpha: 0.88)); fill(star, color(0xD9FCFF)); ctx.restoreGState()
shade(star, [color(0xF8FFFF), color(0x69F0FF)], [0,1], from: p(710,224), to: p(762,333))

// 玻璃启动坞：四个独立且等距的键帽，体现快捷操作而不是密码管理器。
let dock = rounded(207, 651, 610, 158, 60)
ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0, height: -5), blur: 24, color: color(0x00DEFF, alpha: 0.48)); fill(dock, color(0x1642AC)); ctx.restoreGState()
shade(dock, [color(0xB6E9FF, alpha: 0.92), color(0x3679D8), color(0x183A9F), color(0x3DCFEF)],
      [0, 0.13, 0.67, 1], from: p(380, 650), to: p(415, 817))
stroke(dock, color(0xAEEFFF, alpha: 0.9), 4)
for i in 0..<4 {
    let x = CGFloat(255 + i * 133), tile = rounded(x, 681, 110, 96, 27)
    shade(tile, [color(0xD4EFFF, alpha: 0.88), color(i < 2 ? 0x2EA4F3 : 0x7869F5), color(i < 2 ? 0x1671DA : 0x5045CF)],
          [0, 0.42, 1], from: p(x, 682), to: p(x + 100, 778))
    stroke(tile, color(0xC2E7FF, alpha: 0.45), 2)
}

guard CommandLine.arguments.count == 2, let image = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: CommandLine.arguments[1]) as CFURL,
                                                 UTType.png.identifier as CFString, 1, nil) else { fatalError("Provide one PNG output path") }
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("Cannot write icon PNG") }
