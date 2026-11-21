import AppKit
import Carbon
import ServiceManagement

// MARK: - Outils et couleurs

enum Tool: Int, CaseIterable {
    case select, image, text, oval, rect, arrow, pen, eraser
    var symbol: String { ["cursorarrow", "photo", "textformat", "circle", "square", "arrow.up.right", "scribble", "eraser"][rawValue] }
    var key: String { ["v", "i", "t", "o", "r", "a", "p", "e"][rawValue] }
    var name: String { ["Sélection", "Image", "Texte", "Rond", "Rectangle", "Flèche", "Crayon", "Gomme"][rawValue] }
}

let palette: [NSColor] = [
    NSColor(srgbRed: 0.84, green: 0.27, blue: 0.16, alpha: 1),   // terre cuite
    Canyon.ocre,
    NSColor(srgbRed: 0.50, green: 0.66, blue: 0.48, alpha: 1),   // sauge
    NSColor(srgbRed: 0.33, green: 0.48, blue: 0.62, alpha: 1),   // ardoise
    Canyon.ombre,
    Canyon.sable,
]
let colorNames = ["Terre cuite", "Ocre", "Sauge", "Ardoise", "Ombre", "Sable"]
// touches 1 à 6 (codes physiques, marche aussi en AZERTY)
let digitKeyCodes: [UInt16] = [18, 19, 20, 21, 23, 22]

let overlayLevel = NSWindow.Level.screenSaver
let selectionBlue = Canyon.ocre

// MARK: - Formes

struct Shape {
    enum Kind { case rect, oval, arrow, pen, text, image }
    var kind: Kind
    var color: NSColor
    var filled = true
    var a = CGPoint.zero, b = CGPoint.zero      // coins (ou extrémités de la flèche)
    var points: [CGPoint] = []                  // crayon
    var text = ""
    var fontSize: CGFloat = 28
    var image: NSImage?

    static let lineWidth: CGFloat = 4

    var frame: CGRect {
        if kind == .pen {
            let xs = points.map(\.x), ys = points.map(\.y)
            guard let x0 = xs.min(), let x1 = xs.max(), let y0 = ys.min(), let y1 = ys.max() else { return .zero }
            return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
        }
        return CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    var attributes: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: fontSize, weight: .semibold), .foregroundColor: color]
    }

    static func textSize(_ s: String, _ attrs: [NSAttributedString.Key: Any]) -> CGSize {
        let r = NSAttributedString(string: s.isEmpty ? " " : s, attributes: attrs)
            .boundingRect(with: CGSize(width: 10_000, height: 10_000), options: [.usesLineFragmentOrigin])
        return CGSize(width: ceil(r.width) + 4, height: ceil(r.height))
    }

    /// Redimensionne la forme pour qu'elle tienne dans r
    mutating func setFrame(_ r: CGRect) {
        let old = frame
        if kind == .text {
            if old.height > 0 { fontSize = max(8, fontSize * r.height / old.height) }
            a = r.origin
            let s = Shape.textSize(text, attributes)
            b = CGPoint(x: a.x + s.width, y: a.y + s.height)
            return
        }
        let sx = old.width > 0.5 ? r.width / old.width : 1
        let sy = old.height > 0.5 ? r.height / old.height : 1
        func map(_ p: CGPoint) -> CGPoint { CGPoint(x: r.minX + (p.x - old.minX) * sx, y: r.minY + (p.y - old.minY) * sy) }
        a = map(a); b = map(b); points = points.map(map)
    }

    mutating func move(dx: CGFloat, dy: CGFloat) {
        a.x += dx; a.y += dy; b.x += dx; b.y += dy
        points = points.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
    }

    func hit(_ p: CGPoint) -> Bool {
        switch kind {
        case .pen:
            if points.count == 1 { return hypot(p.x - points[0].x, p.y - points[0].y) < 10 }
            return zip(points, points.dropFirst()).contains { distance(p, $0, $1) < 10 }
        case .arrow: return distance(p, a, b) < 10
        default: return frame.insetBy(dx: -6, dy: -6).contains(p)
        }
    }

    func draw() {
        color.setStroke()
        switch kind {
        case .rect, .oval:
            let r = frame
            let path = kind == .rect ? NSBezierPath(roundedRect: r, xRadius: 8, yRadius: 8) : NSBezierPath(ovalIn: r)
            if filled { color.withAlphaComponent(0.55).setFill(); path.fill() }
            stroke(path)
        case .arrow:
            let path = NSBezierPath()
            path.move(to: a); path.line(to: b)
            let len = hypot(b.x - a.x, b.y - a.y)
            if len > 4 {
                let ang = atan2(b.y - a.y, b.x - a.x), head = min(22, len * 0.45)
                for d in [CGFloat.pi * 0.83, -CGFloat.pi * 0.83] {
                    path.move(to: b)
                    path.line(to: CGPoint(x: b.x + head * cos(ang + d), y: b.y + head * sin(ang + d)))
                }
            }
            stroke(path)
        case .pen:
            guard let first = points.first else { return }
            let path = NSBezierPath()
            path.move(to: first)
            if points.count == 1 { path.line(to: first) }
            // courbe lissée qui passe par le milieu des segments
            for i in 1..<points.count {
                let p0 = points[i - 1], p1 = points[i]
                let mid = CGPoint(x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2)
                path.curve(to: mid, controlPoint1: p0, controlPoint2: p0)
                if i == points.count - 1 { path.line(to: p1) }
            }
            stroke(path)
        case .text:
            NSAttributedString(string: text, attributes: attributes).draw(at: a)
        case .image:
            image?.draw(in: frame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
        }
    }

    private func stroke(_ path: NSBezierPath) {
        path.lineWidth = Shape.lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }
}

