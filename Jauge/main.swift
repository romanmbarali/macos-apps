import AppKit
import SwiftUI
import Darwin

// Jauge : l'état du Mac en un mot. RAM d'abord (pression + swap), puis processeur et chaleur,
// et qui mange quoi, avec un bouton pour quitter le coupable.
// Build : ./build.sh (compile avec ../Canyon/Canyon.swift, installe dans ~/Applications)

// MARK: - Lecture du système

func sysctlInt(_ nom: String) -> Int {
    var v: Int32 = 0; var taille = MemoryLayout<Int32>.size
    return sysctlbyname(nom, &v, &taille, nil, 0) == 0 ? Int(v) : 0
}

func swap() -> (utilise: Double, total: Double) {
    var x = xsw_usage(); var taille = MemoryLayout<xsw_usage>.size
    guard sysctlbyname("vm.swapusage", &x, &taille, nil, 0) == 0 else { return (0, 0) }
    return (Double(x.xsu_used), Double(x.xsu_total))
}

// mémoire utilisée façon Moniteur d'activité : mémoire des apps + câblée + compressée
func ramUtilisee() -> Double {
    var s = vm_statistics64()
    var n = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
    let r = withUnsafeMutablePointer(to: &s) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &n) }
    }
    guard r == KERN_SUCCESS else { return 0 }
    let pages = Double(s.internal_page_count) - Double(s.purgeable_count) + Double(s.wire_count) + Double(s.compressor_page_count)
    return pages * Double(vm_kernel_page_size)
}

func ticksProcesseur() -> (occupe: Double, total: Double) {
    var info = host_cpu_load_info()
    var n = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
    let r = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &n) }
    }
    guard r == KERN_SUCCESS else { return (0, 0) }
    let t = info.cpu_ticks
    let occupe = Double(t.0) + Double(t.1) + Double(t.3)
    return (occupe, occupe + Double(t.2))
}

let timebase: Double = { var t = mach_timebase_info(); mach_timebase_info(&t); return Double(t.numer) / Double(t.denom) }()
let nbCoeurs = Double(ProcessInfo.processInfo.activeProcessorCount)
let ramTotale = Double(ProcessInfo.processInfo.physicalMemory)
let unGo = 1_073_741_824.0

// MARK: - Regroupement des processus par app

struct Groupe: Identifiable {
    var id: String { nom }
    let nom: String
    let chemin: String?          // le .app, s'il y en a un
    var ram: Double = 0          // octets
    var processeur: Double = 0   // part du Mac, en %
    var pids: [pid_t] = []
    var protege: Bool = false    // pas de bouton Quitter (système, Finder, Jauge…)
}

struct Identite { let nom: String; let chemin: String?; let protege: Bool }

let nomsProteges: Set<String> = ["Finder", "Dock", "loginwindow", "WindowServer", "SystemUIServer", "ControlCenter", "Jauge", "launchd"]

