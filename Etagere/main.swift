import AppKit
import UniformTypeIdentifiers

// MARK: - Un élément posé sur l'étagère

final class ShelfEntry {
    enum Kind {
        case file(URL)
        case link(URL)
        case text(String)
    }

    let id = UUID()
    let kind: Kind

    init(_ kind: Kind) { self.kind = kind }

    var title: String {
        switch kind {
        case .file(let url):
            return FileManager.default.displayName(atPath: url.path)
        case .link(let url):
            let host = url.host ?? url.absoluteString
            return url.path.count > 1 ? host + url.path : host
        case .text(let s):
            let first = s.split(whereSeparator: \.isNewline).first.map(String.init) ?? s
            return first.trimmingCharacters(in: .whitespaces)
        }
    }

    var subtitle: String {
        switch kind {
        case .file(let url):
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if values?.isDirectory == true { return "Dossier" }
            let size = ByteCountFormatter.string(fromByteCount: Int64(values?.fileSize ?? 0), countStyle: .file)
            let ext = url.pathExtension.uppercased()
            return ext.isEmpty ? size : "\(ext) · \(size)"
        case .link:
            return "Lien"
        case .text(let s):
            return "Texte · \(s.count) caractères"
        }
    }

    lazy var icon: NSImage = {
        switch kind {
        case .file(let url):
            if let type = UTType(filenameExtension: url.pathExtension), type.conforms(to: .image),
               let image = NSImage(contentsOf: url) {
                return Icons.fit(image, side: 64)
            }
            return NSWorkspace.shared.icon(forFile: url.path)
        case .link:
            return Icons.tile(symbol: "link")
        case .text:
            return Icons.tile(symbol: "text.alignleft")
        }
    }()

    /// Ce qu'on donne à l'app de destination quand on fait glisser l'élément hors de l'étagère.
    func pasteboardWriter() -> NSPasteboardWriting {
        switch kind {
        case .file(let url):
            return url as NSURL
        case .link(let url):
            let item = NSPasteboardItem()
            item.setString(url.absoluteString, forType: .URL)
            item.setString(url.absoluteString, forType: .string)
            return item
        case .text(let s):
            let item = NSPasteboardItem()
            item.setString(s, forType: .string)
            return item
        }
    }

    func open() {
        switch kind {
        case .file(let url), .link(let url):
            NSWorkspace.shared.open(url)
        case .text(let s):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s, forType: .string)
        }
    }

    /// Forme simple (type + valeur) pour l'enregistrer sur le disque.
    var stored: (kind: String, value: String) {
        switch kind {
        case .file(let url): return ("file", url.path)
        case .link(let url): return ("link", url.absoluteString)
        case .text(let s): return ("text", s)
        }
    }

    static func make(kind: String, value: String) -> ShelfEntry {
        switch kind {
        case "file": return ShelfEntry(.file(URL(fileURLWithPath: value)))
        case "link": return URL(string: value).map { ShelfEntry(.link($0)) } ?? ShelfEntry(.text(value))
        default: return ShelfEntry(.text(value))
        }
    }

    func isSameFile(as other: ShelfEntry) -> Bool {
        if case .file(let a) = kind, case .file(let b) = other.kind { return a.standardizedFileURL == b.standardizedFileURL }
        return false
    }
}

// MARK: - Icônes

enum Icons {
    /// Une icône SF Symbol posée sur une petite tuile arrondie.
    static func tile(symbol: String) -> NSImage {
        NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            NSColor.quaternaryLabelColor.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 4, dy: 4), xRadius: 12, yRadius: 12).fill()
            let config = NSImage.SymbolConfiguration(pointSize: 26, weight: .medium)
                .applying(.init(paletteColors: [.secondaryLabelColor]))
            if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(config) {
                let s = img.size
                img.draw(in: NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height))
            }
            return true
        }
    }

    /// Réduit une image dans un carré sans la déformer.
    static func fit(_ image: NSImage, side: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            let s = image.size
            guard s.width > 0, s.height > 0 else { return true }
            let scale = min(rect.width / s.width, rect.height / s.height)
            let w = s.width * scale, h = s.height * scale
            image.draw(in: NSRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h))
            return true
        }
    }

    /// Plusieurs icônes empilées, pour la ligne « Tout glisser ».
    static func stacked(_ icons: [NSImage]) -> NSImage {
        NSImage(size: NSSize(width: 64, height: 64), flipped: false) { _ in
            let shown = Array(icons.prefix(3))
            for (i, img) in shown.enumerated().reversed() {
                let off = CGFloat(i) * 8
                img.draw(in: NSRect(x: off, y: 16 - off, width: 48, height: 48))
            }
            return true
        }
    }
}

