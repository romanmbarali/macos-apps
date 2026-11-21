import AppKit
import AVFoundation
import PDFKit
import ServiceManagement
import UniformTypeIdentifiers

// MARK: - Types de fichiers et actions

enum Kind { case image, pdf, doc, video, audio }

struct Action {
    let label: String
    let run: ([URL]) async throws -> [URL]
}

struct GlisseError: LocalizedError {
    let errorDescription: String?
    init(_ msg: String) { errorDescription = msg }
}

let docExts: Set<String> = ["doc", "docx", "rtf", "rtfd", "txt", "md", "html", "htm", "odt", "webarchive"]

func kind(of url: URL) -> Kind? {
    let ext = url.pathExtension.lowercased()
    if docExts.contains(ext) { return .doc }
    guard let t = UTType(filenameExtension: ext) else { return nil }
    if t.conforms(to: .pdf) { return .pdf }
    if t.conforms(to: .image) { return .image }
    if t.conforms(to: .movie) || t.conforms(to: .video) { return .video }
    if t.conforms(to: .audio) { return .audio }
    return nil
}

/// "photo.png" -> "photo.jpg", ou "photo 2.jpg" si ça existe déjà
func outURL(_ src: URL, ext: String, suffix: String = "", folder: URL? = nil) -> URL {
    let dir = folder ?? src.deletingLastPathComponent()
    let base = src.deletingPathExtension().lastPathComponent + suffix
    var url = dir.appendingPathComponent(base).appendingPathExtension(ext)
    var n = 2
    while FileManager.default.fileExists(atPath: url.path) {
        url = dir.appendingPathComponent("\(base) \(n)").appendingPathExtension(ext); n += 1
    }
    return url
}

func perFile(_ urls: [URL], _ f: @escaping (URL) async throws -> [URL]) async throws -> [URL] {
    var out: [URL] = []
    for u in urls { out += try await f(u) }
    return out
}

// MARK: Images

func writeImage(_ img: CGImage, to url: URL, type: UTType, quality: Double = 0.9) throws {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
    else { throw GlisseError("Format \(url.pathExtension) non pris en charge") }
    CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { throw GlisseError("Écriture impossible") }
}

func loadImage(_ url: URL, maxPixels: Int? = nil) throws -> CGImage {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw GlisseError("Image illisible") }
    var opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                 kCGImageSourceCreateThumbnailWithTransform: true]
    if let m = maxPixels { opts[kCGImageSourceThumbnailMaxPixelSize] = m }
    else if let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
        opts[kCGImageSourceThumbnailMaxPixelSize] = max(p[kCGImagePropertyPixelWidth] as? Int ?? 4096,
                                                        p[kCGImagePropertyPixelHeight] as? Int ?? 4096)
    }
    guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { throw GlisseError("Image illisible") }
    return img
}

func convertImage(to ext: String, _ type: UTType) -> ([URL]) async throws -> [URL] {
    { urls in try await perFile(urls) { u in
        let out = outURL(u, ext: ext)
        try writeImage(try loadImage(u), to: out, type: type)
        return [out]
    } }
}

func imagesToPDF(_ urls: [URL]) throws -> [URL] {
    let doc = PDFDocument()
    for u in urls {
        guard let img = NSImage(contentsOf: u), let page = PDFPage(image: img) else { throw GlisseError("Image illisible") }
        doc.insert(page, at: doc.pageCount)
    }
    let out = urls.count == 1 ? outURL(urls[0], ext: "pdf")
                              : outURL(urls[0].deletingLastPathComponent().appendingPathComponent("Images.pdf"), ext: "pdf")
    guard doc.write(to: out) else { throw GlisseError("PDF non créé") }
    return [out]
}

