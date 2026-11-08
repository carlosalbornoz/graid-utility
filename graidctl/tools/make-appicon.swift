// Fits a flat square logo (Img_GR_Icon.png from the original Configurator) onto the macOS app icon
// grid: an 824 px rounded square with continuous corners, centred in a 1024 px canvas with the
// standard drop shadow. Writes a 1024 px PNG; tools/fetch-artwork.sh turns it into AppIcon.icns.
//
//   swift tools/make-appicon.swift <logo.png> <out.png>
import AppKit
import SwiftUI

let args = CommandLine.arguments
guard args.count == 3, let logo = NSImage(contentsOfFile: args[1]),
      let cg = logo.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    FileHandle.standardError.write("usage: make-appicon.swift <logo.png> <out.png>\n".data(using: .utf8)!)
    exit(1)
}

let canvas = 1024, side: CGFloat = 824, radius: CGFloat = 185
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: canvas, height: canvas, bitsPerComponent: 8, bytesPerRow: 0,
                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let origin = (CGFloat(canvas) - side) / 2
let body = CGRect(x: origin, y: origin + 10, width: side, height: side)   // sits slightly high, like Apple's
let shape = RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: body).cgPath

// The logo's own blue, sampled just inside its top-left corner, fills the tile edge to edge.
let sample = NSBitmapImageRep(cgImage: cg).colorAt(x: 8, y: 8)!.usingColorSpace(.sRGB)!
let fill = CGColor(srgbRed: sample.redComponent, green: sample.greenComponent, blue: sample.blueComponent, alpha: 1)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 20, color: CGColor(gray: 0, alpha: 0.3))
ctx.addPath(shape); ctx.setFillColor(fill); ctx.fillPath()
ctx.restoreGState()

// The logo is drawn a little smaller than the tile so the mark clears the curved corners.
ctx.addPath(shape); ctx.clip()
ctx.interpolationQuality = .high
ctx.draw(cg, in: body.insetBy(dx: 40, dy: 40))

let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
