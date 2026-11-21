import AppKit
import SwiftUI

// Fait le bilan des mails importants : lit toutes les boîtes de l'app Mail
// (AppleScript), puis demande à Claude Code (claude -p) de trier par catégories.
// Les scripts et la consigne sont copiés dans ~/.local/share/bilanmails par build.sh.

let dossier = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".local/share/bilanmails")
let claudePath = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".local/bin/claude").path
let fichierBilan = dossier.appendingPathComponent("dernier-bilan.md")


enum Periode: Int, CaseIterable, Identifiable {
    case jour = 24, troisJours = 72, semaine = 168
    var id: Int { rawValue }
    var nom: String {
        switch self {
        case .jour: return "24 h"
        case .troisJours: return "3 jours"
        case .semaine: return "7 jours"
        }
    }
}

final class Bilan: ObservableObject {
    enum Etat: Equatable { case attente, lecture, tri(Int), fini, erreur(String) }

    @Published var etat = Etat.attente
    @Published var texte = ""
    @Published var date: Date?
    @Published var secondes = 0
    @Published var periode = Periode.troisJours

    private var process: Process?
    private var timer: Timer?

    var enCours: Bool {
        switch etat { case .lecture, .tri: return true; default: return false }
    }

    init() {
        if let t = try? String(contentsOf: fichierBilan, encoding: .utf8) {
            texte = t
            date = (try? FileManager.default.attributesOfItem(atPath: fichierBilan.path))?[.modificationDate] as? Date
            etat = .fini
        }
    }

    func lancer() {
        guard !enCours else { return }
        let heures = periode.rawValue
        etat = .lecture
        secondes = 0
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.secondes += 1 }

        DispatchQueue.global(qos: .userInitiated).async {
            // 1. la liste des mails, via l'app Mail
            let entetes = self.executer("/usr/bin/osascript",
                                        [dossier.appendingPathComponent("entetes.applescript").path, String(heures)])
            guard entetes.code == 0 else {
                return self.echec("Je n'arrive pas à lire Mail. Vérifie dans Réglages Système > Confidentialité > Automatisation que Bilan Mails peut contrôler Mail.\n\n\(entetes.erreur)")
            }
            let lignes = entetes.sortie.split(separator: "\n").filter { $0.contains(" | ") }
            let unique = Array(NSOrderedSet(array: lignes.map(String.init))) as! [String]
            DispatchQueue.main.async { self.etat = .tri(unique.count) }

            // 2. Claude trie et lit les mails qui comptent
            let corps = dossier.appendingPathComponent("corps.applescript").path
            let consigne = ((try? String(contentsOf: dossier.appendingPathComponent("consigne.md"), encoding: .utf8)) ?? "")
                .replacingOccurrences(of: "__CORPS__", with: corps)
                .replacingOccurrences(of: "__HEURES__", with: String(heures))
            let f = DateFormatter(); f.locale = Locale(identifier: "fr_FR"); f.dateFormat = "EEEE d MMMM yyyy 'à' HH:mm"
            let message = consigne + "\n\nNous sommes le \(f.string(from: Date())). Période : les \(heures) dernières heures.\n\nLISTE DES MAILS :\n" + unique.joined(separator: "\n")

            let res = self.executer(claudePath, [
                "-p", "--output-format", "text",
                "--allowedTools", "Bash(osascript \(corps):*)", "Bash(osascript \(corps) *)",
            ], entree: message)
            let bilan = res.sortie.trimmingCharacters(in: .whitespacesAndNewlines)
            guard res.code == 0, !bilan.isEmpty else {
                return self.echec(res.code == 15 ? "Bilan arrêté." : "Claude n'a pas pu faire le bilan.\n\n\(res.erreur.isEmpty ? bilan : res.erreur)")
            }
            try? bilan.write(to: fichierBilan, atomically: true, encoding: .utf8)
            DispatchQueue.main.async {
                self.timer?.invalidate()
                self.texte = bilan
                self.date = Date()
                self.etat = .fini
            }
        }
    }

    func arreter() { process?.terminate() }

    private func echec(_ msg: String) {
        DispatchQueue.main.async {
            self.timer?.invalidate()
            self.etat = .erreur(msg)
        }
    }

    private func executer(_ chemin: String, _ args: [String], entree: String? = nil) -> (code: Int32, sortie: String, erreur: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: chemin)
        p.arguments = args
        p.currentDirectoryURL = dossier
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "\(FileManager.default.homeDirectoryForCurrentUser.path)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        p.environment = env
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out; p.standardError = err; p.standardInput = inp
        var dataOut = Data(), dataErr = Data()
        let groupe = DispatchGroup()
        groupe.enter(); DispatchQueue.global().async { dataOut = out.fileHandleForReading.readDataToEndOfFile(); groupe.leave() }
        groupe.enter(); DispatchQueue.global().async { dataErr = err.fileHandleForReading.readDataToEndOfFile(); groupe.leave() }
        do { try p.run() } catch { return (-1, "", error.localizedDescription) }
        process = p
        if let e = entree { inp.fileHandleForWriting.write(e.data(using: .utf8)!) }
        try? inp.fileHandleForWriting.close()
        p.waitUntilExit()
        groupe.wait()
        process = nil
        return (p.terminationStatus, String(decoding: dataOut, as: UTF8.self), String(decoding: dataErr, as: UTF8.self))
    }
}