func identite(chemin: String) -> Identite {
    if let r = chemin.range(of: ".app/") ?? (chemin.hasSuffix(".app") ? chemin.range(of: ".app") : nil) {
        let app = String(chemin[..<r.upperBound]).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let complet = "/" + app
        let nom = (complet as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
        let systeme = complet.hasPrefix("/System/") && !complet.hasPrefix("/System/Applications/")
        return Identite(nom: nom, chemin: complet, protege: systeme || nomsProteges.contains(nom))
    }
    var nom = (chemin as NSString).lastPathComponent
    if chemin.contains("WebKit.WebContent") { nom = "Pages web (Safari)" }
    else if chemin.contains("/claude/versions/") || nom == "claude" { nom = "Claude Code" }
    else if nom.count > 18, nom.contains("-") { nom = String(nom.split(separator: "-")[0]) }   // ffmpeg-macos-aarch64-v9.0 → ffmpeg
    let systeme = ["/System/", "/usr/libexec/", "/usr/sbin/", "/sbin/", "/Library/Apple/"].contains { chemin.hasPrefix($0) }
    return Identite(nom: nom, chemin: nil, protege: systeme || nomsProteges.contains(nom))
}

// MARK: - L'état, relu toutes les 2 secondes

enum Niveau: Int { case roule = 0, chauffe = 1, leve = 2 }

final class Etat: ObservableObject {
    @Published var pressionNiveau = 1        // 1 normal, 2 alerte, 4 critique
    @Published var pression = 0.0            // 0…1
    @Published var ram = 0.0                 // octets
    @Published var swapUtilise = 0.0
    @Published var swapTotal = 0.0
    @Published var processeur = 0.0          // 0…1
    @Published var chaleur: ProcessInfo.ThermalState = .nominal
    @Published var parRam: [Groupe] = []
    @Published var parProcesseur: [Groupe] = []
    @Published var niveau: Niveau = .roule
    @Published var mot = "Ça roule"
    @Published var phrase = "Tout va bien. Rien à fermer."

    var auChangement: ((Niveau) -> Void)?
    private var dernierTicks = ticksProcesseur()
    private var historique: [Double] = []
    private var tempsPrecedents: [String: Double] = [:]   // "pid-début" → temps CPU en ns
    private var identites: [String: Identite] = [:]
    private var dernierInstant = DispatchTime.now().uptimeNanoseconds
    private var timer: Timer?

    func demarrer() {
        relire()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.relire() }
    }

    func relire() {
        pressionNiveau = sysctlInt("kern.memorystatus_vm_pressure_level")
        pression = min(1, max(0, Double(100 - sysctlInt("kern.memorystatus_level")) / 100))
        ram = ramUtilisee()
        (swapUtilise, swapTotal) = swap()
        let t = ticksProcesseur()
        let dt = t.total - dernierTicks.total
        processeur = dt > 0 ? (t.occupe - dernierTicks.occupe) / dt : 0
        dernierTicks = t
        historique.append(processeur); if historique.count > 5 { historique.removeFirst() }
        chaleur = ProcessInfo.processInfo.thermalState
        lireProcessus()
        juger()
    }

    private func lireProcessus() {
        let maintenant = DispatchTime.now().uptimeNanoseconds
        let ecoule = Double(maintenant - dernierInstant); dernierInstant = maintenant
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        let lus = Int(proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size)))
        var groupes: [String: Groupe] = [:]
        var nouveauxTemps: [String: Double] = [:]
        var chemin = [CChar](repeating: 0, count: 4096)
        for pid in pids.prefix(lus) where pid > 0 {
            var ru = rusage_info_v2()
            let ok = withUnsafeMutablePointer(to: &ru) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V2, $0) }
            }
            guard ok == 0 else { continue }   // processus d'un autre utilisateur : illisible, et on ne pourrait pas le quitter
            let cle = "\(pid)-\(ru.ri_proc_start_abstime)"
            let id: Identite
            if let connu = identites[cle] { id = connu } else {
                guard proc_pidpath(pid, &chemin, UInt32(chemin.count)) > 0 else { continue }
                id = identite(chemin: String(cString: chemin)); identites[cle] = id
            }
            let temps = Double(ru.ri_user_time + ru.ri_system_time) * timebase
            nouveauxTemps[cle] = temps
            var g = groupes[id.nom] ?? Groupe(nom: id.nom, chemin: id.chemin, protege: id.protege)
            g.ram += Double(ru.ri_phys_footprint)
            if let avant = tempsPrecedents[cle], ecoule > 0 { g.processeur += max(0, temps - avant) / (ecoule * nbCoeurs) * 100 }
            g.pids.append(pid)
            groupes[id.nom] = g
        }
        tempsPrecedents = nouveauxTemps
        identites = identites.filter { nouveauxTemps[$0.key] != nil }
        let tous = groupes.values.filter { $0.nom != "Jauge" }
        parRam = Array(tous.sorted { $0.ram > $1.ram }.prefix(5))
        parProcesseur = Array(tous.filter { $0.processeur >= 0.1 }.sorted { $0.processeur > $1.processeur }.prefix(5))
    }

    private func juger() {
        let ancien = niveau
        let fermables = parRam.filter { !$0.protege }
        let gros = fermables.prefix(2).map { "\($0.nom) (\(Fmt.go($0.ram)))" }
        let suggestion = gros.isEmpty ? "" : " Ferme " + gros.joined(separator: " ou ") + "."
        let tropProc = historique.count >= 5 && historique.allSatisfy { $0 > 0.85 }
        let procHaut = historique.count >= 5 && historique.allSatisfy { $0 > 0.60 }
        let gourmand = parProcesseur.first { !$0.protege } ?? parProcesseur.first
        let swapPlein = swapTotal > 0 && swapUtilise / swapTotal > 0.8

        if pressionNiveau >= 4 {
            niveau = .leve; mot = "Lève le pied"
            phrase = "La RAM est à bout, le Mac va ramer fort." + suggestion
        } else if pressionNiveau >= 2 && swapPlein {
            niveau = .leve; mot = "Lève le pied"
            phrase = "La RAM est pleine et le Mac écrit sur le disque pour compenser." + suggestion
        } else if chaleur == .critical {
            niveau = .leve; mot = "Lève le pied"
            phrase = "Le Mac est brûlant et se bride tout seul." + (gourmand.map { " Le plus gourmand : \($0.nom)." } ?? "")
        } else if tropProc, let g = gourmand {
            niveau = .leve; mot = "Lève le pied"
            phrase = "Le processeur tourne à fond, surtout à cause de \(g.nom) (\(Fmt.pct(g.processeur)) du Mac)."
        } else if pressionNiveau >= 2 {
            niveau = .chauffe; mot = "Ça chauffe"
            phrase = "La RAM commence à manquer." + suggestion
        } else if chaleur == .serious {
            niveau = .chauffe; mot = "Ça chauffe"
            phrase = "Le Mac est chaud, il peut ralentir." + (gourmand.map { " Le plus gourmand : \($0.nom)." } ?? "")
        } else if procHaut, let g = gourmand {
            niveau = .chauffe; mot = "Ça chauffe"
            phrase = "Le processeur est bien chargé, surtout par \(g.nom)."
        } else {
            niveau = .roule; mot = "Ça roule"
            phrase = swapPlein ? "Tout va bien. Le swap reste plein d'avant, ça se videra tout seul." : "Tout va bien. Rien à fermer."
        }
        if niveau != ancien { auChangement?(niveau) }
    }

    // MARK: Quitter un groupe

    func quitter(_ g: Groupe) {
        let alerte = NSAlert()
        alerte.messageText = "Quitter \(g.nom) ?"
        let libere = "Ça libère environ \(Fmt.go(g.ram))."
        if g.chemin != nil {
            alerte.informativeText = libere + " Si un document n'est pas enregistré, l'app te le demandera."
        } else {
            alerte.informativeText = libere + " \(g.pids.count) processus seront arrêtés" + (g.pids.count > 1 ? ", tous ceux qui s'appellent « \(g.nom) »." : ".")
        }
        alerte.addButton(withTitle: "Quitter")
        alerte.addButton(withTitle: "Annuler")
        guard alerte.runModal() == .alertFirstButtonReturn else { return }
        if let chemin = g.chemin {
            let apps = NSWorkspace.shared.runningApplications.filter { $0.bundleURL?.path == chemin }
            if apps.isEmpty { g.pids.forEach { kill($0, SIGTERM) } } else { apps.forEach { $0.terminate() } }
        } else {
            g.pids.forEach { kill($0, SIGTERM) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.relire() }
    }
}

