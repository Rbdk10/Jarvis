import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Renders a 1024x1024 opaque app icon: glowing energy orb on dark navy.
let size = 1024
let cs = CGColorSpaceCreateDeviceRGB()
// noneSkipLast => no alpha channel (App Store icons must be opaque).
guard let ctx = CGContext(data: nil, width: size, height: size,
                          bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { exit(1) }
let c = CGPoint(x: size / 2, y: size / 2)

// Background radial gradient (dark navy -> black)
let bg = CGGradient(colorsSpace: cs, colors: [
    CGColor(red: 0.03, green: 0.06, blue: 0.11, alpha: 1),
    CGColor(red: 0.0,  green: 0.0,  blue: 0.0,  alpha: 1)
] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(bg, startCenter: c, startRadius: 0, endCenter: c,
                       endRadius: CGFloat(size) * 0.72, options: [])

// Glowing orb (white core -> cyan -> transparent)
let orb = CGGradient(colorsSpace: cs, colors: [
    CGColor(red: 1.0,  green: 1.0,  blue: 1.0,  alpha: 1.0),
    CGColor(red: 0.35, green: 0.80, blue: 1.0,  alpha: 0.95),
    CGColor(red: 0.10, green: 0.50, blue: 0.95, alpha: 0.35),
    CGColor(red: 0.05, green: 0.30, blue: 0.70, alpha: 0.0)
] as CFArray, locations: [0.0, 0.30, 0.62, 1.0])!
ctx.drawRadialGradient(orb, startCenter: c, startRadius: 0, endCenter: c,
                       endRadius: CGFloat(size) * 0.42, options: [])

// Two HUD rings
ctx.setStrokeColor(CGColor(red: 0.6, green: 0.92, blue: 1.0, alpha: 0.9))
ctx.setLineWidth(7)
let r1 = CGFloat(size) * 0.40
ctx.strokeEllipse(in: CGRect(x: c.x - r1, y: c.y - r1, width: r1 * 2, height: r1 * 2))

ctx.setStrokeColor(CGColor(red: 0.4, green: 0.72, blue: 1.0, alpha: 0.4))
ctx.setLineWidth(3)
let r2 = CGFloat(size) * 0.46
ctx.strokeEllipse(in: CGRect(x: c.x - r2, y: c.y - r2, width: r2 * 2, height: r2 * 2))

guard let image = ctx.makeImage() else { exit(1) }
let out = URL(fileURLWithPath: CommandLine.arguments[1])
guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.png.identifier as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(dest, image, nil)
if CGImageDestinationFinalize(dest) { print("wrote \(out.path)") } else { exit(1) }
