import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
// Opaque bitmap: iOS app icons must not have alpha.
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(colorSpace: cs, components: [r, g, b, a])! }
// Flip to top-left origin.
ctx.translateBy(x: 0, y: CGFloat(size)); ctx.scaleBy(x: 1, y: -1)

// Background: deep navy to near-black.
let bg = CGGradient(colorsSpace: cs, colors: [c(0.09, 0.16, 0.34), c(0.03, 0.05, 0.11)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 200, y: 0), end: CGPoint(x: 824, y: 1024), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])

// Soft blue glow behind the pad.
let glow = CGGradient(colorsSpace: cs, colors: [c(0.23, 0.51, 0.96, 0.35), c(0.23, 0.51, 0.96, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 470), startRadius: 0,
                       endCenter: CGPoint(x: 512, y: 470), endRadius: 470, options: [])

// Trackpad slab.
let pad = CGRect(x: 212, y: 232, width: 600, height: 560)
let padPath = CGPath(roundedRect: pad, cornerWidth: 84, cornerHeight: 84, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 24), blur: 60, color: c(0, 0, 0, 0.55))
ctx.addPath(padPath)
ctx.setFillColor(c(0.13, 0.16, 0.22))
ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(padPath); ctx.clip()
let sheen = CGGradient(colorsSpace: cs, colors: [c(0.22, 0.26, 0.34), c(0.12, 0.14, 0.19)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: pad.minY), end: CGPoint(x: 512, y: pad.maxY), options: [])
// Button split near the bottom.
ctx.setStrokeColor(c(0.33, 0.38, 0.48)); ctx.setLineWidth(8); ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: pad.minX, y: 652)); ctx.addLine(to: CGPoint(x: pad.maxX, y: 652))
ctx.move(to: CGPoint(x: 512, y: 652)); ctx.addLine(to: CGPoint(x: 512, y: pad.maxY))
ctx.strokePath()
ctx.restoreGState()
ctx.addPath(padPath); ctx.setStrokeColor(c(0.36, 0.42, 0.54)); ctx.setLineWidth(6); ctx.strokePath()

// Touch ripple where the "finger" taps.
let tap = CGPoint(x: 400, y: 420)
for (r, a) in [(78.0, 0.18), (50.0, 0.32)] {
    ctx.setFillColor(c(0.23, 0.51, 0.96, a))
    ctx.fillEllipse(in: CGRect(x: tap.x - r, y: tap.y - r, width: r * 2, height: r * 2))
}
ctx.setFillColor(c(0.40, 0.64, 1.0))
ctx.fillEllipse(in: CGRect(x: tap.x - 24, y: tap.y - 24, width: 48, height: 48))

// Cursor arrow, tip pointing up-left.
let o = CGPoint(x: 548, y: 330), k: CGFloat = 1.25
let pts: [(CGFloat, CGFloat)] = [(0, 0), (0, 200), (48, 156), (82, 236), (116, 222), (82, 142), (146, 142)]
let arrow = CGMutablePath()
arrow.addLines(between: pts.map { CGPoint(x: o.x + $0.0 * k, y: o.y + $0.1 * k) }); arrow.closeSubpath()
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 24, color: c(0, 0, 0, 0.5))
ctx.addPath(arrow); ctx.setFillColor(c(1, 1, 1)); ctx.fillPath()
ctx.restoreGState()
ctx.addPath(arrow); ctx.setStrokeColor(c(0.23, 0.51, 0.96)); ctx.setLineWidth(10); ctx.setLineJoin(.round); ctx.strokePath()

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
precondition(CGImageDestinationFinalize(dest))