// MARK: - Lecture de ce qu'on dépose

enum DropReader {
    static let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Etagere", isDirectory: true)

    static let promiseQueue: OperationQueue = {
        let q = OperationQueue()
        q.qualityOfService = .userInitiated
        return q
    }()

    static let jpeg = NSPasteboard.PasteboardType(UTType.jpeg.identifier)

    static var acceptedTypes: [NSPasteboard.PasteboardType] {
        [.fileURL, .URL, .string, .png, .tiff, jpeg]
            + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    }

    static func freshFolder() -> URL {
        let url = cacheRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func clearCache() {
        try? FileManager.default.removeItem(at: cacheRoot)
    }

    /// Lit le contenu déposé. Les fichiers « promis » (Photos, pièces jointes Mail…) arrivent un peu après.
    static func read(_ pb: NSPasteboard, add: @escaping ([ShelfEntry]) -> Void) -> Bool {
        // 1. De vrais fichiers (Finder, bureau…)
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            add(urls.map { ShelfEntry(.file($0)) })
            return true
        }

        // 2. Des fichiers promis, que l'app source écrit pour nous
        if let receivers = pb.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver],
           !receivers.isEmpty {
            for receiver in receivers {
                receiver.receivePromisedFiles(atDestination: freshFolder(), options: [:], operationQueue: promiseQueue) { url, error in
                    guard error == nil else { return }
                    DispatchQueue.main.async { add([ShelfEntry(.file(url))]) }
                }
            }
            return true
        }

        // 3. Une image sans fichier (copiée d'une page web, d'un aperçu…)
        if let file = saveImage(from: pb) {
            add([ShelfEntry(.file(file))])
            return true
        }

        // 4. Des liens web
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL] {
            let links = urls.filter { !$0.isFileURL }
            if !links.isEmpty {
                add(links.map { ShelfEntry(.link($0)) })
                return true
            }
        }

        // 5. Du texte
        if let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            if !text.contains(where: \.isWhitespace), let url = URL(string: text),
               let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) {
                add([ShelfEntry(.link(url))])
            } else {
                add([ShelfEntry(.text(text))])
            }
            return true
        }
        return false
    }

    private static func saveImage(from pb: NSPasteboard) -> URL? {
        var data: Data?
        var ext = "png"
        if let png = pb.data(forType: .png) {
            data = png
        } else if let jpg = pb.data(forType: jpeg) {
            data = jpg
            ext = "jpg"
        } else if let tiff = pb.data(forType: .tiff) {
            data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        }
        guard let data else { return nil }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'à' HH.mm.ss"
        let url = freshFolder().appendingPathComponent("Image \(formatter.string(from: Date())).\(ext)")
        do {
            try data.write(to: url)
            return url
        } catch {
            return nil
        }
    }
}

// MARK: - Zone qui accepte qu'on dépose des choses

class DropTargetView: NSView {
    var onEnter: (() -> Void)?
    var onHighlight: ((Bool) -> Void)?
    var onDrop: ((NSPasteboard) -> Bool)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes(DropReader.acceptedTypes)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func operation(for info: NSDraggingInfo) -> NSDragOperation {
        // On ne redépose pas sur l'étagère ce qui en sort.
        if info.draggingSource is EntryRowView { return [] }
        return info.draggingSourceOperationMask.contains(.copy) ? .copy : .generic
    }

    override func draggingEntered(_ info: NSDraggingInfo) -> NSDragOperation {
        let op = operation(for: info)
        guard op != [] else { return [] }
        onEnter?()
        onHighlight?(true)
        return op
    }

    override func draggingUpdated(_ info: NSDraggingInfo) -> NSDragOperation {
        operation(for: info)
    }

    override func draggingExited(_ info: NSDraggingInfo?) {
        onHighlight?(false)
    }

    override func performDragOperation(_ info: NSDraggingInfo) -> Bool {
        onHighlight?(false)
        return onDrop?(info.draggingPasteboard) ?? false
    }
}

// MARK: - Historique des copier-coller

final class ClipItem {
    struct Record: Codable {
        var id = UUID()
        var kind: String
        var value: String
        var pinned = false
        var date = Date()
    }