enum Fmt {
    static func go(_ octets: Double) -> String {
        octets >= unGo ? String(format: "%.1f Go", octets / unGo).replacingOccurrences(of: ".", with: ",")
                     : "\(Int((octets / 1_048_576).rounded())) Mo"
    }
    static func pct(_ v: Double) -> String { v < 1 ? "<1 %" : "\(Int(v.rounded())) %" }
}

// MARK: - Interface

func couleur(_ niveau: Niveau) -> Color { [Color.sable, .ocre, Color(red: 0.98, green: 0.52, blue: 0.27)][niveau.rawValue] }

struct Anneau: View {
    let titre: String, grand: String, petit: String
    let valeur: Double
    let teinte: Color
    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle().trim(from: 0.125, to: 0.875)
                    .stroke(Color.sable.opacity(0.14), style: StrokeStyle(lineWidth: 7, lineCap: .butt))
                Circle().trim(from: 0.125, to: 0.125 + 0.75 * min(1, max(0.01, valeur)))
                    .stroke(teinte, style: StrokeStyle(lineWidth: 7, lineCap: .butt))
                    .animation(.easeOut(duration: 0.6), value: valeur)
            }
            .rotationEffect(.degrees(90))
            .overlay(Text(grand).font(.system(size: 17, weight: .semibold).monospacedDigit()).foregroundStyle(Color.sable).lineLimit(1).minimumScaleFactor(0.6).frame(width: 52))
            .frame(width: 70, height: 70)
            Text(titre.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(1.4).foregroundStyle(Color.ocre)
            Text(petit).font(.system(size: 11).monospacedDigit()).foregroundStyle(Color.sable.opacity(0.7))
                .lineLimit(1).minimumScaleFactor(0.8)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
        .glassEffect(.regular.tint(Color.ombre.opacity(0.45)), in: .rect(cornerRadius: 18))
    }
}

