import AppKit
import SwiftUI
import ApplicationServices

// Bloque toutes les touches du clavier (lettres, modificateurs, touches média)
// tant que l'interrupteur est activé. La souris / le trackpad restent actifs.
//
// Gardes-fous pour ne jamais rester coincé :
//  1. Retour automatique du clavier à la fin du compte à rebours (120 s max).
//  2. Interrupteur et bouton « Réactiver » cliquables à la souris.
//  3. Fermer ou quitter l'app rend le clavier (le blocage vit dans l'app).
//  4. Si l'app plante ou se fige, macOS coupe le blocage tout seul.
//  5. Le bouton power et le redémarrage forcé marchent toujours.
final class KeyboardBlocker: ObservableObject {
    @Published var isBlocking = false
    @Published var remaining = 0
    @Published var duration = 60
    @Published var needsPermission = false

    fileprivate var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var timer: Timer?
    private static let maxDuration = 120

    func start() {
        guard !isBlocking else { return }
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        guard AXIsProcessTrustedWithOptions(options) else { needsPermission = true; return }

        let systemDefined: UInt64 = 14  // touches média, luminosité, volume
        let mask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)
                 | (1 << CGEventType.flagsChanged.rawValue) | (1 << systemDefined)

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            let blocker = Unmanaged<KeyboardBlocker>.fromOpaque(refcon!).takeUnretainedValue()
            if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                if let tap = blocker.tap { CGEvent.tapEnable(tap: tap, enable: true) }
                return Unmanaged.passUnretained(event)
            }
            if type.rawValue == 14 {
                // sous-type 8 = touches spéciales du clavier ; le reste passe
                if let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 { return nil }
                return Unmanaged.passUnretained(event)
            }
            return nil  // touche avalée
        }

        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                          options: .defaultTap, eventsOfInterest: CGEventMask(mask),
                                          callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            needsPermission = true
            return
        }
        needsPermission = false
        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        remaining = min(duration, Self.maxDuration)
        isBlocking = true
        NSSound(named: "Tink")?.play()

        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.remaining -= 1
            if self.remaining <= 0 { self.stop() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate(); timer = nil
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil; source = nil
        if isBlocking { NSSound(named: "Glass")?.play() }
        isBlocking = false
        remaining = 0
    }
}


struct ContentView: View {
    @ObservedObject var blocker: KeyboardBlocker

    private var progress: CGFloat {
        blocker.isBlocking ? CGFloat(blocker.remaining) / CGFloat(blocker.duration) : 1
    }
    private var ringColors: [Color] {
        blocker.isBlocking ? [.ocre, .terre, .ocre] : [.sable.opacity(0.5), .ocre, .sable.opacity(0.5)]
    }