    var record: Record
    init(_ record: Record) { self.record = record }

    lazy var entry: ShelfEntry = ShelfEntry.make(kind: record.kind, value: record.value)
}

final class ClipboardStore {
    private(set) var items: [ClipItem] = []
    var onChange: (() -> Void)?

    private let maxUnpinned = 50
    private var lastChange = NSPasteboard.general.changeCount
    private var timer: Timer?

    static let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Etagere", isDirectory: true)
    static let imagesFolder = folder.appendingPathComponent("Copies", isDirectory: true)
    private static let saveFile = folder.appendingPathComponent("copies.json")

    /// Les gestionnaires de mots de passe marquent ce qu'ils copient avec ces types : on ne l'enregistre pas.
    private static let ignoredTypes: Set<String> = [
        "org.nspasteboard.ConcealedType",
        "org.nspasteboard.TransientType",
        "org.nspasteboard.AutoGeneratedType",
        "com.agilebits.onepassword",
    ]

    init() {
        try? FileManager.default.createDirectory(at: Self.imagesFolder, withIntermediateDirectories: true)
        load()
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.poll() }
    }

    /// Épinglés en haut, puis du plus récent au plus ancien.
    var sorted: [ClipItem] {
        items.sorted { a, b in
            a.record.pinned != b.record.pinned ? a.record.pinned : a.record.date > b.record.date
        }
    }

    var hasUnpinned: Bool { items.contains { !$0.record.pinned } }

    // MARK: Surveillance du presse-papiers

    private func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChange else { return }
        lastChange = pb.changeCount
        let types = Set((pb.types ?? []).map(\.rawValue))
        guard types.isDisjoint(with: Self.ignoredTypes) else { return }
        let entries = read(pb)
        guard !entries.isEmpty else { return }
        insert(entries.map { ClipItem.Record(kind: $0.stored.kind, value: $0.stored.value) })
    }

    private func read(_ pb: NSPasteboard) -> [ShelfEntry] {
        // Fichiers copiés dans le Finder
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            return urls.map { ShelfEntry(.file($0)) }
        }
        // Texte (avant les images : Word, Excel ou Pages ajoutent une image du texte copié)
        if let text = pb.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            if !text.contains(where: \.isWhitespace), let url = URL(string: text),
               let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) {
                return [ShelfEntry(.link(url))]
            }
            return [ShelfEntry(.text(text))]
        }
        if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL], let link = urls.first(where: { !$0.isFileURL }) {
            return [ShelfEntry(.link(link))]
        }
        // Image seule (capture d'écran, « Copier l'image »…)
        if let file = saveImage(from: pb) {
            return [ShelfEntry(.file(file))]
        }
        return []
    }

    private func saveImage(from pb: NSPasteboard) -> URL? {
        let data: Data?
        if let png = pb.data(forType: .png) {
            data = png
        } else if let tiff = pb.data(forType: .tiff) {
            data = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
        } else {
            data = nil
        }
        guard let data else { return nil }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'à' HH.mm.ss"
        let url = Self.imagesFolder.appendingPathComponent("Image \(formatter.string(from: Date())).png")
        return (try? data.write(to: url)) != nil ? url : nil
    }

    // MARK: Modifications

    private func insert(_ records: [ClipItem.Record]) {
        for var record in records {
            // Déjà dans l'historique : on le remonte en haut au lieu de le dupliquer.
            if let i = items.firstIndex(where: { $0.record.kind == record.kind && $0.record.value == record.value }) {
                record.pinned = items[i].record.pinned
                record.id = items[i].record.id
                items.remove(at: i)
            }
            items.append(ClipItem(record))
        }
        trim()
        changed()
    }

    private func trim() {
        let unpinned = items.filter { !$0.record.pinned }.sorted { $0.record.date > $1.record.date }
        for old in unpinned.dropFirst(maxUnpinned) { delete(old, notify: false) }
    }

    /// Remet l'élément dans le presse-papiers : il n'y a plus qu'à faire ⌘V.
    func copy(_ item: ClipItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([item.entry.pasteboardWriter()])
    }

    func togglePin(_ item: ClipItem) {
        item.record.pinned.toggle()
        trim()
        changed()
    }

    func delete(_ item: ClipItem, notify: Bool = true) {
        items.removeAll { $0 === item }
        if item.record.kind == "file", item.record.value.hasPrefix(Self.imagesFolder.path) {
            try? FileManager.default.removeItem(atPath: item.record.value)
        }
        if notify { changed() }
    }

    func clearUnpinned() {
        items.filter { !$0.record.pinned }.forEach { delete($0, notify: false) }
        changed()
    }

    // MARK: Sauvegarde

    private func changed() {
        save()
        onChange?()
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items.map(\.record)) else { return }
        try? data.write(to: Self.saveFile, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.saveFile),
              let records = try? JSONDecoder().decode([ClipItem.Record].self, from: data) else { return }
        // Un fichier supprimé entre-temps n'a plus rien à faire dans l'historique.
        items = records
            .filter { $0.kind != "file" || FileManager.default.fileExists(atPath: $0.value) }
            .map(ClipItem.init)
    }
}