func distance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx = b.x - a.x, dy = b.y - a.y
    let len2 = dx * dx + dy * dy
    guard len2 > 0 else { return hypot(p.x - a.x, p.y - a.y) }
    let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
    return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
}

// MARK: - Calque transparent (un par écran)

final class OverlayWindow: NSWindow {
    let canvas: Canvas

    init(screen: NSScreen) {
        canvas = Canvas(frame: NSRect(origin: .zero, size: screen.frame.size))
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        setFrame(screen.frame, display: false)
        level = overlayLevel
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        contentView = canvas
        orderFrontRegardless()
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

final class Canvas: NSView, NSTextViewDelegate {
    var shapes: [Shape] = [] { didSet { needsDisplay = true } }
    var selected: Int? { didSet { needsDisplay = true } }
    var undoStack: [[Shape]] = [], redoStack: [[Shape]] = []
    var pendingSnapshot: [Shape]?     // enregistré au premier vrai déplacement

    enum Drag { case none, create(Int), move(CGPoint), handle(Int, Int), erase }
    var drag = Drag.none

    var editor: NSTextView?
    var editingIndex: Int?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Historique

    func pushUndo(_ snap: [Shape]? = nil) {
        undoStack.append(snap ?? shapes)
        if undoStack.count > 100 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    func undo() {
        commitText()
        guard let s = undoStack.popLast() else { NSSound.beep(); return }
        redoStack.append(shapes); shapes = s; selected = nil
    }

    func redo() {
        commitText()
        guard let s = redoStack.popLast() else { NSSound.beep(); return }
        undoStack.append(shapes); shapes = s; selected = nil
    }

    func clear() {
        commitText()
        guard !shapes.isEmpty else { return }
        pushUndo(); shapes.removeAll(); selected = nil
    }

    // MARK: Dessin

    override func draw(_ dirtyRect: NSRect) {
        if craie.drawing {
            // léger voile pour savoir qu'on est en mode dessin
            NSColor.black.withAlphaComponent(0.05).setFill()
            bounds.fill()
        }
        for (i, s) in shapes.enumerated() where i != editingIndex { s.draw() }
        guard craie.drawing, let i = selected, shapes.indices.contains(i) else { return }
        let s = shapes[i]
        selectionBlue.setStroke()
        if s.kind != .arrow {
            let box = NSBezierPath(roundedRect: s.frame.insetBy(dx: -6, dy: -6), xRadius: 8, yRadius: 8)
            box.lineWidth = 2.5
            box.stroke()
        }
        for h in handles(of: s) {
            let c = NSBezierPath(ovalIn: CGRect(x: h.x - 5, y: h.y - 5, width: 10, height: 10))
            NSColor.white.setFill(); c.fill()
            c.lineWidth = 2; c.stroke()
        }
    }

    func handles(of s: Shape) -> [CGPoint] {
        if s.kind == .arrow { return [s.a, s.b] }
        let r = s.frame.insetBy(dx: -6, dy: -6)
        return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
    }

    override func resetCursorRects() {
        let cursor: NSCursor
        switch craie.tool {
        case .select, .image: cursor = .arrow
        case .text: cursor = .iBeam
        default: cursor = .crosshair
        }
        addCursorRect(bounds, cursor: craie.drawing ? cursor : .arrow)
    }

    // MARK: Souris

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        window?.makeKey()
        commitText()
        pendingSnapshot = nil
        drag = .none

        switch craie.tool {
        case .select:
            if let i = selected, shapes.indices.contains(i),
               let h = handles(of: shapes[i]).firstIndex(where: { hypot($0.x - p.x, $0.y - p.y) < 10 }) {
                pendingSnapshot = shapes
                drag = .handle(i, h)
                return
            }
            selected = shapes.lastIndex { $0.hit(p) }
            guard let i = selected else { return }
            if e.clickCount == 2, shapes[i].kind == .text { beginText(at: p, editing: i); return }
            pendingSnapshot = shapes
            drag = .move(p)
        case .text:
            if let i = shapes.lastIndex(where: { $0.kind == .text && $0.hit(p) }) { beginText(at: p, editing: i) }
            else { beginText(at: CGPoint(x: p.x, y: p.y - craie.fontSize * 0.6), editing: nil) }
        case .image:
            craie.pickImage()
        case .eraser:
            pendingSnapshot = shapes
            drag = .erase
            erase(at: p)
        case .oval, .rect, .arrow, .pen:
            pushUndo()
            let kind: Shape.Kind
            switch craie.tool {
            case .oval: kind = .oval
            case .rect: kind = .rect
            case .arrow: kind = .arrow
            default: kind = .pen
            }
            shapes.append(Shape(kind: kind, color: craie.color, filled: craie.filled, a: p, b: p, points: [p]))
            selected = nil
            drag = .create(shapes.count - 1)
        }
    }

    override func mouseDragged(with e: NSEvent) {
        var p = convert(e.locationInWindow, from: nil)
        switch drag {
        case .none: break
        case .create(let i):
            switch shapes[i].kind {
            case .pen:
                if let last = shapes[i].points.last, hypot(p.x - last.x, p.y - last.y) > 1.5 { shapes[i].points.append(p) }
            case .rect, .oval:
                if e.modifierFlags.contains(.shift) {   // ⇧ = carré / cercle parfait
                    let a = shapes[i].a, side = max(abs(p.x - a.x), abs(p.y - a.y))
                    p = CGPoint(x: a.x + (p.x < a.x ? -side : side), y: a.y + (p.y < a.y ? -side : side))
                }
                shapes[i].b = p
            default:
                shapes[i].b = p
            }
        case .move(let last):
            savePending()
            if let i = selected { shapes[i].move(dx: p.x - last.x, dy: p.y - last.y) }
            drag = .move(p)
        case .handle(let i, let h):
            savePending()
            if shapes[i].kind == .arrow {
                if h == 0 { shapes[i].a = p } else { shapes[i].b = p }
            } else {
                let opposite = handles(of: shapes[i])[(h + 2) % 4]
                let r = CGRect(x: min(p.x, opposite.x), y: min(p.y, opposite.y),
                               width: abs(p.x - opposite.x), height: abs(p.y - opposite.y)).insetBy(dx: 6, dy: 6)
                if r.width > 4, r.height > 4 { shapes[i].setFrame(r) }
            }
        case .erase:
            erase(at: p)
        }
    }

    override func mouseUp(with e: NSEvent) {
        if case .create(let i) = drag {
            let s = shapes[i]
            // simple clic avec une forme : on n'ajoute rien (le crayon garde le point)
            if s.kind != .pen, s.frame.width < 3, s.frame.height < 3 {
                shapes.removeLast()
                _ = undoStack.popLast()
            }
        }
        drag = .none
        pendingSnapshot = nil
    }

    func savePending() {
        if let snap = pendingSnapshot { pushUndo(snap); pendingSnapshot = nil }
    }

    func erase(at p: CGPoint) {
        guard let i = shapes.lastIndex(where: { $0.hit(p) }) else { return }
        savePending()
        shapes.remove(at: i)
        selected = nil
    }

    // MARK: Clavier

    override func keyDown(with e: NSEvent) {
        let ch = e.charactersIgnoringModifiers?.lowercased() ?? ""
        let flags = e.modifierFlags
        if flags.contains(.command) {
            switch ch {
            case "z": flags.contains(.shift) ? redo() : undo()
            case "v": paste()
            case "w": craie.setDrawing(false)
            default: super.keyDown(with: e)
            }
            return
        }
        if e.keyCode == 53 { craie.setDrawing(false); return }                  // Échap
        if e.keyCode == 51 || e.keyCode == 117 { deleteSelected(); return }     // ⌫
        if let c = digitKeyCodes.firstIndex(of: e.keyCode) { craie.setColor(c); return }
        if ch == "f" { craie.toggleFill(); return }
        if ch == "x" { clear(); return }
        if let t = Tool.allCases.first(where: { $0.key == ch }) {
            if t == .image { craie.pickImage() } else { craie.setTool(t) }
            return
        }
        super.keyDown(with: e)
    }

    func deleteSelected() {
        guard let i = selected else { return }
        pushUndo(); shapes.remove(at: i); selected = nil
    }

    /// Couleur / remplissage choisis dans la barre : appliqués aussi à la forme sélectionnée
    func applyStyle(color: NSColor? = nil, filled: Bool? = nil) {
        guard let i = selected, shapes.indices.contains(i) else { return }
        pushUndo()
        if let c = color { shapes[i].color = c }
        if let f = filled { shapes[i].filled = f }
    }

    func paste() {
        let pb = NSPasteboard.general
        let mouse = window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) }
        let at = mouse.flatMap { bounds.contains($0) ? $0 : nil } ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let fileImage = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?
            .lazy.compactMap { NSImage(contentsOf: $0) }.first
        if pb.availableType(from: [.png, .tiff]) != nil, let img = NSImage(pasteboard: pb) {
            add(image: img, at: at)
        } else if let img = fileImage {
            add(image: img, at: at)
        } else if let s = pb.string(forType: .string), !s.isEmpty {
            pushUndo()
            var t = Shape(kind: .text, color: craie.color, a: at, text: s, fontSize: craie.fontSize)
            let size = Shape.textSize(s, t.attributes)
            t.b = CGPoint(x: at.x + size.width, y: at.y + size.height)
            shapes.append(t)
            selected = shapes.count - 1
            craie.setTool(.select)
        }
    }

