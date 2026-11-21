// Flow : un clic pour entrer en flow, un 2e clic (ou le menu) pour en sortir.
// Bureau caché sous un fond « canyon au crépuscule » animé, Dock et barre des menus masqués,
// musique de concentration générée en direct. Les fenêtres restent utilisables.
import AppKit
import SwiftUI
import AVFoundation

// MARK: - Musique (nappe d'accords qui évolue + notes de cloche douces + pluie légère)

final class Ambiance {
    struct Bell { var f: Double; var ph = 0.0; var age = 0.0; var amp: Float; var pan: Float }
    let engine = AVAudioEngine()
    var src: AVAudioSourceNode!
    var sr = 48000.0
    var level: Float = 0, target: Float = 0
    // Fmaj7 → C → Am7 → G, 12 s par accord, enchaînés en fondu
    let chords: [[Double]] = [
        [174.61, 261.63, 329.63, 440.00, 523.25],
        [196.00, 261.63, 329.63, 392.00, 493.88],
        [220.00, 261.63, 329.63, 392.00, 523.25],
        [196.00, 293.66, 392.00, 493.88, 587.33],
    ]
    var padPh = [[Double]](repeating: [Double](repeating: 0, count: 5), count: 4)
    let scale = [261.63, 293.66, 329.63, 392.00, 440.00, 523.25] // do majeur pentatonique
    var bells: [Bell] = []
    var nextBell = 3.0
    var bl = 0.0, br = 0.0, binL = 0.0, binR = 0.0, t = 0.0
    var rng: UInt64 = 0x9E3779B97F4A7C15

    func white() -> Double {
        rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
        return Double(rng % 2_000_001) / 1_000_000 - 1
    }
    func rand(_ a: Double, _ b: Double) -> Double { a + (white() + 1) / 2 * (b - a) }

    func start() {
        sr = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let fmt = AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)!
        src = AVAudioSourceNode(format: fmt) { [unowned self] _, _, frames, abl in
            let buf = UnsafeMutableAudioBufferListPointer(abl)
            let L = buf[0].mData!.assumingMemoryBound(to: Float.self)
            let R = buf[1].mData!.assumingMemoryBound(to: Float.self)
            for i in 0..<Int(frames) { (L[i], R[i]) = self.next() }
            return noErr
        }
        let reverb = AVAudioUnitReverb()
        reverb.loadFactoryPreset(.largeHall)
        reverb.wetDryMix = 35
        engine.attach(src); engine.attach(reverb)
        engine.connect(src, to: reverb, format: fmt)
        engine.connect(reverb, to: engine.mainMixerNode, format: fmt)
        try? engine.start()
        target = 1
    }

    func next() -> (Float, Float) {
        let dt = 1 / sr
        t += dt
        // fondu doux (~6 s à l'entrée)
        level += (target - level) * Float(dt / 1.5)
        var l: Float = 0, r: Float = 0

        // nappe : chaque accord monte puis s'efface en cosinus
        let p = (t / 12).truncatingRemainder(dividingBy: 4)
        for k in 0..<4 {
            var d = abs(p - Double(k) - 0.5)
            d = min(d, 4 - d)
            guard d < 1 else { continue }
            let w = Float(0.5 + 0.5 * cos(.pi * d))
            for v in 0..<5 {
                padPh[k][v] += 2 * .pi * chords[k][v] * dt
                if padPh[k][v] > 2 * .pi { padPh[k][v] -= 2 * .pi }
                let ph = padPh[k][v]
                let s = Float(sin(ph) + 0.3 * sin(2 * ph)) * 0.032 * w
                let pan: Float = v % 2 == 0 ? -0.35 : 0.35
                l += s * (1 - pan); r += s * (1 + pan)
            }
        }

        // cloches : une note de temps en temps, qui s'éteint doucement
        if t >= nextBell {
            if bells.count < 8 {
                bells.append(Bell(f: scale[Int(rand(0, 5.99))], amp: Float(rand(0.05, 0.09)), pan: Float(rand(-0.6, 0.6))))
            }
            nextBell = t + rand(1.8, 4.5)
        }
        for i in bells.indices {
            bells[i].ph += 2 * .pi * bells[i].f * dt
            if bells[i].ph > 2 * .pi { bells[i].ph -= 2 * .pi }
            bells[i].age += dt
            let a = bells[i].age, ph = bells[i].ph
            let env = min(1, a / 0.01) * exp(-a / 2.2)
            let s = Float((sin(ph) + 0.35 * sin(2 * ph) * exp(-a / 0.6) + 0.12 * sin(3 * ph) * exp(-a / 0.3)) * env) * bells[i].amp
            l += s * (1 - bells[i].pan); r += s * (1 + bells[i].pan)
        }
        bells.removeAll { $0.age > 10 }

        // pluie très légère
        bl = (bl + 0.02 * white()) / 1.02
        br = (br + 0.02 * white()) / 1.02
        l += Float(bl * 3.5) * 0.05
        r += Float(br * 3.5) * 0.05
        // battements binauraux 14 Hz (au casque)
        binL += 2 * .pi * 180 * dt; binR += 2 * .pi * 194 * dt
        if binL > 2 * .pi { binL -= 2 * .pi }
        if binR > 2 * .pi { binR -= 2 * .pi }
        l += Float(sin(binL)) * 0.015
        r += Float(sin(binR)) * 0.015
        return (l * level * 0.3, r * level * 0.3)
    }

    // musique coupée = moteur audio arrêté après le fondu (sinon il calcule du silence en continu)
    var muted = false {
        didSet {
            target = muted ? 0 : 1
            if muted {
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [self] in if self.muted { engine.pause() } }
            } else if !engine.isRunning {
                try? engine.start()
            }
        }
    }
    func fadeOut() { target = 0 }
}