// MARK: affichage du bilan (Markdown simple : ## titres et - puces)

struct Section: Identifiable {
    let id = UUID()
    var titre: String
    var lignes: [String] = []
}

func decouper(_ texte: String) -> [Section] {
    var sections: [Section] = []
    for brut in texte.components(separatedBy: "\n") {
        let l = brut.trimmingCharacters(in: .whitespaces)
        if l.isEmpty { continue }
        if l.hasPrefix("#") {
            sections.append(Section(titre: sansEmoji(l.trimmingCharacters(in: CharacterSet(charactersIn: "# ")))))
        } else {
            if sections.isEmpty { sections.append(Section(titre: "")) }
            var t = l
            for p in ["- ", "* ", "• "] where t.hasPrefix(p) { t.removeFirst(p.count) }
            sections[sections.count - 1].lignes.append(sansEmoji(t.replacingOccurrences(of: "👉", with: "→")))
        }
    }
    return sections
}

// les anciens bilans ont des emojis : on les retire, le style passe par la couleur
func sansEmoji(_ s: String) -> String {
    let garde = s.unicodeScalars.filter { u in
        u.value != 0xFE0F && !(u.properties.isEmoji && u.value >= 0x2190 && u != "→")
    }
    return String(String.UnicodeScalarView(garde)).replacingOccurrences(of: "  ", with: " ").trimmingCharacters(in: .whitespaces)
}

// couleur de la légende selon la section
func teinte(_ titre: String) -> Color {
    let t = titre.lowercased()
    if t.contains("vite") || t.contains("arnaque") || t.contains("erreur") { return .terre }
    if t.contains("pas important") || t.contains("rien") { return .sable.opacity(0.55) }
    return .ocre
}

