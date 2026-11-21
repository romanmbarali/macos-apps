import SwiftUI
import IOKit.pwr_mgt
import IOKit.ps

// Garde le Mac éveillé, comme Amphetamine. Vit dans la barre des menus.
//
// Deux niveaux :
//  - normal : le Mac ne se met pas en veille tout seul (assertion macOS, sans mot de passe)
//  - capot fermé : « pmset disablesleep 1 », demande le mot de passe administrateur
//
// Gardes-fous pour le mode capot fermé :
//  1. Arrêt automatique à la fin du minuteur.
//  2. Arrêt automatique sous 15 % de batterie si le Mac n'est pas branché.
//  3. Quitter l'app remet la veille normale.
//  4. Si l'app a planté pendant ce mode, elle répare toute seule au lancement.
//  5. Une « garde » launchd (com.roman.eveille.garde) remet la veille si l'app n'est pas lancée.
final class Awake: ObservableObject {
    static let shared = Awake()

    @Published private(set) var active = false
    @Published var minutes = 60                 // 0 = sans limite
    @Published var lidClosed = false { didSet { if active, oldValue != lidClosed { applyLid() } } }
    @Published var keepScreen = true { didSet { if active, oldValue != keepScreen { applyAssertion() } } }
    @Published private(set) var endDate: Date?
    @Published private(set) var now = Date()
    @Published private(set) var sleepStuck = false
    @Published var notice: String?

    private var assertion: IOPMAssertionID = 0
    private var lidApplied = false
    private var ticker: Timer?
    private static let minBattery = 15

    init() {
        // reste d'une session plantée : on répare tout seul, sans rien demander
        if Self.systemSleepDisabled() { sleepStuck = !Self.sudoPmset(false) }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        ticker = t
    }

    var remaining: TimeInterval? { endDate.map { max(0, $0.timeIntervalSince(now)) } }

    func start() {
        guard !active else { return }
        notice = nil
        active = true
        applyAssertion()
        if lidClosed { applyLid() }
        endDate = minutes > 0 ? Date().addingTimeInterval(Double(minutes) * 60) : nil
        NSSound(named: "Tink")?.play()
    }

    func stop() {
        guard active else { return }
        active = false
        applyAssertion()
        applyLid()
        endDate = nil
        NSSound(named: "Glass")?.play()
    }

    func addTime(_ mins: Int) {
        guard active else { return }
        endDate = max(endDate ?? Date(), Date()).addingTimeInterval(Double(mins) * 60)
    }

    func repairSleep() {
        if Self.setSystemSleepDisabled(false) { sleepStuck = false }
    }

    private func applyAssertion() {
        if assertion != 0 { IOPMAssertionRelease(assertion); assertion = 0 }
        guard active else { return }
        let type = keepScreen ? kIOPMAssertionTypePreventUserIdleDisplaySleep
                              : kIOPMAssertionTypePreventUserIdleSystemSleep
        IOPMAssertionCreateWithName(type as CFString, IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                    "Éveillé" as CFString, &assertion)
    }

    private func applyLid() {
        let want = active && lidClosed
        guard want != lidApplied else { return }
        if Self.setSystemSleepDisabled(want) {
            lidApplied = want
        } else if want {
            lidClosed = false   // mot de passe refusé : on reste en mode normal
            notice = "Mode capot fermé annulé (autorisation refusée)"
        }
    }

    private func tick() {
        now = Date()
        if active, let end = endDate, now >= end { stop(); notice = "Minuteur terminé, le Mac peut redormir" }
        if lidApplied, let pct = Self.batteryOnBattery(), pct < Self.minBattery {
            stop(); notice = "Arrêté : batterie sous \(Self.minBattery) %"
        }
    }

    // MARK: système

    private static func systemSleepDisabled() -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        p.arguments = ["-g"]
        let pipe = Pipe(); p.standardOutput = pipe
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        let out = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return out.range(of: #"SleepDisabled\s+1"#, options: .regularExpression) != nil
    }

    // Sans mot de passe grâce à la règle /etc/sudoers.d/eveille (installée une seule fois).
    // Si la règle manque, on l'installe avec UNE demande de mot de passe, puis plus jamais.
    @discardableResult
    static func setSystemSleepDisabled(_ on: Bool) -> Bool {
        if sudoPmset(on) { return true }
        guard let script = Bundle.main.path(forResource: "installer-garde", ofType: "sh") else { return false }
        let cmd = "/bin/sh '\(script)' '\(NSUserName())' && /usr/bin/pmset -a disablesleep \(on ? 1 : 0)"
        var err: NSDictionary?
        NSAppleScript(source: "do shell script \"\(cmd)\" with administrator privileges")?.executeAndReturnError(&err)
        return err == nil
    }

    private static func sudoPmset(_ on: Bool) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        p.arguments = ["-n", "/usr/bin/pmset", "-a", "disablesleep", on ? "1" : "0"]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    // pourcentage de batterie, seulement si le Mac n'est pas branché
    private static func batteryOnBattery() -> Int? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for src in list {
            guard let d = IOPSGetPowerSourceDescription(info, src)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue,
                  let cur = d[kIOPSCurrentCapacityKey] as? Int, let max = d[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            return cur * 100 / max
        }
        return nil
    }
}