    func add(image: NSImage, at c: CGPoint) {
        var w = image.size.width, h = image.size.height
        guard w > 0, h > 0 else { return }
        let scale = min(1, 480 / w, 360 / h)
        w *= scale; h *= scale
        pushUndo()
        shapes.append(Shape(kind: .image, color: craie.color,
                            a: CGPoint(x: c.x - w / 2, y: c.y - h / 2), b: CGPoint(x: c.x + w / 2, y: c.y + h / 2),
                            image: image))
        selected = shapes.count - 1
        craie.setTool(.select)
    }

    // MARK: Texte

    func beginText(at p: CGPoint, editing i: Int?) {
        let s = i.map { shapes[$0] } ?? Shape(kind: .text, color: craie.color, a: p, fontSize: craie.fontSize)
        editingIndex = i
        selected = nil
        let tv = NSTextView(frame: CGRect(origin: s.a, size: Shape.textSize(s.text, s.attributes)))
        tv.drawsBackground = false
        tv.isRichText = false
        tv.allowsUndo = true
        tv.font = s.attributes[.font] as? NSFont
        tv.textColor = s.color
        tv.insertionPointColor = s.color
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = false
        tv.textContainer?.containerSize = CGSize(width: 10_000, height: 10_000)
        tv.isHorizontallyResizable = true
        tv.string = s.text
        tv.delegate = self
        addSubview(tv)
        window?.makeFirstResponder(tv)
        editor = tv
        needsDisplay = true
    }

