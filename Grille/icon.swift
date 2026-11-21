import AppKit
// Icône Liquid Glass, ambiance canyon : swift icon.swift AppIcon.icon
// Fond = strates de roche (calque plat), picto géométrique blanc = calque en verre. macOS rend le verre.
let roches: [UInt32] = [0xB8704A, 0x8A4428, 0x58241A, 0x1E0C08]   // couleurs des strates, du haut vers le bas
let houle: CGFloat = 0.7        // forme des vagues de roche
func picto() {
    for i in 0..<3 { for j in 0..<2 { pave(270 + CGFloat(i) * 172, 360 + CGFloat(j) * 172, 140, 132) } }
}
// --- moteur commun : écrit AppIcon.icon (fond roche + picto en verre + icon.json) ---
let T: CGFloat = 66                      // épaisseur des traits du picto
func c(_ hex: UInt32) -> NSColor { NSColor(srgbRed: CGFloat(hex >> 16 & 255)/255, green: CGFloat(hex >> 8 & 255)/255, blue: CGFloat(hex & 255)/255, alpha: 1) }
func trait(_ pts: [(CGFloat, CGFloat)], ferme: Bool = false) {
    let p = NSBezierPath(); p.lineWidth = T; p.lineCapStyle = .butt; p.lineJoinStyle = .miter
    p.move(to: NSPoint(x: pts[0].0, y: pts[0].1)); for q in pts.dropFirst() { p.line(to: NSPoint(x: q.0, y: q.1)) }
    if ferme { p.close() }; p.stroke()
}
func pave(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) { NSRect(x: x, y: y, width: w, height: h).fill() }
func losange(_ x: CGFloat, _ y: CGFloat, _ r: CGFloat) {
    let p = NSBezierPath(); p.move(to: NSPoint(x: x, y: y+r)); p.line(to: NSPoint(x: x+r, y: y)); p.line(to: NSPoint(x: x, y: y-r)); p.line(to: NSPoint(x: x-r, y: y)); p.close(); p.fill()
}
func toile(_ dessin: () -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    dessin(); NSGraphicsContext.restoreGraphicsState(); return rep
}
// la roche : 4 grandes strates en S qui se chevauchent (clair en haut, sombre en bas) + fines stries
func roche() {
    let cols = roches.map(c)
    cols[0].blended(withFraction: 0.15, of: NSColor(srgbRed: 1, green: 0.85, blue: 0.6, alpha: 1))!.setFill(); NSRect(x: 0, y: 0, width: 1024, height: 1024).fill()
    for i in 0..<cols.count {
        let y = 1180 - CGFloat(i) * 300, s: CGFloat = i % 2 == 0 ? 1 : -1
        func vague(_ dy: CGFloat) -> NSBezierPath {
            let p = NSBezierPath(); p.move(to: NSPoint(x: -80, y: y + dy - 140 * houle * s))
            p.curve(to: NSPoint(x: 1104, y: y + dy - 260 + 120 * houle),
                    controlPoint1: NSPoint(x: 360, y: y + dy + 380 * s * houle),
                    controlPoint2: NSPoint(x: 620, y: y + dy - 420 * s))
            return p
        }
        let band = vague(0); band.line(to: NSPoint(x: 1104, y: -80)); band.line(to: NSPoint(x: -80, y: -80)); band.close()
        let col = cols[i]
        NSGradient(colors: [col.blended(withFraction: 0.12, of: NSColor(srgbRed: 1, green: 0.85, blue: 0.6, alpha: 1))!, col, col.blended(withFraction: 0.35, of: .black)!])!.draw(in: band, angle: -75)
        for k in 1...9 {   // stries du grès
            let l = vague(-CGFloat(k) * 17); l.lineWidth = 1.6
            NSColor(white: k % 3 == 0 ? 0 : 1, alpha: 0.07).setStroke(); l.stroke()
        }
    }
}
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
let assets = dir.appendingPathComponent("Assets")
try? FileManager.default.removeItem(at: dir)
try! FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
try! toile(roche).representation(using: .png, properties: [:])!.write(to: assets.appendingPathComponent("roche.png"))
try! toile { NSColor.white.setFill(); NSColor.white.setStroke(); picto() }.representation(using: .png, properties: [:])!.write(to: assets.appendingPathComponent("picto.png"))
let json = """
{
  "fill" : { "solid" : "srgb:0.40000,0.15000,0.08000,1.00000" },
  "groups" : [
    { "layers" : [ { "image-name" : "picto.png", "name" : "picto", "glass" : true } ],
      "shadow" : { "kind" : "layer-color", "opacity" : 0.5 }, "translucency" : { "enabled" : true, "value" : 0.25 } },
    { "layers" : [ { "image-name" : "roche.png", "name" : "roche", "glass" : false } ] }
  ],
  "supported-platforms" : { "squares" : "shared" }
}
"""
try! json.write(to: dir.appendingPathComponent("icon.json"), atomically: true, encoding: .utf8)