    var body: some View {
        ZStack {
            FondCanyon()

            VStack(spacing: 22) {
                header

                // anneau du compte à rebours
                ZStack {
                    Circle().stroke(Color.sable.opacity(0.1), lineWidth: 6)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(AngularGradient(colors: ringColors, center: .center),
                                style: StrokeStyle(lineWidth: 6, lineCap: .butt))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 1), value: blocker.remaining)
                    if blocker.isBlocking {
                        VStack(spacing: 2) {
                            Text("\(blocker.remaining)")
                                .font(.system(size: 56, weight: .light))
                                .monospacedDigit()
                                .contentTransition(.numericText(countsDown: true))
                                .animation(.snappy, value: blocker.remaining)
                            Text("secondes").font(.callout).foregroundStyle(Color.sable.opacity(0.6))
                        }
                    } else {
                        Image(systemName: "keyboard")
                            .font(.system(size: 50, weight: .ultraLight))
                            .foregroundStyle(Color.ocre)
                    }
                }
                .padding(22)
                .frame(width: 210, height: 210)
                .glassEffect(.regular.tint(Color.ombre.opacity(0.45)), in: .circle)

                // l'interrupteur
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(blocker.isBlocking ? "Clavier désactivé" : "Désactiver le clavier")
                            .font(.headline)
                        Text(blocker.isBlocking ? "Nettoie tranquille" : "Il revient tout seul")
                            .font(.subheadline).foregroundStyle(Color.sable.opacity(0.6))
                    }
                    Spacer()
                    Toggle("", isOn: Binding(get: { blocker.isBlocking },
                                             set: { $0 ? blocker.start() : blocker.stop() }))
                        .toggleStyle(.switch).labelsHidden().controlSize(.large)
                        .tint(.terre)
                }
                .padding(.horizontal, 20).padding(.vertical, 14)
                .glassEffect(.regular.tint(Color.ombre.opacity(0.45)), in: .rect(cornerRadius: 22))

                if blocker.isBlocking {
                    Button { blocker.stop() } label: {
                        Text("Réactiver maintenant").fontWeight(.medium)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent).tint(.terre).controlSize(.extraLarge)
                } else {
                    GlassEffectContainer(spacing: 10) {
                        HStack(spacing: 10) {
                            ForEach([30, 60, 120], id: \.self) { secs in
                                durationButton(secs)
                            }
                        }
                    }
                }

                if blocker.needsPermission { permissionCard }

                safetyList
            }
            .padding(.horizontal, 26)
            .padding(.top, 34)
            .padding(.bottom, 24)
        }
        .frame(width: 380)
        .foregroundStyle(Color.sable)
        .tint(.terre)
        .preferredColorScheme(.dark)
        .animation(.spring(duration: 0.4), value: blocker.isBlocking)
        .animation(.spring(duration: 0.4), value: blocker.needsPermission)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 1) {
                Text("Nettoyage Clavier").font(.system(size: 20, weight: .semibold))
                Text(blocker.isBlocking ? "En cours…" : "Prêt").font(.subheadline)
                    .foregroundStyle(blocker.isBlocking ? Color.ocre : Color.sable.opacity(0.6))
            }
            Spacer()
        }
    }

    @ViewBuilder
    private func durationButton(_ secs: Int) -> some View {
        let label = Text("\(secs) s").font(.body.weight(.medium)).frame(maxWidth: .infinity)
        if blocker.duration == secs {
            Button { blocker.duration = secs } label: { label }
                .buttonStyle(.glassProminent).tint(.terre).controlSize(.large)
        } else {
            Button { blocker.duration = secs } label: { label }
                .buttonStyle(.glass).controlSize(.large).tint(nil as Color?)
        }
    }

    private var permissionCard: some View {
        VStack(spacing: 10) {
            Label("Autorise l'app dans Accessibilité, puis réessaie.", systemImage: "lock.shield")
                .font(.callout).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button("Ouvrir les réglages") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
            }
            .buttonStyle(.glassProminent).tint(.terre)
        }
        .padding(16).frame(maxWidth: .infinity)
        .glassEffect(.regular.tint(Color.rouille.opacity(0.5)), in: .rect(cornerRadius: 20))
    }

    private var safetyList: some View {
        VStack(alignment: .leading, spacing: 8) {
            safety("timer", "Retour automatique du clavier")
            safety("cursorarrow.click", "Souris et trackpad restent actifs")
            safety("xmark.circle", "Fermer l'app rend le clavier")
            safety("power", "Le redémarrage forcé marche toujours")
        }
        .font(.footnote).foregroundStyle(Color.sable.opacity(0.6))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
    }

    private func safety(_ icon: String, _ text: String) -> some View {
        Label { Text(text) } icon: {
            Image(systemName: icon).frame(width: 18).foregroundStyle(Color.terre)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let blocker = KeyboardBlocker()
    var window: NSWindow!

    func applicationDidFinishLaunching(_ n: Notification) {
        window = NSWindow(contentRect: .zero,
                          styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "Nettoyage Clavier"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.contentView = NSHostingView(rootView: ContentView(blocker: blocker))
        window.level = .floating  // toujours visible pour pouvoir réactiver
        window.isReleasedWhenClosed = false
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
    func applicationWillTerminate(_ n: Notification) { blocker.stop() }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
