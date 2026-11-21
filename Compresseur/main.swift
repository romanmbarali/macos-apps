import AppKit
import SwiftUI
import PDFKit
import ImageIO
import UniformTypeIdentifiers

// Dépose des images ou des PDF (sur la fenêtre ou sur l'icône de l'app) :
// une copie plus légère est créée à côté, l'original n'est jamais touché.
enum Level: String, CaseIterable, Identifiable {
    case light = "Légère", medium = "Moyenne", strong = "Forte"
    var id: String { rawValue }
    var maxPixels: Int { switch self { case .light: 2560; case .medium: 1920; case .strong: 1280 } }
    var quality: Double { switch self { case .light: 0.8; case .medium: 0.7; case .strong: 0.55 } }
    var hint: String {
        switch self {
        case .light: "Presque aucune différence visible"
        case .medium: "Le bon compromis pour les mails"
        case .strong: "Le plus léger. Les PDF deviennent des images"
        }
    }
}

struct Result: Identifiable {
    let id = UUID()
    let name: String
    var output: URL?
    var before: Int64 = 0
    var after: Int64 = 0
    var message: String?
    var done = false

    var saved: Int { before > 0 && after > 0 ? Int((1 - Double(after) / Double(before)) * 100) : 0 }
}

final class Compressor: ObservableObject {
    @Published var level = Level.medium
    @Published var results: [Result] = []
    private let queue = DispatchQueue(label: "compresseur", qos: .userInitiated)

    func add(_ urls: [URL]) {
        for url in urls {
            let r = Result(name: url.lastPathComponent)
            results.insert(r, at: 0)
            let level = self.level
            queue.async {
                var out = r
                out.before = Self.size(url)
                do {
                    let dest = try Self.compress(url, level: level)
                    out.after = Self.size(dest)
                    if out.after >= out.before {
                        try? FileManager.default.removeItem(at: dest)
                        out.message = "Déjà léger, rien à gagner"
                    } else {
                        out.output = dest
                    }
                } catch {
                    out.message = (error as? LocalizedError)?.errorDescription ?? "Impossible de compresser ce fichier"
                }
                out.done = true
                DispatchQueue.main.async {
                    if let i = self.results.firstIndex(where: { $0.id == r.id }) { self.results[i] = out }
                    if out.output != nil { NSSound(named: "Pop")?.play() }
                }
            }
        }
    }

    struct Unsupported: LocalizedError { var errorDescription: String? { "Seulement les images et les PDF" } }

    static func size(_ url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
    }

    // « photo.heic » -> « photo (léger).jpg », sans jamais écraser un fichier
    static func destination(for url: URL, ext: String) -> URL {
        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        var dest = dir.appendingPathComponent("\(base) (léger).\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent("\(base) (léger \(n)).\(ext)"); n += 1
        }
        return dest
    }

    static func compress(_ url: URL, level: Level) throws -> URL {
        let type = UTType(filenameExtension: url.pathExtension.lowercased())
        if type?.conforms(to: .pdf) == true { return try compressPDF(url, level: level) }
        if type?.conforms(to: .image) == true { return try compressImage(url, level: level) }
        throw Unsupported()
    }