struct PanelView: View {
    @ObservedObject var awake: Awake

    private let durations: [(String, Int)] = [("30 min", 30), ("1 h", 60), ("2 h", 120), ("4 h", 240), ("∞", 0)]

    var body: some View {
        VStack(spacing: 14) {
            header

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(awake.active ? "Le Mac reste éveillé" : "Garder le Mac éveillé").font(.headline)
                    Text(statusLine).font(.subheadline).foregroundStyle(Color.sable.opacity(0.6))
                        .monospacedDigit()
                }
                Spacer()
                Toggle("", isOn: Binding(get: { awake.active }, set: { $0 ? awake.start() : awake.stop() }))
                    .toggleStyle(.switch).labelsHidden().controlSize(.large).tint(.terre)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .glassEffect(.regular.tint(Color.ombre.opacity(0.45)), in: .rect(cornerRadius: 20))

            if awake.active, awake.endDate != nil {
                HStack(spacing: 8) {
                    ForEach([15, 30, 60], id: \.self) { m in
                        Button("+\(m) min") { awake.addTime(m) }
                            .buttonStyle(.glass).frame(maxWidth: .infinity)
                    }
                }
            } else if !awake.active {
                HStack(spacing: 6) {
                    ForEach(durations, id: \.1) { label, m in
                        durationButton(label, m)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                option("Même capot fermé", "laptopcomputer", $awake.lidClosed,
                       "Coupé sous 15 % de batterie ou si l'app est fermée.")
                Divider().opacity(0.4)
                option("Garder l'écran allumé", "sun.max", $awake.keepScreen, nil)
            }
            .padding(14)
            .glassEffect(.regular.tint(Color.ombre.opacity(0.45)), in: .rect(cornerRadius: 20))

            if awake.lidClosed {
                Label("Pas dans un sac fermé : le Mac pourrait chauffer.", systemImage: "thermometer.high")
                    .font(.caption).foregroundStyle(Color.ocre)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if awake.sleepStuck { stuckCard }

            if let notice = awake.notice {
                Text(notice).font(.caption).foregroundStyle(Color.sable.opacity(0.6))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                Button("Quitter") { NSApp.terminate(nil) }
                    .buttonStyle(.plain).font(.caption).foregroundStyle(Color.sable.opacity(0.6))
            }
        }
        .padding(16)
        .frame(width: 320)
        .foregroundStyle(Color.sable)
        .background(FondCanyon())
        .preferredColorScheme(.dark)
        .animation(.spring(duration: 0.35), value: awake.active)
        .animation(.spring(duration: 0.35), value: awake.lidClosed)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 34, height: 34)
            Text("Éveillé").font(.system(size: 18, weight: .semibold))
            Spacer()
        }
    }

    private var statusLine: String {
        guard awake.active else { return "Il redort tout seul à la fin" }
        guard let r = awake.remaining else { return "Sans limite de temps" }
        let s = Int(r)
        return String(format: "Encore %d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }

    @ViewBuilder
    private func durationButton(_ label: String, _ m: Int) -> some View {
        let text = Text(label).font(.callout.weight(.medium)).frame(maxWidth: .infinity)
        if awake.minutes == m {
            Button { awake.minutes = m } label: { text }.buttonStyle(.glassProminent).tint(.terre)
        } else {
            Button { awake.minutes = m } label: { text }.buttonStyle(.glass)
        }
    }

    private func option(_ title: String, _ icon: String, _ value: Binding<Bool>, _ hint: String?) -> some View {
        HStack(alignment: .top) {
            Image(systemName: icon).foregroundStyle(Color.terre).frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout)
                if let hint { Text(hint).font(.caption).foregroundStyle(Color.sable.opacity(0.6)) }
            }
            Spacer()
            Toggle("", isOn: value).toggleStyle(.switch).labelsHidden().controlSize(.small).tint(.terre)
        }
    }

    private var stuckCard: some View {
        VStack(spacing: 8) {
            Label("Ton Mac ne peut plus du tout dormir (reste d'une ancienne session).",
                  systemImage: "exclamationmark.triangle")
                .font(.caption).fixedSize(horizontal: false, vertical: true)
            Button("Réparer") { awake.repairSleep() }.buttonStyle(.glassProminent).tint(.terre)
        }
        .padding(12).frame(maxWidth: .infinity)
        .glassEffect(.regular.tint(Color.rouille.opacity(0.5)), in: .rect(cornerRadius: 16))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ n: Notification) { Awake.shared.stop() }
}

@main
struct EveilleApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @ObservedObject var awake = Awake.shared

    var body: some Scene {
        MenuBarExtra {
            PanelView(awake: awake)
        } label: {
            Image(systemName: awake.active ? "cup.and.heat.waves.fill" : "cup.and.saucer")
        }
        .menuBarExtraStyle(.window)
    }
}