func imageActions(_ urls: [URL]) -> [Action] {
    let exts = Set(urls.map { $0.pathExtension.lowercased() })
    var a: [Action] = []
    if exts != ["png"] { a.append(Action(label: "PNG", run: convertImage(to: "png", .png))) }
    if exts != ["jpg"] && exts != ["jpeg"] { a.append(Action(label: "JPG", run: convertImage(to: "jpg", .jpeg))) }
    if exts != ["heic"] { a.append(Action(label: "HEIC", run: convertImage(to: "heic", .heic))) }
    a.append(Action(label: urls.count > 1 ? "1 PDF" : "PDF") { try imagesToPDF($0) })
    a.append(Action(label: "Compresser") { urls in try await perFile(urls) { u in
        let out = outURL(u, ext: "jpg", suffix: " (compressé)")
        try writeImage(try loadImage(u), to: out, type: .jpeg, quality: 0.6)
        return [out]
    } })
    a.append(Action(label: "Taille ½") { urls in try await perFile(urls) { u in
        guard let src = CGImageSourceCreateWithURL(u as CFURL, nil),
              let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int
        else { throw GlisseError("Image illisible") }
        var ext = u.pathExtension.lowercased()
        var type = UTType(filenameExtension: ext) ?? .png
        if !(CGImageDestinationCopyTypeIdentifiers() as! [String]).contains(type.identifier) { ext = "png"; type = .png }
        let out = outURL(u, ext: ext, suffix: " (½)")
        try writeImage(try loadImage(u, maxPixels: max(w, h) / 2), to: out, type: type)
        return [out]
    } })
    return a
}

// MARK: PDF

func openPDF(_ u: URL) throws -> PDFDocument {
    guard let d = PDFDocument(url: u) else { throw GlisseError("PDF illisible") }
    return d
}

func pdfToImages(ext: String, _ type: UTType) -> ([URL]) async throws -> [URL] {
    { urls in try await perFile(urls) { u in
        let doc = try openPDF(u)
        var outs: [URL] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let box = page.bounds(for: .mediaBox)
            let scale: CGFloat = 2   // ~144 dpi
            let w = Int(box.width * scale), h = Int(box.height * scale)
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
            ctx.setFillColor(.white); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: ctx)
            guard let img = ctx.makeImage() else { continue }
            let out = outURL(u, ext: ext, suffix: doc.pageCount > 1 ? " p\(i + 1)" : "")
            try writeImage(img, to: out, type: type)
            outs.append(out)
        }
        return outs
    } }
}

func pdfActions(_ urls: [URL]) -> [Action] {
    var a: [Action] = [
        Action(label: "PNG", run: pdfToImages(ext: "png", .png)),
        Action(label: "JPG", run: pdfToImages(ext: "jpg", .jpeg)),
        Action(label: "TXT") { urls in try await perFile(urls) { u in
            let out = outURL(u, ext: "txt")
            try (try openPDF(u).string ?? "").write(to: out, atomically: true, encoding: .utf8)
            return [out]
        } },
        Action(label: "DOCX") { urls in try await perFile(urls) { u in
            let out = outURL(u, ext: "docx")
            try await writeAttributed(NSAttributedString(string: try openPDF(u).string ?? ""), to: out)
            return [out]
        } },
        Action(label: "Compresser") { urls in try await perFile(urls) { u in
            let out = outURL(u, ext: "pdf", suffix: " (compressé)")
            guard try openPDF(u).write(to: out, withOptions: [.saveImagesAsJPEGOption: true,
                                                              .optimizeImagesForScreenOption: true])
            else { throw GlisseError("Compression impossible") }
            return [out]
        } },
    ]
    if urls.count > 1 {
        a.append(Action(label: "Fusionner") { urls in
            let doc = PDFDocument()
            for u in urls {
                let d = try openPDF(u)
                for i in 0..<d.pageCount { if let p = d.page(at: i) { doc.insert(p, at: doc.pageCount) } }
            }
            let out = outURL(urls[0].deletingLastPathComponent().appendingPathComponent("Fusion.pdf"), ext: "pdf")
            guard doc.write(to: out) else { throw GlisseError("Fusion impossible") }
            return [out]
        })
    }
    return a
}

// MARK: Documents

@MainActor
func writeAttributed(_ s: NSAttributedString, to out: URL) throws {
    let range = NSRange(location: 0, length: s.length)
    let type: NSAttributedString.DocumentType
    switch out.pathExtension {
    case "txt": try s.string.write(to: out, atomically: true, encoding: .utf8); return
    case "pdf": try attributedToPDF(s, out); return
    case "docx": type = .officeOpenXML
    case "rtf": type = .rtf
    case "html": type = .html
    case "odt": type = .openDocument
    default: type = .plain
    }
    try s.data(from: range, documentAttributes: [.documentType: type]).write(to: out)
}