// MARK: - Une ligne (étagère ou historique), qu'on peut faire glisser vers une autre app

class EntryRowView: NSView, NSDraggingSource {
    let entries: [ShelfEntry]
    private let accent: Bool
    private var mouseDownPoint: NSPoint?
    private var didDrag = false
    let subtitleLabel: NSTextField
    let buttons = NSStackView()
    private(set) var hovering = false {
        didSet { updateAppearance() }
    }

    init(entries: [ShelfEntry], title: String, subtitle: String, icon: NSImage,
         iconSide: CGFloat = 32, height: CGFloat = 44, accent: Bool = false) {
        self.entries = entries
        self.accent = accent
        subtitleLabel = NSTextField(labelWithString: subtitle)
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        translatesAutoresizingMaskIntoConstraints = false

        let imageView = NSImageView(image: icon)
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .systemFont(ofSize: 13, weight: accent ? .semibold : .regular)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        subtitleLabel.font = .systemFont(ofSize: 11)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.lineBreakMode = .byTruncatingTail
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let labels = NSStackView(views: [titleLabel, subtitleLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1
        labels.translatesAutoresizingMaskIntoConstraints = false

        buttons.orientation = .horizontal
        buttons.spacing = 6
        buttons.translatesAutoresizingMaskIntoConstraints = false

        addSubview(imageView)
        addSubview(labels)
        addSubview(buttons)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: height),
            imageView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalToConstant: iconSide),
            imageView.heightAnchor.constraint(equalToConstant: iconSide),
            labels.leadingAnchor.constraint(equalTo: imageView.trailingAnchor, constant: 10),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -6),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            buttons.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        updateAppearance()
    }

    required init?(coder: NSCoder) { fatalError() }

    func addButton(_ symbol: String, tip: String, action: Selector) -> NSButton {
        let b = NSButton()
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        b.isBordered = false
        b.contentTintColor = .tertiaryLabelColor
        b.toolTip = tip
        b.target = self
        b.action = action
        b.widthAnchor.constraint(equalToConstant: 16).isActive = true
        b.heightAnchor.constraint(equalToConstant: 16).isActive = true
        buttons.addArrangedSubview(b)
        return b
    }

    // À personnaliser dans les sous-classes
    func hoverChanged() {}
    func clicked() {}
    func doubleClicked() {}
    func draggedOut() {}

    private func updateAppearance() {
        hoverChanged()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let color: NSColor
            if accent {
                color = Canyon.terre.withAlphaComponent(hovering ? 0.22 : 0.14)
            } else {
                color = hovering ? NSColor.labelColor.withAlphaComponent(0.08) : .clear
            }
            layer?.backgroundColor = color.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Sans ça, tirer une ligne déplace toute la fenêtre au lieu de prendre l'élément.
    override var mouseDownCanMoveWindow: Bool { false }

    // Toute la ligne réagit au clic (sauf ses petits boutons), même sur l'icône ou le texte.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        return hit is NSButton ? hit : self
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownPoint = event.locationInWindow
        didDrag = false
    }

    override func mouseUp(with event: NSEvent) {
        defer { mouseDownPoint = nil }
        guard !didDrag else { return }
        if event.clickCount == 2 { doubleClicked() } else if event.clickCount == 1 { clicked() }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = mouseDownPoint, !didDrag else { return }
        let p = event.locationInWindow
        guard hypot(p.x - start.x, p.y - start.y) > 4 else { return }
        didDrag = true

        let local = convert(p, from: nil)
        let items: [NSDraggingItem] = entries.enumerated().map { i, entry in
            let item = NSDraggingItem(pasteboardWriter: entry.pasteboardWriter())
            let off = CGFloat(min(i, 4)) * 4
            item.setDraggingFrame(NSRect(x: local.x - 20 + off, y: local.y - 20 - off, width: 40, height: 40),
                                  contents: entry.icon)
            return item
        }
        let session = beginDraggingSession(with: items, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
        session.draggingFormation = .pile
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        context == .outsideApplication ? [.copy, .move, .generic] : []
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        guard operation != [] else { return }
        DispatchQueue.main.async { [weak self] in self?.draggedOut() }
    }

    func copyToPasteboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects(entries.map { $0.pasteboardWriter() })
    }
}