    func textDidChange(_ n: Notification) {
        guard let tv = editor, let font = tv.font else { return }
        let size = Shape.textSize(tv.string, [.font: font])
        tv.setFrameSize(CGSize(width: max(size.width, 20), height: size.height))
    }

    func textView(_ tv: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(cancelOperation(_:)) { commitText(); return true }   // Échap valide le texte
        return false
    }

    func commitText() {
        guard let tv = editor else { return }
        editor = nil
        let str = tv.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : tv.string
        tv.removeFromSuperview()
        defer { editingIndex = nil; window?.makeFirstResponder(self); needsDisplay = true }

        if let i = editingIndex {
            guard str != shapes[i].text else { return }
            pushUndo()
            if str.isEmpty { shapes.remove(at: i); return }
            shapes[i].text = str
            shapes[i].setFrame(shapes[i].frame)   // recalcule la taille
        } else if !str.isEmpty {
            pushUndo()
            var t = Shape(kind: .text, color: tv.textColor ?? craie.color, a: tv.frame.origin, text: str, fontSize: craie.fontSize)
            let size = Shape.textSize(str, t.attributes)
            t.b = CGPoint(x: t.a.x + size.width, y: t.a.y + size.height)
            shapes.append(t)
        }
    }
}

// MARK: - Barre d'outils