// MARK: - Fond d'écran « canyon au crépuscule » animé + chrono + respiration (cohérence cardiaque)

struct Backdrop: View {
    let start: Date

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width, h = geo.size.height
            // 20 images/s au lieu de ~120 : le mouvement est lent, l'œil ne voit pas la différence, la batterie si
            TimelineView(.animation(minimumInterval: 1.0 / 20)) { ctx in
                let t = ctx.date.timeIntervalSince(start)
                let drift = Self.wave(t, 45)   // va-et-vient de 45 s
                let breathe = Self.wave(t, 5)  // respiration : 5 s inspire, 5 s expire
                ZStack {
                    LinearGradient(colors: [Color(red: 0.10, green: 0.045, blue: 0.03), Color(red: 0.035, green: 0.015, blue: 0.01)],
                                   startPoint: .top, endPoint: .bottom)
                    blob(Color(red: 0.36, green: 0.13, blue: 0.06), w * 0.8)
                        .offset(x: Self.mix(w * 0.12, -w * 0.18, drift), y: Self.mix(h * 0.05, -h * 0.15, drift))
                    blob(Color(red: 0.24, green: 0.08, blue: 0.05), w * 0.7)
                        .offset(x: Self.mix(-w * 0.05, w * 0.22, drift), y: Self.mix(-h * 0.1, h * 0.2, drift))
                    blob(Color(red: 0.45, green: 0.24, blue: 0.10), w * 0.55)
                        .offset(x: Self.mix(w * 0.25, w * 0.02, drift), y: Self.mix(h * 0.3, h * 0.05, drift))
                    Circle()
                        .stroke(Color.sable.opacity(0.08), lineWidth: 1)
                        .frame(width: 260, height: 260)
                        .scaleEffect(Self.mix(0.8, 1.25, breathe))
                    Text(Self.clock(t))
                        .font(.system(size: 54, weight: .ultraLight))
                        .monospacedDigit()
                        .foregroundStyle(Color.sable.opacity(0.3))
                }
                .frame(width: w, height: h)
            }
        }
        .ignoresSafeArea()
    }

    // 0 → 1 → 0 en douceur (comme easeInOut + autoreverse), une demi-période = `half` secondes
    static func wave(_ t: TimeInterval, _ half: Double) -> CGFloat { CGFloat(0.5 - 0.5 * cos(.pi * t / half)) }
    static func mix(_ a: CGFloat, _ b: CGFloat, _ k: CGFloat) -> CGFloat { a + (b - a) * k }

    // dégradé radial plutôt qu'un .blur : même halo, sans recalculer un flou plein écran à chaque image
    func blob(_ c: Color, _ d: CGFloat) -> some View {
        Circle()
            .fill(RadialGradient(colors: [c, c.opacity(0.75), c.opacity(0.3), c.opacity(0)],
                                 center: .center, startRadius: 0, endRadius: d * 0.72))
            .frame(width: d * 1.44, height: d * 1.44)
            .opacity(0.85)
    }

    static func clock(_ s: TimeInterval) -> String {
        let s = Int(s)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%02d:%02d", s / 60, s % 60)
    }
}