func enrichi(_ s: String) -> AttributedString {
    (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
}

struct ContentView: View {
    @ObservedObject var bilan: Bilan

    var body: some View {
        ZStack {
            FondCanyon()
            VStack(spacing: 14) {
                header
                controles
                contenu
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22)
            .padding(.top, 34)
            .padding(.bottom, 20)
        }
        .frame(width: 480, height: 700)
        .foregroundStyle(Color.sable)
        .tint(.terre)
        .preferredColorScheme(.dark)
        .animation(.spring(duration: 0.4), value: bilan.etat)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 1) {
                Text("Bilan Mails").font(.system(size: 20, weight: .semibold)).tracking(-0.2)
                Text(sousTitre).font(.subheadline).foregroundStyle(Color.sable.opacity(0.6))
            }
            Spacer()
            if case .fini = bilan.etat {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(bilan.texte, forType: .string)
                } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.glass).tint(nil as Color?)
                .help("Copier le bilan")
            }
        }
    }

    private var sousTitre: String {
        switch bilan.etat {
        case .attente: return "Toutes tes boîtes, triées par Claude"
        case .lecture: return "Je lis tes boîtes dans Mail…"
        case .tri(let n): return "Claude trie \(n) mails…"
        case .erreur: return "Oups"
        case .fini:
            guard let d = bilan.date else { return "Prêt" }
            let f = RelativeDateTimeFormatter(); f.locale = Locale(identifier: "fr_FR")
            return "Bilan fait \(f.localizedString(for: d, relativeTo: Date()))"
        }
    }

    private var controles: some View {
        HStack(spacing: 10) {
            Picker("", selection: $bilan.periode) {
                ForEach(Periode.allCases) { Text($0.nom).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(bilan.enCours)
            .frame(width: 210)
            Spacer()
            if bilan.enCours {
                Button("Arrêter") { bilan.arreter() }
                    .buttonStyle(.glass)
            } else {
                Button { bilan.lancer() } label: {
                    Text("Faire le bilan").fontWeight(.medium).padding(.horizontal, 8)
                }
                .buttonStyle(.glassProminent).tint(.terre)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    @ViewBuilder private var contenu: some View {
        switch bilan.etat {
        case .attente:
            carte {
                Text("Clique sur « Faire le bilan ». Je lis toutes tes boîtes, puis Claude te dit ce qui compte, rangé par catégories.")
                    .foregroundStyle(Color.sable.opacity(0.7))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .lecture, .tri:
            carte {
                HStack(spacing: 14) {
                    ProgressView().controlSize(.regular).tint(.ocre)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(etapeTexte).font(.body.weight(.medium))
                        Text("\(bilan.secondes) s · compte une à deux minutes").font(.caption).foregroundStyle(Color.sable.opacity(0.55))
                    }
                    Spacer()
                }
            }
        case .erreur(let msg):
            carte {
                Text(msg).font(.callout).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        case .fini:
            ScrollView {
                VStack(spacing: 12) {
                    ForEach(decouper(bilan.texte)) { s in
                        carte {
                            VStack(alignment: .leading, spacing: 10) {
                                if !s.titre.isEmpty {
                                    Legende(s.titre, couleur: teinte(s.titre))
                                }
                                ForEach(Array(s.lignes.enumerated()), id: \.offset) { _, l in
                                    Text(enrichi(l))
                                        .font(.callout).lineSpacing(2)
                                        .foregroundStyle(Color.sable.opacity(0.9))
                                        .fixedSize(horizontal: false, vertical: true)
                                        .textSelection(.enabled)
                                }
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
            .scrollIndicators(.never)
        }
    }

    private var etapeTexte: String {
        if case .tri(let n) = bilan.etat { return "Claude lit les \(n) mails et garde l'important" }
        return "Lecture de toutes tes boîtes dans Mail"
    }

    private func carte<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        c()
            .padding(18)
            .glassEffect(.regular.tint(Color.ombre.opacity(0.45)), in: .rect(cornerRadius: 22))
    }
}

// Icône dans la barre des menus (comme Test Visio) : clic = ouvrir/fermer, clic droit = menu
final class StatusIconView: NSView {
    var onClick: (() -> Void)?
    var onMenu: (() -> Void)?
    override func mouseDown(with event: NSEvent) {
        if event.modifierFlags.contains(.control) { onMenu?() } else { onClick?() }
    }
    override func rightMouseDown(with event: NSEvent) { onMenu?() }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let bilan = Bilan()
    var window: NSWindow!
    private var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ n: Notification) {
        window = NSWindow(contentRect: .zero,
                          styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "Bilan Mails"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.contentView = NSHostingView(rootView: ContentView(bilan: bilan))
        window.isReleasedWhenClosed = false
        window.delegate = self

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem.button else { return }
        let image = NSImage(systemSymbolName: "envelope.badge", accessibilityDescription: "Bilan Mails")
        image?.isTemplate = true
        button.image = image
        let overlay = StatusIconView(frame: button.bounds)
        overlay.autoresizingMask = [.width, .height]
        overlay.onClick = { [weak self] in self?.toggle() }
        overlay.onMenu = { [weak self] in self?.showMenu() }
        button.addSubview(overlay)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.showWindow() }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(); return true
    }

    private func toggle() {
        if window.isVisible && NSApp.isActive { window.orderOut(nil) } else { showWindow() }
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

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Ouvrir Bilan Mails", action: #selector(openWindow), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Faire le bilan", action: #selector(run), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quitter Bilan Mails", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }
    @objc private func openWindow() { showWindow() }
    @objc private func run() { showWindow(); bilan.lancer() }
    func applicationWillTerminate(_ n: Notification) { bilan.arreter() }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
