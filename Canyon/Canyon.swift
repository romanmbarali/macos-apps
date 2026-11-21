import AppKit
import SwiftUI

// Style commun à toutes les apps de Roman : l'ambiance d'un canyon de grès.
// Terre cuite, ocre, rouille, sable, et une ombre presque noire.
// Compilé avec chaque app : swiftc main.swift ../Canyon/Canyon.swift

enum Canyon {
    // couleurs (sRGB)
    static let sable  = NSColor(srgbRed: 0.96, green: 0.88, blue: 0.78, alpha: 1)   // #F5E0C7
    static let ocre   = NSColor(srgbRed: 0.91, green: 0.60, blue: 0.29, alpha: 1)   // #E8994A
    static let terre  = NSColor(srgbRed: 0.80, green: 0.36, blue: 0.15, alpha: 1)   // #CC5C26, l'accent
    static let rouille = NSColor(srgbRed: 0.58, green: 0.21, blue: 0.10, alpha: 1)  // #94361A
    static let ombre  = NSColor(srgbRed: 0.13, green: 0.06, blue: 0.04, alpha: 1)   // #210F0A
}

extension Color {
    static let sable = Color(nsColor: Canyon.sable)
    static let ocre = Color(nsColor: Canyon.ocre)
    static let terre = Color(nsColor: Canyon.terre)
    static let rouille = Color(nsColor: Canyon.rouille)
    static let ombre = Color(nsColor: Canyon.ombre)
}

// Fond « roche » : de grandes strates en S, lumineuses en haut, qui plongent dans l'ombre en bas.
// intensite = 1 pour un fond plein, plus bas pour juste une lueur derrière du verre.
struct FondCanyon: View {
    var intensite: Double = 1
    var body: some View {
        SwiftUI.Canvas { ctx, size in
            let w = size.width, h = size.height
            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.ombre))
            let strates: [(Color, CGFloat, CGFloat)] = [   // couleur, hauteur de départ (0 = haut), houle
                (.ocre, 0.00, 0.10), (.terre, 0.16, -0.08), (.rouille, 0.34, 0.07),
                (Color(red: 0.36, green: 0.13, blue: 0.07), 0.52, -0.05), (.ombre, 0.68, 0.04)]
            for (i, s) in strates.enumerated() {
                let y = s.1 * h
                var p = Path()
                p.move(to: CGPoint(x: -20, y: y + s.2 * h))
                p.addCurve(to: CGPoint(x: w + 20, y: y + h * 0.08),
                           control1: CGPoint(x: w * 0.35, y: y - s.2 * h * 2.6),
                           control2: CGPoint(x: w * 0.65, y: y + s.2 * h * 3.2))
                var bande = p
                bande.addLine(to: CGPoint(x: w + 20, y: h + 20)); bande.addLine(to: CGPoint(x: -20, y: h + 20)); bande.closeSubpath()
                ctx.fill(bande, with: .linearGradient(Gradient(colors: [s.0, s.0.mix(with: .black, by: 0.35)]),
                                                      startPoint: CGPoint(x: 0, y: y), endPoint: CGPoint(x: w * 0.3, y: y + h * 0.3)))
                for k in 1...6 {   // fines stries du grès
                    ctx.stroke(p.offsetBy(dx: 0, dy: CGFloat(k) * 7), with: .color(.white.opacity(i < 2 ? 0.06 : 0.035)), lineWidth: 0.8)
                }
            }
        }
        .opacity(intensite)
        .ignoresSafeArea()
    }
}

// Petit titre de section : majuscules espacées, comme une légende
struct Legende: View {
    let texte: String
    var couleur: Color = .ocre
    init(_ texte: String, couleur: Color = .ocre) { self.texte = texte; self.couleur = couleur }
    var body: some View {
        HStack(spacing: 8) {
            Rectangle().fill(couleur).frame(width: 7, height: 7).rotationEffect(.degrees(45))
            Text(texte.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(1.6).foregroundStyle(couleur)
        }
    }
}