final class ToolButton: NSButton {
    var on = false { didSet { updateLook() } }

    init(symbol: String, tip: String, target: AnyObject, action: Selector) {
        super.init(frame: NSRect(x: 0, y: 0, width: 36, height: 36))
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .medium))
        imagePosition = .imageOnly
        isBordered = false
        toolTip = tip
        self.target = target
        self.action = action
        wantsLayer = true
        layer?.cornerRadius = 8
        widthAnchor.constraint(equalToConstant: 36).isActive = true
        heightAnchor.constraint(equalToConstant: 36).isActive = true
        updateLook()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func updateLook() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = on ? NSColor.labelColor.withAlphaComponent(0.16).cgColor : NSColor.clear.cgColor
        }
        contentTintColor = on ? .labelColor : .secondaryLabelColor
    }
}

final class ColorDot: NSView {
    let color: NSColor
    let onClick: () -> Void
    var on = false { didSet { needsDisplay = true } }

    init(color: NSColor, tip: String, onClick: @escaping () -> Void) {
        self.color = color
        self.onClick = onClick
        super.init(frame: NSRect(x: 0, y: 0, width: 26, height: 36))
        toolTip = tip
        widthAnchor.constraint(equalToConstant: 26).isActive = true
        heightAnchor.constraint(equalToConstant: 36).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onClick() }

    override func draw(_ dirtyRect: NSRect) {
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        if on {
            let ring = NSBezierPath(ovalIn: CGRect(x: c.x - 11, y: c.y - 11, width: 22, height: 22))
            NSColor.labelColor.withAlphaComponent(0.6).setStroke()
            ring.lineWidth = 2; ring.stroke()
        }
        let dot = NSBezierPath(ovalIn: CGRect(x: c.x - 7.5, y: c.y - 7.5, width: 15, height: 15))
        color.setFill(); dot.fill()
        NSColor.labelColor.withAlphaComponent(0.25).setStroke()
        dot.lineWidth = 1; dot.stroke()
    }
}