@MainActor
func attributedToPDF(_ s: NSAttributedString, _ out: URL) throws {
    let info = NSPrintInfo()
    info.jobDisposition = .save
    info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = out
    info.horizontalPagination = .fit
    info.verticalPagination = .automatic
    for m in [\NSPrintInfo.leftMargin, \.rightMargin, \.topMargin, \.bottomMargin] { info[keyPath: m] = 56 }
    let width = info.paperSize.width - info.leftMargin - info.rightMargin
    let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 10))
    tv.textStorage?.setAttributedString(s)
    tv.layoutManager?.ensureLayout(for: tv.textContainer!)
    let used = tv.layoutManager?.usedRect(for: tv.textContainer!).height ?? 10
    tv.frame.size.height = used + 20
    let op = NSPrintOperation(view: tv, printInfo: info)
    op.showsPrintPanel = false
    op.showsProgressPanel = false
    guard op.run() else { throw GlisseError("PDF non créé") }
}

func docActions(_ urls: [URL]) -> [Action] {
    let exts = Set(urls.map { $0.pathExtension.lowercased() })
    return ["docx", "pdf", "txt", "rtf", "html", "odt"].filter { exts != [$0] }.map { ext in
        Action(label: ext.uppercased()) { urls in try await perFile(urls) { u in
            let out = outURL(u, ext: ext)
            try await MainActor.run {
                let s = try NSAttributedString(url: u, options: [:], documentAttributes: nil)
                try writeAttributed(s, to: out)
            }
            return [out]
        } }
    }
}

// MARK: Vidéo

func export(_ u: URL, preset: String, type: AVFileType, ext: String, suffix: String = "") async throws -> URL {
    let out = outURL(u, ext: ext, suffix: suffix)
    guard let s = AVAssetExportSession(asset: AVURLAsset(url: u), presetName: preset)
    else { throw GlisseError("Export vidéo impossible") }
    do { try await s.export(to: out, as: type) }
    catch { try? FileManager.default.removeItem(at: out); throw error }
    return out
}

func remux(_ type: AVFileType, ext: String) -> ([URL]) async throws -> [URL] {
    { urls in try await perFile(urls) { u in
        // d'abord sans réencoder (instantané), sinon on réencode
        do { return [try await export(u, preset: AVAssetExportPresetPassthrough, type: type, ext: ext)] }
        catch { return [try await export(u, preset: AVAssetExportPresetHighestQuality, type: type, ext: ext)] }
    } }
}

func videoToGIF(_ u: URL) async throws -> URL {
    let asset = AVURLAsset(url: u)
    let dur = try await asset.load(.duration).seconds
    let fps = 10.0
    let n = max(1, min(Int(dur * fps), 300))   // 30 s max
    let gen = AVAssetImageGenerator(asset: asset)
    gen.appliesPreferredTrackTransform = true
    gen.maximumSize = CGSize(width: 640, height: 640)
    let tol = CMTime(seconds: 0.05, preferredTimescale: 600)
    gen.requestedTimeToleranceBefore = tol; gen.requestedTimeToleranceAfter = tol
    let out = outURL(u, ext: "gif")
    guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, n, nil)
    else { throw GlisseError("GIF impossible") }
    CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
    let frame = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
    for i in 0..<n {
        let (img, _) = try await gen.image(at: CMTime(seconds: Double(i) / fps, preferredTimescale: 600))
        CGImageDestinationAddImage(dest, img, frame)
    }
    guard CGImageDestinationFinalize(dest) else { throw GlisseError("GIF impossible") }
    return out
}

func videoActions(_ urls: [URL]) -> [Action] {
    let exts = Set(urls.map { $0.pathExtension.lowercased() })
    var a: [Action] = []
    if exts != ["mp4"] { a.append(Action(label: "MP4", run: remux(.mp4, ext: "mp4"))) }
    if exts != ["mov"] { a.append(Action(label: "MOV", run: remux(.mov, ext: "mov"))) }
    a.append(Action(label: "Compresser") { urls in try await perFile(urls) { u in
        [try await export(u, preset: AVAssetExportPresetHEVC1920x1080, type: .mp4, ext: "mp4", suffix: " (compressé)")]
    } })
    a.append(Action(label: "GIF") { urls in try await perFile(urls) { [try await videoToGIF($0)] } })
    a.append(Action(label: "Son M4A") { urls in try await perFile(urls) { u in
        guard try await !AVURLAsset(url: u).loadTracks(withMediaType: .audio).isEmpty
        else { throw GlisseError("Cette vidéo n'a pas de son") }
        return [try await export(u, preset: AVAssetExportPresetAppleM4A, type: .m4a, ext: "m4a")]
    } })
    return a
}

