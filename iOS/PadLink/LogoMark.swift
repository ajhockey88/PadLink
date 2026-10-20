import SwiftUI

/// The pad silhouette from the app icon, in the icon's 1024-point coordinate space.
private struct PadShape: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: 318, y: 352))
        p.addLine(to: CGPoint(x: 706, y: 352))
        p.addCurve(to: CGPoint(x: 868, y: 540), control1: CGPoint(x: 790, y: 352), control2: CGPoint(x: 842, y: 420))
        p.addCurve(to: CGPoint(x: 826, y: 686), control1: CGPoint(x: 884, y: 618), control2: CGPoint(x: 872, y: 672))
        p.addCurve(to: CGPoint(x: 716, y: 626), control1: CGPoint(x: 780, y: 700), control2: CGPoint(x: 744, y: 668))
        p.addCurve(to: CGPoint(x: 656, y: 592), control1: CGPoint(x: 700, y: 602), control2: CGPoint(x: 684, y: 592))
        p.addLine(to: CGPoint(x: 368, y: 592))
        p.addCurve(to: CGPoint(x: 308, y: 626), control1: CGPoint(x: 340, y: 592), control2: CGPoint(x: 324, y: 602))
        p.addCurve(to: CGPoint(x: 198, y: 686), control1: CGPoint(x: 280, y: 668), control2: CGPoint(x: 244, y: 700))
        p.addCurve(to: CGPoint(x: 156, y: 540), control1: CGPoint(x: 152, y: 672), control2: CGPoint(x: 140, y: 618))
        p.addCurve(to: CGPoint(x: 318, y: 352), control1: CGPoint(x: 182, y: 420), control2: CGPoint(x: 234, y: 352))
        p.closeSubpath()
        return p
    }
}

/// The PadLink icon, drawn as a vector so it stays sharp at any size.
struct LogoMark: View {
    var size: CGFloat = 60

    var body: some View {
        ZStack(alignment: .topLeading) {
            Theme.bg.frame(width: 1024, height: 1024)

            // Signal arcs (centre of the emitter is at 512, 450 after the 30pt shift).
            ForEach([100.0, 165.0, 230.0], id: \.self) { r in
                Circle()
                    .trim(from: 0.6333, to: 0.8667)
                    .stroke(Theme.mint, style: StrokeStyle(lineWidth: 34, lineCap: .round))
                    .frame(width: 2 * r, height: 2 * r)
                    .position(x: 512, y: 450)
            }
            Circle().fill(Theme.mint).frame(width: 52, height: 52).position(x: 512, y: 450)

            ZStack(alignment: .topLeading) {
                PadShape().fill(Theme.text).frame(width: 1024, height: 1024)
                RoundedRectangle(cornerRadius: 8).fill(Theme.bg).frame(width: 90, height: 36).position(x: 330, y: 480)
                RoundedRectangle(cornerRadius: 8).fill(Theme.bg).frame(width: 36, height: 90).position(x: 330, y: 480)
                Circle().fill(Theme.bg).frame(width: 48, height: 48).position(x: 694, y: 432)
                Circle().fill(Theme.bg).frame(width: 48, height: 48).position(x: 646, y: 480)
                Circle().fill(Theme.bg).frame(width: 48, height: 48).position(x: 742, y: 480)
                Circle().fill(Theme.mint).frame(width: 48, height: 48).position(x: 694, y: 528)
            }
            .frame(width: 1024, height: 1024)
            .offset(y: 121)
        }
        .frame(width: 1024, height: 1024, alignment: .topLeading)
        .scaleEffect(size / 1024, anchor: .topLeading)
        .frame(width: size, height: size, alignment: .topLeading)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.2237, style: .continuous))
        .accessibilityHidden(true)
    }
}