struct Ligne: View {
    let g: Groupe
    let valeur: String
    let part: Double          // 0…1, pour la petite barre
    let quitter: () -> Void
    var body: some View {
        HStack(spacing: 10) {
            Group {
                if let c = g.chemin { Image(nsImage: NSWorkspace.shared.icon(forFile: c)).resizable() }
                else { Image(systemName: "terminal").font(.system(size: 12)).foregroundStyle(Color.sable.opacity(0.7)) }
            }
            .frame(width: 20, height: 20)
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(g.nom).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.sable).lineLimit(1)
                    Spacer()
                    Text(valeur).font(.system(size: 12).monospacedDigit()).foregroundStyle(Color.sable.opacity(0.75))
                }
                GeometryReader { geo in
                    Rectangle().fill(Color.sable.opacity(0.12))
                        .overlay(alignment: .leading) { Rectangle().fill(Color.ocre).frame(width: geo.size.width * min(1, part)) }
                }
                .frame(height: 3)
            }
            Button(action: quitter) { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                .buttonStyle(.glass).tint(nil as Color?)
                .help("Quitter \(g.nom)")
                .opacity(g.protege ? 0 : 1).disabled(g.protege)
        }
    }
}

struct Liste: View {
    let titre: String
    let groupes: [Groupe]
    let valeur: (Groupe) -> String
    let part: (Groupe) -> Double
    let vide: String
    let quitter: (Groupe) -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Legende(titre)
            if groupes.isEmpty {
                Text(vide).font(.system(size: 12)).foregroundStyle(Color.sable.opacity(0.6))
            }
            ForEach(groupes) { g in Ligne(g: g, valeur: valeur(g), part: part(g)) { quitter(g) } }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular.tint(Color.ombre.opacity(0.45)), in: .rect(cornerRadius: 18))
    }
}

struct Vue: View {
    @ObservedObject var e: Etat