// MARK: - Ligne de l'étagère

final class ItemRow: EntryRowView {
    private let isGroup: Bool
    private weak var shelf: ShelfController?
    private var removeButton: NSButton?

    init(entries: [ShelfEntry], isGroup: Bool, shelf: ShelfController) {
        self.isGroup = isGroup
        self.shelf = shelf
        super.init(entries: entries,
                   title: isGroup ? "Tout glisser" : entries[0].title,
                   subtitle: isGroup ? "\(entries.count) éléments" : entries[0].subtitle,
                   icon: isGroup ? Icons.stacked(entries.map(\.icon)) : entries[0].icon,
                   iconSide: isGroup ? 40 : 32, height: isGroup ? 52 : 44, accent: isGroup)
        if !isGroup {
            removeButton = addButton("xmark.circle.fill", tip: "Retirer de l'étagère", action: #selector(removeClicked))
        }
        hoverChanged()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hoverChanged() { removeButton?.isHidden = !hovering }
    override func doubleClicked() { if !isGroup { entries[0].open() } }
    override func draggedOut() { shelf?.remove(entries, draggedOut: true) }

    @objc private func removeClicked() { shelf?.remove(entries, draggedOut: false) }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func item(_ title: String, _ action: Selector) {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        item(isGroup ? "Tout copier" : "Copier", #selector(copyClicked))
        if !isGroup {
            item("Ouvrir", #selector(openClicked))
            if case .file = entries[0].kind { item("Afficher dans le Finder", #selector(revealClicked)) }
        }
        menu.addItem(.separator())
        item(isGroup ? "Vider l'étagère" : "Retirer de l'étagère", #selector(removeClicked))
        return menu
    }

    @objc private func copyClicked() { copyToPasteboard() }
    @objc private func openClicked() { entries[0].open() }

    @objc private func revealClicked() {
        if case .file(let url) = entries[0].kind { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }
}

// MARK: - Ligne de l'historique des copies

final class ClipRow: EntryRowView {
    private let item: ClipItem
    private let store: ClipboardStore
    private weak var shelf: ShelfController?
    private var pinButton: NSButton!
    private var removeButton: NSButton!

    private static let relative: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "fr_FR")
        f.unitsStyle = .short
        return f
    }()

    init(item: ClipItem, store: ClipboardStore, shelf: ShelfController) {
        self.item = item
        self.store = store
        self.shelf = shelf
        let when = Self.relative.localizedString(for: item.record.date, relativeTo: Date())
        super.init(entries: [item.entry], title: item.entry.title,
                   subtitle: "\(item.entry.subtitle) · \(when)", icon: item.entry.icon)
        pinButton = addButton(item.record.pinned ? "pin.fill" : "pin",
                              tip: item.record.pinned ? "Désépingler" : "Épingler (le garder pour toujours)",
                              action: #selector(pinClicked))
        if item.record.pinned { pinButton.contentTintColor = Canyon.terre }
        removeButton = addButton("xmark.circle.fill", tip: "Supprimer de l'historique", action: #selector(deleteClicked))
        if case .text(let s) = item.entry.kind { toolTip = String(s.prefix(600)) }
        hoverChanged()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func hoverChanged() {
        guard pinButton != nil else { return }
        pinButton.isHidden = !hovering && !item.record.pinned
        removeButton.isHidden = !hovering
    }

    /// Un clic recopie l'élément puis ferme la fenêtre : il n'y a plus qu'à faire ⌘V.
    override func clicked() {
        store.copy(item)
        subtitleLabel.stringValue = "Copié, fais ⌘V pour coller"
        subtitleLabel.textColor = Canyon.ocre
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak shelf] in shelf?.hide() }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        menu.autoenablesItems = false
        func add(_ title: String, _ action: Selector) {
            menu.addItem(withTitle: title, action: action, keyEquivalent: "").target = self
        }
        add("Copier", #selector(copyClicked))
        add(item.record.pinned ? "Désépingler" : "Épingler", #selector(pinClicked))
        add("Poser sur l'étagère", #selector(shelveClicked))
        if case .file = item.entry.kind { add("Ouvrir", #selector(openClicked)) }
        if case .link = item.entry.kind { add("Ouvrir", #selector(openClicked)) }
        menu.addItem(.separator())
        add("Supprimer", #selector(deleteClicked))
        return menu
    }

    @objc private func copyClicked() { store.copy(item) }
    @objc private func pinClicked() { store.togglePin(item) }
    @objc private func deleteClicked() { store.delete(item) }
    @objc private func openClicked() { item.entry.open() }

    @objc private func shelveClicked() {
        let stored = item.entry.stored
        shelf?.add([ShelfEntry.make(kind: stored.kind, value: stored.value)])
    }
}

// MARK: - Zone vide en pointillés

final class EmptyDropView: NSView {
    var highlighted = false {
        didSet { needsDisplay = true }
    }
    private let dashed: Bool

    init(symbol: String, message: String, dashed: Bool) {
        self.dashed = dashed
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let icon = NSImageView(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil)!)
        icon.symbolConfiguration = .init(pointSize: 26, weight: .light)
        icon.contentTintColor = .secondaryLabelColor

        let label = NSTextField(wrappingLabelWithString: message)
        label.alignment = .center
        label.font = .systemFont(ofSize: 12)
        label.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [icon, label])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 120),
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        guard dashed else { return }
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 10, yRadius: 10)
        path.lineWidth = 1.5
        path.setLineDash([6, 4], count: 2, phase: 0)
        if highlighted {
            Canyon.terre.withAlphaComponent(0.12).setFill()
            path.fill()
            Canyon.terre.setStroke()
        } else {
            NSColor.tertiaryLabelColor.setStroke()
        }
        path.stroke()
    }
}

// MARK: - La fenêtre flottante

final class ShelfPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override func cancelOperation(_ sender: Any?) { orderOut(nil) }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// Une liste qui défile, et dont la hauteur suit le nombre de lignes.
final class RowList {
    let scrollView = NSScrollView()
    let stack = NSStackView()
    let height: NSLayoutConstraint
    private let rowHeight: CGFloat = 44
    private let spacing: CGFloat = 2

    init() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false

        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)

        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.documentView = document
        scrollView.contentView.drawsBackground = false

        let clip = scrollView.contentView
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            document.topAnchor.constraint(equalTo: clip.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        height = scrollView.heightAnchor.constraint(equalToConstant: 0)
        height.isActive = true
    }

    func setRows(_ rows: [NSView], maxVisible: Int) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for row in rows {
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        let visible = CGFloat(min(rows.count, maxVisible))
        height.constant = visible * rowHeight + max(visible - 1, 0) * spacing
    }
}

final class ShelfController: NSObject {
    enum Mode: Int { case shelf, clips }

    private(set) var entries: [ShelfEntry] = []
    private(set) var mode: Mode = .shelf
    var anchorRect: (() -> NSRect?)?

    private let width: CGFloat = 300
    private let store: ClipboardStore

    let panel: ShelfPanel
    private let root = DropTargetView(frame: .zero)
    private let tabs = NSSegmentedControl(labels: ["Étagère", "Copiés"], trackingMode: .selectOne, target: nil, action: nil)
    private let countLabel = NSTextField(labelWithString: "")
    private var clearButton: NSButton!
    private let emptyView = EmptyDropView(symbol: "tray.and.arrow.down",
                                          message: "Glisse ici des fichiers,\ndu texte, des images ou des liens",
                                          dashed: true)
    private let clipsEmptyView = EmptyDropView(symbol: "doc.on.clipboard",
                                               message: "Tout ce que tu copies avec ⌘C\napparaîtra ici",
                                               dashed: false)
    private let groupHolder = NSView()
    private let shelfList = RowList()
    private let clipList = RowList()

    init(store: ClipboardStore) {
        self.store = store
        panel = ShelfPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
                           styleMask: [.borderless, .nonactivatingPanel],
                           backing: .buffered, defer: false)
        super.init()
        configurePanel()
        buildContent()
        store.onChange = { [weak self] in self?.reload() }
        reload()
    }

    private func configurePanel() {
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true

        let effect = NSVisualEffectView()
        effect.appearance = NSAppearance(named: .darkAqua)   // ambiance canyon : sombre et chaud
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = Self.roundedMask(radius: 14)
        panel.contentView = effect

        root.translatesAutoresizingMaskIntoConstraints = false
        root.wantsLayer = true
        root.layer?.cornerRadius = 14
        effect.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            root.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            root.topAnchor.constraint(equalTo: effect.topAnchor),
            root.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])

        root.onEnter = { [weak self] in self?.setMode(.shelf) }
        root.onHighlight = { [weak self] on in self?.setHighlighted(on) }
        root.onDrop = { [weak self] pb in
            DropReader.read(pb) { self?.add($0) }
        }
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let side = radius * 2 + 1
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }

    private func headerButton(_ symbol: String, tip: String, action: Selector) -> NSButton {
        let b = NSButton()
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        b.isBordered = false
        b.contentTintColor = .secondaryLabelColor
        b.toolTip = tip
        b.target = self
        b.action = action
        return b
    }

    private func buildContent() {
        tabs.controlSize = .small
        tabs.selectedSegment = 0
        tabs.target = self
        tabs.action = #selector(tabChanged)
        countLabel.font = .systemFont(ofSize: 12)
        countLabel.textColor = .secondaryLabelColor

        clearButton = headerButton("trash", tip: "Vider", action: #selector(clearClicked))
        let close = headerButton("xmark", tip: "Fermer", action: #selector(closeClicked))
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let header = NSStackView(views: [tabs, countLabel, spacer, clearButton, close])
        header.orientation = .horizontal
        header.spacing = 8

        groupHolder.translatesAutoresizingMaskIntoConstraints = false

        let content = NSStackView(views: [header, emptyView, groupHolder, shelfList.scrollView,
                                          clipsEmptyView, clipList.scrollView])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 8
        content.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            content.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            content.topAnchor.constraint(equalTo: root.topAnchor, constant: 10),
            header.heightAnchor.constraint(equalToConstant: 22),
        ])
        for view in content.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: content.widthAnchor).isActive = true
        }
    }

    private func setHighlighted(_ on: Bool) {
        emptyView.highlighted = on
        root.layer?.borderWidth = on && !entries.isEmpty ? 2 : 0
        root.layer?.borderColor = Canyon.terre.cgColor
    }

    // MARK: Contenu de l'étagère

    func add(_ new: [ShelfEntry]) {
        let fresh = new.filter { n in !entries.contains { $0.isSameFile(as: n) } }
        entries.append(contentsOf: fresh)
        mode = .shelf
        reload()
        show()
    }

    func remove(_ gone: [ShelfEntry], draggedOut: Bool) {
        let ids = Set(gone.map(\.id))
        entries.removeAll { ids.contains($0.id) }
        reload()
        if entries.isEmpty && draggedOut {
            panel.orderOut(nil)
        }
    }

    @objc func clearClicked() {
        switch mode {
        case .shelf:
            entries.removeAll()
            reload()
        case .clips:
            store.clearUnpinned()
        }
    }

    func clearShelf() {
        entries.removeAll()
        reload()
    }

    @objc private func closeClicked() { hide() }

    @objc private func tabChanged() {
        setMode(Mode(rawValue: tabs.selectedSegment) ?? .shelf)
    }

    func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        mode = newMode
        reload()
    }

    private func reload() {
        tabs.selectedSegment = mode.rawValue
        let onShelf = mode == .shelf
        let count = entries.count
        let clips = store.sorted

        // Étagère : ligne « Tout glisser » dès deux éléments, puis une ligne par élément (le plus récent en haut)
        groupHolder.subviews.forEach { $0.removeFromSuperview() }
        if count >= 2 {
            let group = ItemRow(entries: entries, isGroup: true, shelf: self)
            groupHolder.addSubview(group)
            NSLayoutConstraint.activate([
                group.leadingAnchor.constraint(equalTo: groupHolder.leadingAnchor),
                group.trailingAnchor.constraint(equalTo: groupHolder.trailingAnchor),
                group.topAnchor.constraint(equalTo: groupHolder.topAnchor),
                group.bottomAnchor.constraint(equalTo: groupHolder.bottomAnchor),
            ])
        }
        shelfList.setRows(entries.reversed().map { ItemRow(entries: [$0], isGroup: false, shelf: self) }, maxVisible: 6)

        // Historique : épinglés en haut, puis les plus récents
        if !onShelf || panel.isVisible {
            clipList.setRows(clips.map { ClipRow(item: $0, store: store, shelf: self) }, maxVisible: 8)
        }

        emptyView.isHidden = !onShelf || count > 0
        groupHolder.isHidden = !onShelf || count < 2
        shelfList.scrollView.isHidden = !onShelf || count == 0
        clipsEmptyView.isHidden = onShelf || !clips.isEmpty
        clipList.scrollView.isHidden = onShelf || clips.isEmpty

        let shown = onShelf ? count : clips.count
        countLabel.stringValue = shown == 0 ? "" : "\(shown)"
        clearButton.isHidden = onShelf ? count == 0 : !store.hasUnpinned
        clearButton.toolTip = onShelf ? "Vider l'étagère" : "Effacer l'historique (sauf les épinglés)"

        resizePanel()
    }

    private func resizePanel() {
        var height: CGFloat = 10 + 22 + 8
        switch mode {
        case .shelf:
            if entries.isEmpty {
                height += 120
            } else {
                if entries.count >= 2 { height += 52 + 8 }
                height += shelfList.height.constant
            }
        case .clips:
            height += store.items.isEmpty ? 120 : clipList.height.constant
        }
        height += 10

        var frame = panel.frame
        let top = frame.maxY
        frame.size = NSSize(width: width, height: height)
        frame.origin.y = top - height
        panel.setFrame(frame, display: true, animate: false)
    }

    // MARK: Afficher / cacher

    func toggle() {
        panel.isVisible ? hide() : show()
    }

    func show(_ newMode: Mode? = nil) {
        if let newMode { mode = newMode }
        let wasVisible = panel.isVisible
        reload()
        if !wasVisible { placeUnderMenuBarIcon() }
        panel.orderFrontRegardless()
        panel.makeKey()
    }

    func hide() {
        panel.orderOut(nil)
    }

    private func placeUnderMenuBarIcon() {
        let size = panel.frame.size
        let anchor = anchorRect?()
        let screen = anchor.flatMap { r in NSScreen.screens.first { $0.frame.intersects(r) } } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let midX = anchor?.midX ?? visible.maxX - size.width / 2 - 8
        let x = min(max(midX - size.width / 2, visible.minX + 8), visible.maxX - size.width - 8)
        panel.setFrameOrigin(NSPoint(x: x, y: visible.maxY - size.height - 6))
    }
}

// MARK: - L'icône dans la barre de menus

final class StatusIconView: DropTargetView {
    var onClick: (() -> Void)?
    var onMenu: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { onMenu?() } else { onClick?() }
    }

    override func rightMouseDown(with event: NSEvent) {
        onMenu?()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let store = ClipboardStore()
    private lazy var shelf = ShelfController(store: store)

    func applicationDidFinishLaunching(_ notification: Notification) {
        DropReader.clearCache()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        let image = NSImage(systemSymbolName: "tray.and.arrow.down", accessibilityDescription: "Étagère")
        image?.isTemplate = true
        button.image = image

        // Une vue transparente par-dessus le bouton : clic = ouvrir, et on peut y déposer directement.
        let overlay = StatusIconView(frame: button.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.onClick = { [weak self] in self?.shelf.toggle() }
        overlay.onMenu = { [weak self] in self?.showMenu() }
        overlay.onEnter = { [weak self] in self?.shelf.show(.shelf) }
        overlay.onHighlight = { on in button.highlight(on) }
        overlay.onDrop = { [weak self] pb in
            DropReader.read(pb) { self?.shelf.add($0) }
        }
        button.addSubview(overlay)

        shelf.anchorRect = {
            guard let window = button.window else { return nil }
            return window.convertToScreen(button.convert(button.bounds, to: nil))
        }

    }

    private func showMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(withTitle: "Ouvrir l'étagère", action: #selector(openShelf), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Mes copier-coller", action: #selector(openClips), keyEquivalent: "").target = self
        let clear = menu.addItem(withTitle: "Vider l'étagère", action: #selector(clearShelf), keyEquivalent: "")
        clear.target = self
        clear.isEnabled = !shelf.entries.isEmpty
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quitter Étagère", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openShelf() { shelf.show(.shelf) }
    @objc private func openClips() { shelf.show(.clips) }
    @objc private func clearShelf() { shelf.clearShelf() }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
