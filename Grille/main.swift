import AppKit
import Carbon
import ServiceManagement

// Clic sur l'app ou ⌃⇧T : nouveau bureau vide + 6 fenêtres Terminal en grille 3×2

let colonnes = 3, lignes = 2
let ecart: CGFloat = 12

// MARK: - Accessibilité (pour piloter Mission Control)

func attr(_ e: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    AXUIElementCopyAttributeValue(e, name as CFString, &v)
    return v
}

func enfants(_ e: AXUIElement) -> [AXUIElement] { attr(e, kAXChildrenAttribute) as? [AXUIElement] ?? [] }

func chercher(_ e: AXUIElement, id: String, profondeur: Int = 0) -> [AXUIElement] {
    if profondeur > 8 { return [] }
    if attr(e, kAXIdentifierAttribute) as? String == id { return [e] }
    return enfants(e).flatMap { chercher($0, id: id, profondeur: profondeur + 1) }
}

func cadre(_ e: AXUIElement) -> CGRect {
    var p = CGPoint.zero, s = CGSize.zero
    if let v = attr(e, kAXPositionAttribute) { AXValueGetValue(v as! AXValue, .cgPoint, &p) }
    if let v = attr(e, kAXSizeAttribute) { AXValueGetValue(v as! AXValue, .cgSize, &s) }
    return CGRect(origin: p, size: s)
}

/// Position de la souris en coordonnées « haut-gauche » (celles d'AX et d'AppleScript)
func sourisHautGauche() -> CGPoint {
    let m = NSEvent.mouseLocation
    let h = NSScreen.screens.first!.frame.height
    return CGPoint(x: m.x, y: h - m.y)
}

func attendre(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }

/// Ouvre Mission Control, ajoute un bureau sur l'écran de la souris et s'y rend
func nouveauBureau() -> Bool {
    guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
    else { return false }
    let app = AXUIElementCreateApplication(dock.processIdentifier)
    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app"))

    var ecrans: [AXUIElement] = []
    for _ in 0..<30 {   // attendre que Mission Control soit affiché
        attendre(0.1)
        ecrans = chercher(app, id: "mc.display")
        if !ecrans.isEmpty && !chercher(app, id: "mc.spaces.add").isEmpty { break }
    }
    let souris = sourisHautGauche()
    let ecran = ecrans.first { cadre($0).contains(souris) } ?? ecrans.first
    guard let ecran, let ajouter = chercher(ecran, id: "mc.spaces.add").first,
          let liste = chercher(ecran, id: "mc.spaces.list").first
    else { NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Mission Control.app")); return false }

    let avant = enfants(liste).count
    AXUIElementPerformAction(ajouter, kAXPressAction as CFString)
    for _ in 0..<20 where enfants(liste).count == avant { attendre(0.1) }
    guard let dernier = enfants(liste).last else { return false }
    AXUIElementPerformAction(dernier, kAXPressAction as CFString)
    attendre(0.9)   // animation de sortie de Mission Control
    return true
}

// MARK: - Terminal

func ouvrirTerminaux() {
    let souris = NSEvent.mouseLocation
    let ecran = NSScreen.screens.first { NSMouseInRect(souris, $0.frame, false) } ?? NSScreen.main!
    let h = NSScreen.screens.first!.frame.height
    let v = ecran.visibleFrame
    let haut = h - v.maxY   // haut de la zone utile en coordonnées haut-gauche
    let l = (v.width - ecart * CGFloat(colonnes + 1)) / CGFloat(colonnes)
    let ht = (v.height - ecart * CGFloat(lignes + 1)) / CGFloat(lignes)

    var cadres: [String] = [], commandes: [String] = []
    for r in 0..<lignes {
        for c in 0..<colonnes {
            let x1 = v.minX + ecart + CGFloat(c) * (l + ecart)
            let y1 = haut + ecart + CGFloat(r) * (ht + ecart)
            commandes.append(r == 0 ? "claude" : "")   // Claude Code dans la rangée du haut
            cadres.append("{\(Int(x1)), \(Int(y1)), \(Int(x1 + l)), \(Int(y1 + ht))}")
        }
    }
    let script = """
    set lesCadres to {\(cadres.joined(separator: ", "))}
    set lesCommandes to {\(commandes.map { "\"\($0)\"" }.joined(separator: ", "))}
    tell application "Terminal"
        set dejaLance to running
        if not dejaLance then
            launch
            delay 0.5
        end if
        set fenetres to {}
        repeat with i from 1 to count of lesCadres
            set cmd to item i of lesCommandes
            if i = 1 and not dejaLance and (count of windows) > 0 then
                if cmd is not "" then do script cmd in window 1
            else
                do script cmd
            end if
            set end of fenetres to window 1
        end repeat
        repeat with i from 1 to count of fenetres
            set bounds of item i of fenetres to item i of lesCadres
        end repeat
        activate
    end tell
    """
    var err: NSDictionary?
    NSAppleScript(source: script)?.executeAndReturnError(&err)
    if let err { NSLog("Grille: \(err)") }
}

// MARK: - Raccourci global (Carbon)

func installerRaccourci(_ action: @escaping () -> Void) {
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    raccourci = action
    InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
        DispatchQueue.main.async { raccourci?() }
        return noErr
    }, 1, &spec, nil, nil)
    var ref: EventHotKeyRef?
    RegisterEventHotKey(UInt32(kVK_ANSI_T), UInt32(controlKey | shiftKey),
                        EventHotKeyID(signature: OSType(0x4752_494C), id: 1), GetApplicationEventTarget(), 0, &ref)
}
var raccourci: (() -> Void)?

// MARK: - App

final class Grille: NSObject, NSApplicationDelegate {
    var enCours = false

    var auDemarrage = false

    func applicationWillFinishLaunching(_ n: Notification) {
        let ev = NSAppleEventManager.shared().currentAppleEvent
        auDemarrage = ev?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
            || ProcessInfo.processInfo.systemUptime < 120
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        if SMAppService.mainApp.status != .enabled { try? SMAppService.mainApp.register() }
        installerRaccourci { [weak self] in self?.lancer() }
        // ouverte au démarrage de la session : on attend le raccourci ; sinon c'est un clic, on lance
        if !auDemarrage { lancer() }
    }

    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool {
        lancer()
        return false
    }

    func lancer() {
        if enCours { return }
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(opts) else { return }
        enCours = true
        defer { enCours = false }
        if nouveauBureau() { ouvrirTerminaux() }
    }
}

let app = NSApplication.shared
let delegue = Grille()
app.delegate = delegue
app.setActivationPolicy(.accessory)
app.run()