    var teinteRam: Color { e.pressionNiveau >= 4 ? .terre : e.pressionNiveau >= 2 ? .ocre : .sable }
    var teinteProc: Color { e.processeur > 0.85 ? .terre : e.processeur > 0.6 ? .ocre : .sable }
    var chaleur: (String, Double, Color) {
        switch e.chaleur {
        case .nominal: return ("Normal", 0.22, .sable)
        case .fair: return ("Tiède", 0.45, .sable)
        case .serious: return ("Chaud", 0.75, .ocre)
        case .critical: return ("Critique", 1, .terre)
        @unknown default: return ("?", 0, .sable)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Legende("État du Mac")
                Text(e.mot).font(.system(size: 34, weight: .semibold)).foregroundStyle(couleur(e.niveau))
                Text(e.phrase).font(.system(size: 14)).foregroundStyle(Color.sable)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassEffect(.regular.tint(Color.ombre.opacity(0.55)), in: .rect(cornerRadius: 18))

            HStack(spacing: 10) {
                Anneau(titre: "RAM", grand: "\(Int((e.pression * 100).rounded())) %",
                       petit: "swap \(Fmt.go(e.swapUtilise)) / \(Fmt.go(e.swapTotal))",
                       valeur: e.pression, teinte: teinteRam)
                Anneau(titre: "Processeur", grand: "\(Int((e.processeur * 100).rounded())) %",
                       petit: "\(Int(nbCoeurs)) cœurs", valeur: e.processeur, teinte: teinteProc)
                Anneau(titre: "Chaleur", grand: chaleur.0, petit: "état thermique",
                       valeur: chaleur.1, teinte: chaleur.2)
            }
            Text("RAM : pression mémoire (le signal du Moniteur d'activité). \(Fmt.go(e.ram)) utilisés sur \(Fmt.go(ramTotale)).")
                .font(.system(size: 11)).foregroundStyle(Color.sable.opacity(0.6))
                .fixedSize(horizontal: false, vertical: true)

            Liste(titre: "Qui mange la RAM", groupes: e.parRam, valeur: { Fmt.go($0.ram) },
                  part: { $0.ram / ramTotale }, vide: "…", quitter: e.quitter)
            Liste(titre: "Qui fait tourner le processeur", groupes: e.parProcesseur, valeur: { Fmt.pct($0.processeur) },
                  part: { $0.processeur / 100 }, vide: "Personne, le processeur se repose.", quitter: e.quitter)
        }
        .padding(.horizontal, 20).padding(.top, 34).padding(.bottom, 20)
        .frame(width: 420)
        .background(FondCanyon(intensite: 0.9))
        .preferredColorScheme(.dark)
        .tint(.terre)
    }
}

// MARK: - App : fenêtre + pastille dans la barre des menus

final class AppDelegate: NSObject, NSApplicationDelegate {
    let etat = Etat()
    var window: NSWindow!
    var statusItem: NSStatusItem!

    func applicationDidFinishLaunching(_ n: Notification) {
        window = NSWindow(contentRect: .zero, styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "Jauge"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: Vue(e: etat))

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(clic)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        etat.auChangement = { [weak self] in self?.pastille($0) }
        pastille(.roule)
        etat.demarrer()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.montrer() }
    }

    // la pastille : jauge blanche si ça roule, ocre si ça chauffe, terre cuite s'il faut lever le pied
    func pastille(_ n: Niveau) {
        let nom = ["gauge.with.dots.needle.33percent", "gauge.with.dots.needle.50percent", "gauge.with.dots.needle.67percent"][n.rawValue]
        var image = NSImage(systemSymbolName: nom, accessibilityDescription: "Jauge") ?? NSImage(systemSymbolName: "gauge", accessibilityDescription: "Jauge")
        if n == .roule {
            image?.isTemplate = true
        } else {
            let teinte = n == .chauffe ? Canyon.ocre : NSColor(srgbRed: 0.93, green: 0.42, blue: 0.18, alpha: 1)
            image = image?.withSymbolConfiguration(.init(paletteColors: [teinte]))
            image?.isTemplate = false
        }
        statusItem.button?.image = image
    }

    @objc func clic() {
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            let menu = NSMenu()
            menu.addItem(withTitle: "Ouvrir Jauge", action: #selector(ouvrir), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: "Quitter Jauge", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else if window.isVisible && NSApp.isActive {
            window.orderOut(nil)
        } else { montrer() }
    }
    @objc func ouvrir() { montrer() }

    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows f: Bool) -> Bool { montrer(); return true }

    // la fenêtre s'ouvre juste sous la pastille
    func montrer() {
        if !window.isVisible, let b = statusItem.button, let bw = b.window, let ecran = bw.screen ?? NSScreen.main {
            let icone = bw.convertToScreen(b.convert(b.bounds, to: nil))
            if let v = window.contentView { window.setContentSize(v.fittingSize) }
            let vis = ecran.visibleFrame
            let x = min(max(icone.midX - window.frame.width / 2, vis.minX + 8), vis.maxX - window.frame.width - 8)
            window.setFrameTopLeftPoint(NSPoint(x: x, y: vis.maxY - 6))
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