    static func compressImage(_ url: URL, level: Level) throws -> URL {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,   // garde le bon sens de la photo
                  kCGImageSourceThumbnailMaxPixelSize: level.maxPixels,
              ] as CFDictionary)
        else { throw Unsupported() }

        // les PNG transparents (logos…) restent en PNG, tout le reste passe en JPEG
        let alpha = img.alphaInfo
        let hasAlpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(alpha)
        let keepPNG = hasAlpha && url.pathExtension.lowercased() == "png"
        let dest = destination(for: url, ext: keepPNG ? "png" : "jpg")
        guard let out = CGImageDestinationCreateWithURL(dest as CFURL,
                                                        (keepPNG ? UTType.png : UTType.jpeg).identifier as CFString, 1, nil)
        else { throw Unsupported() }
        CGImageDestinationAddImage(out, img, [kCGImageDestinationLossyCompressionQuality: level.quality] as CFDictionary)
        guard CGImageDestinationFinalize(out) else { throw Unsupported() }
        return dest
    }

    static func compressPDF(_ url: URL, level: Level) throws -> URL {
        guard let doc = PDFDocument(url: url) else { throw Unsupported() }
        let dest = destination(for: url, ext: "pdf")

        if level != .strong {
            // garde le texte sélectionnable, ne recompresse que les images dedans
            guard doc.write(to: dest, withOptions: [.saveImagesAsJPEGOption: true,
                                                    .optimizeImagesForScreenOption: true]) else { throw Unsupported() }
            return dest
        }

        // Forte : chaque page devient une image JPEG (le texte n'est plus sélectionnable)
        let out = PDFDocument()
        let scale: CGFloat = 130 / 72
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let box = page.bounds(for: .mediaBox)
            let w = Int(box.width * scale), h = Int(box.height * scale)
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { continue }
            ctx.setFillColor(.white); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: ctx)
            guard let cg = ctx.makeImage() else { continue }
            let jpeg = NSMutableData()
            guard let d = CGImageDestinationCreateWithData(jpeg, UTType.jpeg.identifier as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(d, cg, [kCGImageDestinationLossyCompressionQuality: level.quality] as CFDictionary)
            CGImageDestinationFinalize(d)
            guard let image = NSImage(data: jpeg as Data), let newPage = PDFPage(image: image) else { continue }
            newPage.setBounds(CGRect(origin: .zero, size: box.size), for: .mediaBox)
            out.insert(newPage, at: out.pageCount)
        }
        guard out.pageCount > 0, out.write(to: dest) else { throw Unsupported() }
        return dest
    }
}


struct ContentView: View {
    @ObservedObject var comp: Compressor
    @State private var hovering = false

    var body: some View {
        ZStack {
            FondCanyon()

            VStack(spacing: 16) {
                header
                dropZone
                levelPicker
                if !comp.results.isEmpty { resultsList }
            }
            .padding(.horizontal, 24)
            .padding(.top, 34)
            .padding(.bottom, 22)
        }
        .frame(width: 400)
        .foregroundStyle(Color.sable)
        .tint(.terre)
        .preferredColorScheme(.dark)
        .animation(.spring(duration: 0.35), value: comp.results.map(\.done))
        .animation(.spring(duration: 0.35), value: hovering)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 1) {
                Text("Compresseur").font(.system(size: 20, weight: .semibold))
                Text("L'original n'est jamais modifié").font(.subheadline).foregroundStyle(Color.sable.opacity(0.6))
            }
            Spacer()
        }
    }

    private var dropZone: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.to.line")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Color.ocre)
                .offset(y: hovering ? 4 : 0)
            Text("Dépose tes images ou PDF ici").font(.headline)
            Text("ou directement sur l'icône de l'app").font(.subheadline).foregroundStyle(Color.sable.opacity(0.6))
            Button("Choisir des fichiers…") { pickFiles() }
                .buttonStyle(.glass).tint(nil as Color?).padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 26)
        .glassEffect(.regular.tint(hovering ? Color.terre.opacity(0.35) : Color.ombre.opacity(0.45)), in: .rect(cornerRadius: 26))
        .scaleEffect(hovering ? 1.02 : 1)
        .onDrop(of: [.fileURL], isTargeted: $hovering) { providers in
            for p in providers {
                _ = p.loadObject(ofClass: URL.self) { url, _ in
                    if let url { DispatchQueue.main.async { comp.add([url]) } }
                }
            }
            return true
        }
    }

    private var levelPicker: some View {
        VStack(spacing: 8) {
            Picker("", selection: $comp.level) {
                ForEach(Level.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden()
            Text(comp.level.hint).font(.footnote).foregroundStyle(Color.sable.opacity(0.6))
        }
    }

    private var resultsList: some View {
        VStack(spacing: 0) {
            ForEach(comp.results.prefix(6)) { r in
                row(r)
                if r.id != comp.results.prefix(6).last?.id { Divider().opacity(0.4) }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 6)
        .glassEffect(.regular.tint(Color.ombre.opacity(0.45)), in: .rect(cornerRadius: 22))
    }

    private func row(_ r: Result) -> some View {
        HStack(spacing: 10) {
            Group {
                if !r.done { ProgressView().controlSize(.small) }
                else if r.output != nil { Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(Color.ocre) }
                else { Image(systemName: "minus.circle.fill").foregroundStyle(Color.sable.opacity(0.6)) }
            }
            .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(r.name).font(.callout.weight(.medium)).lineLimit(1).truncationMode(.middle)
                if let msg = r.message {
                    Text(msg).font(.caption).foregroundStyle(Color.sable.opacity(0.6))
                } else if r.done {
                    Text("\(fmt(r.before)) → \(fmt(r.after))").font(.caption).foregroundStyle(Color.sable.opacity(0.6))
                } else {
                    Text("Compression…").font(.caption).foregroundStyle(Color.sable.opacity(0.6))
                }
            }
            Spacer()
            if let out = r.output {
                Text("-\(r.saved) %").font(.callout.weight(.semibold)).foregroundStyle(Color.ocre)
                Button { NSWorkspace.shared.activateFileViewerSelecting([out]) } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.glass).tint(nil as Color?).help("Montrer dans le Finder")
            }
        }
        .padding(.vertical, 8)
    }

    private func fmt(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func pickFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.image, .pdf]
        if panel.runModal() == .OK { comp.add(panel.urls) }
    }
}