// MARK: Audio

func afconvert(_ fmt: String, _ data: String, ext: String, suffix: String = "", extra: [String] = []) -> ([URL]) async throws -> [URL] {
    { urls in try await perFile(urls) { u in
        let out = outURL(u, ext: ext, suffix: suffix)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/afconvert")
        p.arguments = ["-f", fmt, "-d", data] + extra + [u.path, out.path]
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw GlisseError("Conversion audio impossible") }
        return [out]
    } }
}

func audioActions(_ urls: [URL]) -> [Action] {
    let exts = Set(urls.map { $0.pathExtension.lowercased() })
    var a: [Action] = []
    if exts != ["m4a"] { a.append(Action(label: "M4A", run: afconvert("m4af", "aac", ext: "m4a", extra: ["-s", "3", "-u", "vbrq", "127"]))) }
    if exts != ["wav"] { a.append(Action(label: "WAV", run: afconvert("WAVE", "LEI16", ext: "wav"))) }
    if exts != ["aiff"] && exts != ["aif"] { a.append(Action(label: "AIFF", run: afconvert("AIFF", "BEI16", ext: "aiff"))) }
    a.append(Action(label: "Compresser") { urls in
        try await afconvert("m4af", "aac", ext: "m4a", suffix: " (compressé)", extra: ["-s", "3", "-u", "vbrq", "40"])(urls)
    })
    return a
}

func actions(for urls: [URL]) -> [Action] {
    let kinds = Set(urls.compactMap(kind(of:)))
    guard kinds.count == urls.count || kinds.count == 1, urls.allSatisfy({ kind(of: $0) != nil }) else { return [] }
    if kinds == [.image, .pdf] {   // mélange images + PDF : on fait un seul PDF
        return [Action(label: "1 PDF") { urls in
            let doc = PDFDocument()
            for u in urls {
                if kind(of: u) == .pdf {
                    let d = try openPDF(u)
                    for i in 0..<d.pageCount { if let p = d.page(at: i) { doc.insert(p, at: doc.pageCount) } }
                } else if let img = NSImage(contentsOf: u), let p = PDFPage(image: img) { doc.insert(p, at: doc.pageCount) }
            }
            let out = outURL(urls[0].deletingLastPathComponent().appendingPathComponent("Fusion.pdf"), ext: "pdf")
            guard doc.write(to: out) else { throw GlisseError("Fusion impossible") }
            return [out]
        }]
    }
    guard kinds.count == 1, let k = kinds.first else { return [] }
    switch k {
    case .image: return imageActions(urls)
    case .pdf: return pdfActions(urls)
    case .doc: return docActions(urls)
    case .video: return videoActions(urls)
    case .audio: return audioActions(urls)
    }
}

// MARK: - La roue

let orange = Canyon.ocre
let orangeDeep = Canyon.terre
let segment = NSColor(srgbRed: 0.20, green: 0.10, blue: 0.065, alpha: 0.94)   // roche sombre

