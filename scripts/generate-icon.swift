import AppKit
import Foundation

let size = 1024
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                             isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
NSColor.clear.setFill()
NSRect(x: 0, y: 0, width: size, height: size).fill()
let tile = NSBezierPath(roundedRect: NSRect(x: 42, y: 42, width: 940, height: 940), xRadius: 210, yRadius: 210)
let gradient = NSGradient(starting: NSColor(srgbRed: 0.04, green: 0.28, blue: 0.31, alpha: 1),
                          ending: NSColor(srgbRed: 0.10, green: 0.63, blue: 0.52, alpha: 1))!
gradient.draw(in: tile, angle: 45)
NSColor(srgbRed: 0.98, green: 0.80, blue: 0.44, alpha: 1).setFill()
NSBezierPath(ovalIn: NSRect(x: 690, y: 695, width: 110, height: 110)).fill()
NSColor.white.setFill()
let sail = NSBezierPath()
sail.move(to: NSPoint(x: 488, y: 780)); sail.line(to: NSPoint(x: 270, y: 420))
sail.line(to: NSPoint(x: 488, y: 420)); sail.close(); sail.fill()
NSColor.white.withAlphaComponent(0.75).setFill()
let sail2 = NSBezierPath()
sail2.move(to: NSPoint(x: 532, y: 710)); sail2.line(to: NSPoint(x: 720, y: 420))
sail2.line(to: NSPoint(x: 532, y: 420)); sail2.close(); sail2.fill()
NSColor.white.setFill()
let hull = NSBezierPath()
hull.move(to: NSPoint(x: 240, y: 375)); hull.line(to: NSPoint(x: 785, y: 375))
hull.line(to: NSPoint(x: 675, y: 270)); hull.line(to: NSPoint(x: 350, y: 270)); hull.close(); hull.fill()
NSColor.white.withAlphaComponent(0.4).setStroke()
let wave = NSBezierPath(); wave.lineWidth = 17; wave.lineCapStyle = .round
wave.move(to: NSPoint(x: 260, y: 205))
wave.curve(to: NSPoint(x: 770, y: 205), controlPoint1: NSPoint(x: 420, y: 165), controlPoint2: NSPoint(x: 610, y: 245))
wave.stroke()
NSGraphicsContext.restoreGraphicsState()
try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