final class Toolbar: NSPanel {
    var toolButtons: [ToolButton] = []
    var dots: [ColorDot] = []
    var fillButton: ToolButton!

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = NSWindow.Level(rawValue: overlayLevel.rawValue + 1)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        for t in Tool.allCases {
            let b = ToolButton(symbol: t.symbol, tip: "\(t.name) (\(t.key.uppercased()))", target: self, action: #selector(toolClicked(_:)))
            b.tag = t.rawValue
            toolButtons.append(b)
            stack.addArrangedSubview(b)
        }
        stack.addArrangedSubview(separator())
        for (i, c) in palette.enumerated() {
            let d = ColorDot(color: c, tip: "\(colorNames[i]) (\(i + 1))") { craie.setColor(i) }
            dots.append(d)
            stack.addArrangedSubview(d)
        }
        fillButton = ToolButton(symbol: "square.lefthalf.filled", tip: "Remplir les formes (F)", target: self, action: #selector(fillClicked))
        stack.addArrangedSubview(fillButton)
        stack.addArrangedSubview(separator())
        stack.addArrangedSubview(ToolButton(symbol: "arrow.uturn.backward", tip: "Annuler (⌘Z)", target: self, action: #selector(undoClicked)))
        stack.addArrangedSubview(ToolButton(symbol: "trash", tip: "Tout effacer (X)", target: self, action: #selector(clearClicked)))
        stack.addArrangedSubview(ToolButton(symbol: "xmark", tip: "Terminer, les dessins restent (Échap)", target: self, action: #selector(doneClicked)))

        let fx = NSVisualEffectView()
        fx.appearance = NSAppearance(named: .darkAqua)
        fx.material = .hudWindow
        fx.state = .active
        fx.blendingMode = .behindWindow
        fx.wantsLayer = true
        fx.layer?.cornerRadius = 12
        fx.layer?.masksToBounds = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        fx.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: fx.leadingAnchor), stack.trailingAnchor.constraint(equalTo: fx.trailingAnchor),
            stack.topAnchor.constraint(equalTo: fx.topAnchor), stack.bottomAnchor.constraint(equalTo: fx.bottomAnchor),
        ])
        contentView = fx
        setContentSize(stack.fittingSize)
        refresh()
    }

    override var canBecomeKey: Bool { false }

    func separator() -> NSView {
        let v = NSBox()
        v.boxType = .separator
        v.heightAnchor.constraint(equalToConstant: 22).isActive = true
        return v
    }

    func refresh() {
        for b in toolButtons { b.on = b.tag == craie.tool.rawValue }
        for (i, d) in dots.enumerated() { d.on = i == craie.colorIndex }
        fillButton.on = craie.filled
    }

    func show(on screen: NSScreen) {
        let f = screen.visibleFrame
        setFrameOrigin(CGPoint(x: f.midX - frame.width / 2, y: f.maxY - frame.height - 12))
        orderFrontRegardless()
    }

    @objc func toolClicked(_ b: NSButton) {
        guard let t = Tool(rawValue: b.tag) else { return }
        if t == .image { craie.pickImage() } else { craie.setTool(t) }
    }
    @objc func fillClicked() { craie.toggleFill() }
    @objc func undoClicked() { craie.activeCanvas?.undo() }
    @objc func clearClicked() { craie.activeCanvas?.clear() }
    @objc func doneClicked() { craie.setDrawing(false) }
}

// MARK: - Raccourcis globaux (Carbon, pas besoin d'autorisation d'accessibilité)

var hotKeyActions: [UInt32: () -> Void] = [:]

func registerHotKey(_ keyCode: Int, _ mods: Int, id: UInt32, _ action: @escaping () -> Void) {
    hotKeyActions[id] = action
    var ref: EventHotKeyRef?
    RegisterEventHotKey(UInt32(keyCode), UInt32(mods), EventHotKeyID(signature: OSType(0x4352_4149), id: id),
                        GetApplicationEventTarget(), 0, &ref)
}

func installHotKeyHandler() {
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
        var hk = EventHotKeyID()
        GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                          nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
        DispatchQueue.main.async { hotKeyActions[hk.id]?() }
        return noErr
    }, 1, &spec, nil, nil)
}

// MARK: - App

final class Craie: NSObject, NSApplicationDelegate {
    var tool = Tool.pen
    var colorIndex = 0
    var filled = true
    var fontSize: CGFloat = 28
    var drawing = false
    var hidden = false
    var overlays: [OverlayWindow] = []
    lazy var toolbar = Toolbar()
    var status: NSStatusItem!
    var previousApp: NSRunningApplication?

    var color: NSColor { palette[colorIndex] }
    var activeCanvas: Canvas? {
        (overlays.first { $0.isKeyWindow } ?? overlayUnderMouse())?.canvas
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        buildOverlays()
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                               object: nil, queue: .main) { [weak self] _ in self?.buildOverlays() }

        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "scribble.variable", accessibilityDescription: "Craie")
        buildMenu()

        installHotKeyHandler()
        let optShift = optionKey | shiftKey
        registerHotKey(kVK_ANSI_D, optShift, id: 1) { [weak self] in self?.toggleDrawing() }
        registerHotKey(kVK_ANSI_X, optShift, id: 2) { [weak self] in self?.clearAll() }
        registerHotKey(kVK_ANSI_H, optShift, id: 3) { [weak self] in self?.toggleHidden() }
    }

    /// Un calque par écran ; on garde les dessins des écrans toujours branchés
    func buildOverlays() {
        let old = Dictionary(overlays.map { ("\($0.frame)", $0.canvas.shapes) }, uniquingKeysWith: { a, _ in a })
        overlays.forEach { $0.orderOut(nil) }
        overlays = NSScreen.screens.map { s in
            let w = OverlayWindow(screen: s)
            w.canvas.shapes = old["\(w.frame)"] ?? []
            w.alphaValue = hidden ? 0 : 1
            w.ignoresMouseEvents = !drawing
            return w
        }
    }

