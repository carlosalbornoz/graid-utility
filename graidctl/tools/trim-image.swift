// Converts an icon (.icns or image) to PNG, using its largest size, and crops away the
// transparent margin so the picture fills its frame in the overview panel.
//
//   swift tools/trim-image.swift <in.icns> <out.png>
import AppKit

let args = CommandLine.arguments
guard args.count == 3, let img = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write("usage: trim-image.swift <in.icns> <out.png>\n".data(using: .utf8)!)
    exit(1)
}
let reps = img.representations.compactMap { $0 as? NSBitmapImageRep }
guard let rep = reps.max(by: { $0.pixelsWide < $1.pixelsWide }) ?? NSBitmapImageRep(data: img.tiffRepresentation!),
      let cg = rep.cgImage else { exit(1) }

let w = rep.pixelsWide, h = rep.pixelsHigh
var minX = w, minY = h, maxX = -1, maxY = -1
for y in 0..<h {
    for x in 0..<w where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.01 {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    }
}
guard maxX >= minX, let cropped = cg.cropping(to: CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)) else { exit(1) }
try! NSBitmapImageRep(cgImage: cropped).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2]))