final class WheelView: NSView {
    var urls: [URL] = []
    var actions: [Action] = [] { didSet { needsDisplay = true } }
    var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }   // -1 = centre (annuler)
    var onDrop: ((Action, [URL]) -> Void)?
    var onEnd: (() -> Void)?

    let outerR: CGFloat = 138, innerR: CGFloat = 46, gap: CGFloat = 7

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    var c: NSPoint { NSPoint(x: bounds.midX, y: bounds.midY) }
    var step: CGFloat { 360 / CGFloat(max(actions.count, 1)) }
    // segment i centré sur l'angle 90° - i*step (on commence en haut, sens horaire)
    func midAngle(_ i: Int) -> CGFloat { 90 - CGFloat(i) * step }

    func index(at p: NSPoint) -> Int? {
        let dx = p.x - c.x, dy = p.y - c.y, d = hypot(dx, dy)
        if d < innerR + gap / 2 { return -1 }
        if d > outerR + 10 { return nil }
        var a = atan2(dy, dx) * 180 / .pi   // -180...180
        a = 90 - a + step / 2               // 0 = début du segment 0
        a = a.truncatingRemainder(dividingBy: 360); if a < 0 { a += 360 }
        return min(Int(a / step), actions.count - 1)
    }

    override func draw(_ dirtyRect: NSRect) {
        // disque de fond
        let disk = NSBezierPath(ovalIn: NSRect(x: c.x - outerR - 8, y: c.y - outerR - 8, width: 2 * (outerR + 8), height: 2 * (outerR + 8)))
        Canyon.ombre.withAlphaComponent(0.7).setFill(); disk.fill()
        Canyon.sable.withAlphaComponent(0.25).setStroke(); disk.lineWidth = 1; disk.stroke()

        let r0 = innerR + gap
        for (i, act) in actions.enumerated() {
            let m = midAngle(i), half = step / 2 - (actions.count > 1 ? 1.6 : 0)
            let p = NSBezierPath()
            if actions.count == 1 {
                p.appendOval(in: NSRect(x: c.x - outerR, y: c.y - outerR, width: 2 * outerR, height: 2 * outerR))
                p.appendOval(in: NSRect(x: c.x - r0, y: c.y - r0, width: 2 * r0, height: 2 * r0))
                p.windingRule = .evenOdd
            } else {
                p.appendArc(withCenter: c, radius: outerR, startAngle: m + half, endAngle: m - half, clockwise: true)
                p.appendArc(withCenter: c, radius: r0, startAngle: m - half, endAngle: m + half, clockwise: false)
                p.close()
            }
            let on = hovered == i
            if on { NSGradient(starting: orange, ending: orangeDeep)!.draw(in: p, angle: -90) }
            else { segment.setFill(); p.fill() }

            let rad = (r0 + outerR) / 2 * (actions.count == 1 ? 0 : 1), ang = m * .pi / 180
            let pos = actions.count == 1 ? NSPoint(x: c.x, y: c.y + (r0 + outerR) / 2)
                                         : NSPoint(x: c.x + cos(ang) * rad, y: c.y + sin(ang) * rad)
            label(act.label, at: pos, color: on ? .white : Canyon.sable.withAlphaComponent(0.85), size: act.label.count > 5 ? 12 : 14)
        }

        // centre = annuler
        let center = NSBezierPath(ovalIn: NSRect(x: c.x - innerR, y: c.y - innerR, width: 2 * innerR, height: 2 * innerR))
        (hovered == -1 ? Canyon.rouille : segment).setFill(); center.fill()
        label("✕", at: c, color: Canyon.sable.withAlphaComponent(hovered == -1 ? 1 : 0.6), size: 16)
    }

    func label(_ s: String, at p: NSPoint, color: NSColor, size: CGFloat) {
        let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: .semibold), .foregroundColor: color]
        let sz = s.size(withAttributes: a)
        s.draw(at: NSPoint(x: p.x - sz.width / 2, y: p.y - sz.height / 2), withAttributes: a)
    }

    // glisser-déposer
    override func draggingEntered(_ s: NSDraggingInfo) -> NSDragOperation { draggingUpdated(s) }
    override func draggingUpdated(_ s: NSDraggingInfo) -> NSDragOperation {
        hovered = index(at: convert(s.draggingLocation, from: nil))
        return (hovered ?? -1) >= 0 ? .copy : .generic
    }
    override func draggingExited(_ s: NSDraggingInfo?) { hovered = nil }
    override func performDragOperation(_ s: NSDraggingInfo) -> Bool {
        defer { hovered = nil }
        guard let i = index(at: convert(s.draggingLocation, from: nil)), i >= 0 else { return false }
        onDrop?(actions[i], urls)
        return true
    }
    override func draggingEnded(_ s: NSDraggingInfo) { onEnd?() }
}

final class Panel: NSPanel {
    init(size: CGFloat) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false; backgroundColor = .clear; hasShadow = true
        level = .popUpMenu; hidesOnDeactivate = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    }
    override var canBecomeKey: Bool { false }
}

// MARK: - Petite bulle de résultat

final class Toast {
    let panel = Panel(size: 10)
    let field = NSTextField(labelWithString: "")
    var hideWork: DispatchWorkItem?