    func overlayUnderMouse() -> OverlayWindow? {
        let p = NSEvent.mouseLocation
        return overlays.first { NSMouseInRect(p, $0.frame, false) } ?? overlays.first
    }

    func buildMenu() {
        let m = NSMenu()
        m.addItem(withTitle: drawing ? "Terminer le dessin" : "Dessiner sur l'écran   ⌥⇧D", action: #selector(toggleDrawing), keyEquivalent: "")
        m.addItem(withTitle: "Tout effacer   ⌥⇧X", action: #selector(clearAll), keyEquivalent: "")
        m.addItem(withTitle: hidden ? "Afficher les dessins   ⌥⇧H" : "Masquer les dessins   ⌥⇧H", action: #selector(toggleHidden), keyEquivalent: "")
        m.addItem(.separator())
        let tips = ["En mode dessin : V sélection, T texte, O rond,", "R rectangle, A flèche, P crayon, E gomme,",
                    "1 à 6 couleurs, F remplir, ⌘Z annuler, ⌘V coller,", "⌫ supprimer, X tout effacer, Échap terminer"]
        for t in tips {
            let it = NSMenuItem(title: t, action: nil, keyEquivalent: "")
            it.isEnabled = false
            m.addItem(it)
        }
        m.addItem(.separator())
        let login = NSMenuItem(title: "Ouvrir au démarrage", action: #selector(toggleLogin), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        m.addItem(login)
        m.addItem(withTitle: "Quitter Craie", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        m.items.forEach { if $0.action != #selector(NSApplication.terminate(_:)) { $0.target = self } }
        status.menu = m
    }

    @objc func toggleLogin() {
        let s = SMAppService.mainApp
        do { if s.status == .enabled { try s.unregister() } else { try s.register() } } catch { NSSound.beep() }
        buildMenu()
    }

    @objc func toggleDrawing() { setDrawing(!drawing) }

    func setDrawing(_ on: Bool) {
        guard on != drawing else { return }
        if on {
            let front = NSWorkspace.shared.frontmostApplication
            previousApp = front?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : front
            if hidden { toggleHidden() }
            drawing = true
            NSApp.activate(ignoringOtherApps: true)
            for w in overlays { w.ignoresMouseEvents = false; w.canvas.needsDisplay = true }
            if let w = overlayUnderMouse() {
                w.makeKeyAndOrderFront(nil)
                w.makeFirstResponder(w.canvas)
                if let s = w.screen { toolbar.show(on: s) }
            }
            toolbar.refresh()
        } else {
            for w in overlays {
                w.canvas.commitText()
                w.canvas.selected = nil
                w.ignoresMouseEvents = true
            }
            drawing = false
            overlays.forEach { $0.canvas.needsDisplay = true; $0.invalidateCursorRects(for: $0.canvas) }
            toolbar.orderOut(nil)
            previousApp?.activate()
            previousApp = nil
        }
        buildMenu()
    }

    @objc func clearAll() { overlays.forEach { $0.canvas.clear() } }

    @objc func toggleHidden() {
        hidden.toggle()
        overlays.forEach { $0.alphaValue = hidden ? 0 : 1 }
        buildMenu()
    }

    func setTool(_ t: Tool) {
        overlays.forEach { $0.canvas.commitText() }
        tool = t
        if t != .select { overlays.forEach { $0.canvas.selected = nil } }
        overlays.forEach { $0.invalidateCursorRects(for: $0.canvas) }
        toolbar.refresh()
    }

    func setColor(_ i: Int) {
        colorIndex = i
        activeCanvas?.applyStyle(color: palette[i])
        activeCanvas?.editor.map { $0.textColor = palette[i]; $0.insertionPointColor = palette[i] }
        toolbar.refresh()
    }

    func toggleFill() {
        filled.toggle()
        activeCanvas?.applyStyle(filled: filled)
        toolbar.refresh()
    }

    func pickImage() {
        guard let w = overlays.first(where: { $0.isKeyWindow }) ?? overlayUnderMouse() else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.level = NSWindow.Level(rawValue: overlayLevel.rawValue + 2)
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url, let img = NSImage(contentsOf: url) {
            w.makeKey()
            w.canvas.add(image: img, at: CGPoint(x: w.canvas.bounds.midX, y: w.canvas.bounds.midY))
        }
    }
}

let app = NSApplication.shared
let craie = Craie()
app.delegate = craie
app.setActivationPolicy(.accessory)
app.run()