// Icône dans la barre des menus (comme Étagère) : clic = ouvrir/fermer, clic droit = menu.
// On peut aussi déposer des fichiers directement sur l'icône.
final class StatusIconView: NSView {
    var onClick: (() -> Void)?
    var onMenu: (() -> Void)?
    var onHighlight: ((Bool) -> Void)?
    var onDrop: (([URL]) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { onMenu?() } else { onClick?() }
    }
    override func rightMouseDown(with event: NSEvent) { onMenu?() }

    override func draggingEntered(_ info: NSDraggingInfo) -> NSDragOperation {
        guard onDrop != nil else { return [] }
        onHighlight?(true)
        return .copy
    }
    override func draggingExited(_ info: NSDraggingInfo?) { onHighlight?(false) }
    override func performDragOperation(_ info: NSDraggingInfo) -> Bool {
        onHighlight?(false)
        let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                       options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let comp = Compressor()
    var window: NSWindow!
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ n: Notification) {
        window = NSWindow(contentRect: .zero,
                          styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "Compresseur"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.contentView = NSHostingView(rootView: ContentView(comp: comp))
        window.isReleasedWhenClosed = false
        window.delegate = self

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        let image = NSImage(systemSymbolName: "arrow.down.right.and.arrow.up.left", accessibilityDescription: "Compresseur")
        image?.isTemplate = true
        button.image = image
        let overlay = StatusIconView(frame: button.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.onClick = { [weak self] in self?.toggle() }
        overlay.onMenu = { [weak self] in self?.showMenu() }
        overlay.onHighlight = { on in button.highlight(on) }
        overlay.onDrop = { [weak self] urls in self?.comp.add(urls); self?.showWindow() }
        button.addSubview(overlay)

        // on attend que l'icône soit placée dans la barre pour ouvrir la fenêtre dessous
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.showWindow() }
        
    }

    private func toggle() {
        if window.isVisible && NSApp.isActive { window.orderOut(nil); windowDidHide() } else { showWindow() }
    }

    // la fenêtre s'ouvre juste sous l'icône
    func showWindow() {
        if !window.isVisible, let button = statusItem.button, let bw = button.window,
           let screen = bw.screen ?? NSScreen.main {
            let icon = bw.convertToScreen(button.convert(button.bounds, to: nil))
            if let v = window.contentView { window.setContentSize(v.fittingSize) }
            let size = window.frame.size
            let vis = screen.visibleFrame
            let x = min(max(icon.midX - size.width / 2, vis.minX + 8), vis.maxX - size.width - 8)
            window.setFrameTopLeftPoint(NSPoint(x: x, y: vis.maxY - 6))
            
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ n: Notification) { windowDidHide() }
    private func windowDidHide() {  }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Ouvrir Compresseur", action: #selector(openWindow), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quitter Compresseur", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }
    @objc private func openWindow() { showWindow() }

    // fichiers déposés sur l'icône de l'app dans le Finder
    func application(_ application: NSApplication, open urls: [URL]) {
        comp.add(urls)
        if window != nil { showWindow() }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