    init() {
        let fx = NSVisualEffectView()
        fx.appearance = NSAppearance(named: .darkAqua)
        fx.material = .hudWindow; fx.state = .active; fx.wantsLayer = true; fx.layer?.cornerRadius = 12
        field.font = .systemFont(ofSize: 13, weight: .medium)
        field.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: fx.leadingAnchor, constant: 14),
            field.trailingAnchor.constraint(equalTo: fx.trailingAnchor, constant: -14),
            field.centerYAnchor.constraint(equalTo: fx.centerYAnchor),
        ])
        panel.contentView = fx
        panel.ignoresMouseEvents = true
    }

    func show(_ text: String, near p: NSPoint, for seconds: Double = 2.2) {
        field.stringValue = text
        let w = field.intrinsicContentSize.width + 28
        panel.setFrame(NSRect(x: p.x - w / 2, y: p.y - 70, width: w, height: 36), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3; self?.panel.animator().alphaValue = 0 },
                                                 completionHandler: { self?.panel.orderOut(nil) })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    let size: CGFloat = 310
    lazy var panel = Panel(size: size)
    lazy var wheel = WheelView(frame: NSRect(x: 0, y: 0, width: size, height: size))
    let toast = Toast()
    var status: NSStatusItem!
    var dragCountAtMouseDown = NSPasteboard(name: .drag).changeCount
    var monitors: [Any] = []

    func applicationDidFinishLaunching(_ n: Notification) {
        panel.contentView = wheel
        wheel.onDrop = { [weak self] a, urls in self?.run(a, urls) }
        wheel.onEnd = { [weak self] in self?.hideWheel() }

        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "circle.circle", accessibilityDescription: "Glisse")
        buildMenu()

        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            self?.dragCountAtMouseDown = NSPasteboard(name: .drag).changeCount
        } as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] e in
            self?.dragged(e)
        } as Any)
        monitors.append(NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self?.hideWheel() }
        } as Any)
    }

    func buildMenu() {
        let m = NSMenu()
        let tip = NSMenuItem(title: "Maintiens ⇧ en glissant un fichier", action: nil, keyEquivalent: "")
        tip.isEnabled = false
        m.addItem(tip)
        m.addItem(.separator())
        let login = NSMenuItem(title: "Ouvrir au démarrage", action: #selector(toggleLogin), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        m.addItem(login)
        m.addItem(withTitle: "Quitter Glisse", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        status.menu = m
    }

    @objc func toggleLogin() {
        let s = SMAppService.mainApp
        do { if s.status == .enabled { try s.unregister() } else { try s.register() } }
        catch { toast.show("Impossible : \(error.localizedDescription)", near: NSEvent.mouseLocation) }
        buildMenu()
    }

    func dragged(_ e: NSEvent) {
        guard !panel.isVisible, e.modifierFlags.contains(.shift) else { return }
        let pb = NSPasteboard(name: .drag)
        guard pb.changeCount != dragCountAtMouseDown,
              let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return }
        let acts = actions(for: urls)
        guard !acts.isEmpty else {
            toast.show("Glisse ne sait pas convertir ce type de fichier", near: NSEvent.mouseLocation)
            dragCountAtMouseDown = pb.changeCount   // une seule fois par glisser
            return
        }
        wheel.urls = urls
        wheel.actions = acts
        wheel.hovered = nil

        // roue centrée sous le curseur, sans déborder de l'écran
        let p = NSEvent.mouseLocation
        var f = NSRect(x: p.x - size / 2, y: p.y - size / 2, width: size, height: size)
        if let vis = NSScreen.screens.first(where: { NSMouseInRect(p, $0.frame, false) })?.visibleFrame {
            f.origin.x = min(max(f.minX, vis.minX), vis.maxX - size)
            f.origin.y = min(max(f.minY, vis.minY), vis.maxY - size)
        }
        panel.setFrame(f, display: true)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.12; panel.animator().alphaValue = 1 }
    }

    func hideWheel() {
        guard panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.12; panel.animator().alphaValue = 0 },
                                             completionHandler: { [weak self] in self?.panel.orderOut(nil) })
    }

    func run(_ action: Action, _ urls: [URL]) {
        let at = NSEvent.mouseLocation
        hideWheel()
        toast.show("\(action.label)…", near: at, for: 600)
        Task {
            do {
                let outs = try await action.run(urls)
                await MainActor.run {
                    NSSound(named: "Glass")?.play()
                    let msg = outs.count == 1 ? "✓ \(outs[0].lastPathComponent)" : "✓ \(outs.count) fichiers créés"
                    self.toast.show(msg, near: at)
                }
            } catch {
                await MainActor.run {
                    NSSound(named: "Basso")?.play()
                    self.toast.show("✗ \(error.localizedDescription)", near: at, for: 4)
                }
            }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
