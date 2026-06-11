// Slices assets/HiveIcons.png (2 rows × 8 cells of 90×90) into per-piece
// PNGs and generates "carbon" silhouettes (solid black + solid white).
// Run: swift tools/slice-pieces.swift
import AppKit

let sheetPath = "assets/HiveIcons.png"
let outBase = "Sources/Hive/Resources/Pieces"
// Left-to-right order in the sheet.
let order = ["ant", "beetle", "grasshopper", "ladybug", "mosquito", "queen", "spider", "pillbug"]

guard let sheet = NSImage(contentsOfFile: sheetPath),
      let cg = sheet.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
    fatalError("cannot load \(sheetPath)")
}
let cell = cg.width / 8
let rows = cg.height / cell
print("sheet \(cg.width)x\(cg.height), cell \(cell), rows \(rows)")

func write(_ image: CGImage, to path: String) {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("png encode") }
    try! FileManager.default.createDirectory(
        atPath: (path as NSString).deletingLastPathComponent,
        withIntermediateDirectories: true)
    try! data.write(to: URL(fileURLWithPath: path))
}

func crop(row: Int, col: Int) -> CGImage {
    cg.cropping(to: CGRect(x: col * cell, y: row * cell, width: cell, height: cell))!
}

/// Pixel difference ratio between two equally sized images.
func diffRatio(_ a: CGImage, _ b: CGImage) -> Double {
    func bytes(_ img: CGImage) -> [UInt8] {
        let w = img.width, h = img.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(
            data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        return buf
    }
    let ba = bytes(a), bb = bytes(b)
    var diff = 0
    for i in 0..<ba.count where abs(Int(ba[i]) - Int(bb[i])) > 16 { diff += 1 }
    return Double(diff) / Double(ba.count)
}

/// Solid-color silhouette using the icon's alpha as a mask.
func silhouette(_ img: CGImage, white: Bool) -> CGImage {
    let w = img.width, h = img.height
    let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let rect = CGRect(x: 0, y: 0, width: w, height: h)
    ctx.draw(img, in: rect)
    ctx.setBlendMode(.sourceIn)
    ctx.setFillColor(white ? CGColor(gray: 1, alpha: 1) : CGColor(gray: 0, alpha: 1))
    ctx.fill(rect)
    return ctx.makeImage()!
}

for (col, name) in order.enumerated() {
    let top = crop(row: 0, col: col)
    if rows > 1 {
        let bottom = crop(row: 1, col: col)
        print("\(name): rows differ by \(String(format: "%.1f", diffRatio(top, bottom) * 100))%")
    }
    write(top, to: "\(outBase)/classic/\(name).png")
    write(silhouette(top, white: false), to: "\(outBase)/carbon/\(name)-dark.png")
    write(silhouette(top, white: true), to: "\(outBase)/carbon/\(name)-light.png")
}
print("wrote \(order.count * 3) images to \(outBase)")