// MARK: - État sauvegardé (pour tout remettre comme avant, même après un plantage)

struct Saved: Codable {
    var dockAutohide: Bool
    var menuAutohide: Bool
}

let stateURL: URL = {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Flow")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("etat.json")
}()

@discardableResult
func run(_ path: String, _ args: [String]) -> String {
    let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = args
    let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
    try? p.run(); p.waitUntilExit()
    return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
}

func setDockAutohide(_ on: Bool) {
    run("/usr/bin/defaults", ["write", "com.apple.dock", "autohide", "-bool", on ? "true" : "false"])
    run("/usr/bin/killall", ["Dock"])
}

func setMenuAutohide(_ on: Bool) {
    run("/usr/bin/osascript", ["-e", "tell application \"System Events\" to set autohide menu bar of dock preferences to \(on)"])
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    let ambiance = Ambiance()
    var overlays: [NSWindow] = []
    var item: NSStatusItem!
    var tick: Timer?
    var saved: Saved!
    let start = Date()
    var leaving = false

    func applicationDidFinishLaunching(_ n: Notification) {
        enter()
    }

    // recliquer sur l'app = sortir du flow
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool {
        leave(); return false
    }

    func enter() {
        // si un ancien état traîne (plantage), on garde les réglages d'origine
        if let d = try? Data(contentsOf: stateURL), let old = try? JSONDecoder().decode(Saved.self, from: d) {
            saved = old
        } else {
            let dock = run("/usr/bin/defaults", ["read", "com.apple.dock", "autohide"]).trimmingCharacters(in: .whitespacesAndNewlines) == "1"
            let menu = run("/usr/bin/osascript", ["-e", "tell application \"System Events\" to get autohide menu bar of dock preferences"]).hasPrefix("true")
            saved = Saved(dockAutohide: dock, menuAutohide: menu)
            try? JSONEncoder().encode(saved).write(to: stateURL)
        }

        // 1. fond d'écran qui recouvre bureau, icônes et widgets (les fenêtres passent au-dessus)
        for screen in NSScreen.screens {
            let w = NSWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
            w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
            w.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            w.isOpaque = true
            w.backgroundColor = .black
            w.contentView = NSHostingView(rootView: Backdrop(start: start))
            w.setFrame(screen.frame, display: true)
            w.alphaValue = 0
            w.orderFront(nil)
            overlays.append(w)
        }
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 1.2
            overlays.forEach { $0.animator().alphaValue = 1 }
        }

        // 2. Dock et barre des menus masqués, musique
        if !saved.dockAutohide { setDockAutohide(true) }
        if !saved.menuAutohide { DispatchQueue.global().async { setMenuAutohide(true) } }
        ambiance.start()

        // 3. petit chrono dans la barre des menus, avec le menu pour sortir
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        let menu = NSMenu()
        let music = NSMenuItem(title: "Couper la musique", action: #selector(toggleMusic(_:)), keyEquivalent: "m")
        music.target = self
        menu.addItem(music)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Sortir du flow", action: #selector(quitFlow), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        updateClock()
        tick = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.updateClock() }
    }

    func updateClock() {
        item.button?.title = "◐ " + Backdrop.clock(Date().timeIntervalSince(start))
    }

    @objc func toggleMusic(_ sender: NSMenuItem) {
        ambiance.muted.toggle()
        sender.title = ambiance.muted ? "Remettre la musique" : "Couper la musique"
    }

    @objc func quitFlow() { leave() }

    func leave() {
        guard !leaving else { return }
        leaving = true
        ambiance.fadeOut()
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 1.5
            overlays.forEach { $0.animator().alphaValue = 0 }
        }, completionHandler: { [self] in
            if !saved.dockAutohide { setDockAutohide(false) }
            if !saved.menuAutohide { setMenuAutohide(false) }
            try? FileManager.default.removeItem(at: stateURL)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { NSApp.terminate(nil) }
        })
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
