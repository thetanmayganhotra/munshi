import SwiftUI

/// How Munshi feels right now. The model picks one per reply with a [[mood: x]] tag.
enum Mood: String, CaseIterable {
    case calm, happy, laughing, curious, thinking, concerned, sad, excited, mischievous, love, proud, listening

    struct Look {
        var eyeOpen: CGFloat      // 0 closed … 1 wide
        var eyeSmile: CGFloat     // 0 round … 1 happy crescent
        var mouthCurve: CGFloat   // -1 frown … 1 smile
        var mouthOpen: CGFloat    // 0 closed … 1 open
        var brow: CGFloat         // -1 worried … 0 neutral … 1 sly/determined
        var look: CGSize          // where the eyes glance
        var blush: Double
        var tint: [Color]
    }

    var look: Look {
        switch self {
        case .calm:        Look(eyeOpen: 0.55, eyeSmile: 0.25, mouthCurve: 0.35, mouthOpen: 0, brow: 0, look: .zero, blush: 0.15, tint: [.init(hex: 0x9FD8CB), .init(hex: 0x5FA8A0)])
        case .happy:       Look(eyeOpen: 0.6, eyeSmile: 0.85, mouthCurve: 0.8, mouthOpen: 0.15, brow: 0, look: .zero, blush: 0.4, tint: [.init(hex: 0xFFD3A5), .init(hex: 0xF4A987)])
        case .laughing:    Look(eyeOpen: 0.5, eyeSmile: 1, mouthCurve: 1, mouthOpen: 0.7, brow: 0.1, look: .zero, blush: 0.55, tint: [.init(hex: 0xFFE29A), .init(hex: 0xF7B267)])
        case .curious:     Look(eyeOpen: 0.85, eyeSmile: 0, mouthCurve: 0.15, mouthOpen: 0.1, brow: -0.25, look: CGSize(width: 3, height: -1), blush: 0.1, tint: [.init(hex: 0xCDB4F6), .init(hex: 0x9C89D9)])
        case .thinking:    Look(eyeOpen: 0.6, eyeSmile: 0, mouthCurve: 0, mouthOpen: 0, brow: 0.3, look: CGSize(width: 4, height: -5), blush: 0, tint: [.init(hex: 0xB8C6F2), .init(hex: 0x7F95D1)])
        case .concerned:   Look(eyeOpen: 0.7, eyeSmile: 0, mouthCurve: -0.3, mouthOpen: 0, brow: -0.8, look: .zero, blush: 0, tint: [.init(hex: 0xA9C7E8), .init(hex: 0x6E93BF)])
        case .sad:         Look(eyeOpen: 0.45, eyeSmile: 0, mouthCurve: -0.7, mouthOpen: 0, brow: -1, look: CGSize(width: 0, height: 3), blush: 0, tint: [.init(hex: 0x9FB3C8), .init(hex: 0x62788F)])
        case .excited:     Look(eyeOpen: 1, eyeSmile: 0.3, mouthCurve: 0.9, mouthOpen: 0.55, brow: -0.2, look: .zero, blush: 0.5, tint: [.init(hex: 0xFFB5A7), .init(hex: 0xF07F6E)])
        case .mischievous: Look(eyeOpen: 0.4, eyeSmile: 0.5, mouthCurve: 0.55, mouthOpen: 0, brow: 1, look: CGSize(width: -4, height: 0), blush: 0.2, tint: [.init(hex: 0xE3A6E8), .init(hex: 0xA86BC2)])
        case .love:        Look(eyeOpen: 0.5, eyeSmile: 0.9, mouthCurve: 0.7, mouthOpen: 0.05, brow: -0.2, look: .zero, blush: 0.8, tint: [.init(hex: 0xFFC1CF), .init(hex: 0xE88AA6)])
        case .proud:       Look(eyeOpen: 0.5, eyeSmile: 0.7, mouthCurve: 0.75, mouthOpen: 0.05, brow: 0.5, look: CGSize(width: 0, height: -2), blush: 0.3, tint: [.init(hex: 0xF9E1A0), .init(hex: 0xDDB45E)])
        case .listening:   Look(eyeOpen: 0.9, eyeSmile: 0.1, mouthCurve: 0.2, mouthOpen: 0.08, brow: -0.15, look: .zero, blush: 0.15, tint: [.init(hex: 0xA8E6E0), .init(hex: 0x6CC3BA)])
        }
    }

    static func parse(_ s: String) -> Mood? {
        Mood(rawValue: s.lowercased().trimmingCharacters(in: .whitespaces))
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

/// The live face: breathes, blinks, glances, and talks.
struct FaceView: View {
    var mood: Mood
    var speaking: Bool
    var level: Float        // mic loudness while listening
    var size: CGFloat = 150

    var body: some View {
        let l = mood.look
        TimelineView(.animation) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            let breathe = 1 + 0.025 * sin(t * 1.3)
            let blinking = (t.truncatingRemainder(dividingBy: 4.7)) < 0.13
            let talk = speaking ? CGFloat(0.25 + 0.3 * abs(sin(t * 9)) * abs(sin(t * 3.7))) : 0
            let bob = speaking ? 2 * sin(t * 4) : 1.5 * sin(t * 0.9)

            ZStack {
                // halo
                Circle()
                    .fill(RadialGradient(colors: [l.tint[0].opacity(0.45), .clear], center: .center, startRadius: size * 0.3, endRadius: size * 0.85))
                    .frame(width: size * 1.7, height: size * 1.7)
                    .scaleEffect(1 + CGFloat(level) * 0.35 + 0.03 * sin(t * 1.3))

                // head
                Circle()
                    .fill(LinearGradient(colors: l.tint, startPoint: .topLeading, endPoint: .bottomTrailing))
                    .overlay(Circle().fill(RadialGradient(colors: [.white.opacity(0.35), .clear], center: UnitPoint(x: 0.3, y: 0.25), startRadius: 0, endRadius: size * 0.5)))
                    .shadow(color: l.tint[1].opacity(0.5), radius: 20, y: 8)
                    .frame(width: size, height: size)

                // blush
                HStack(spacing: size * 0.42) {
                    Circle().fill(Color(hex: 0xFF8FA3).opacity(l.blush * 0.55)).frame(width: size * 0.16).blur(radius: 5)
                    Circle().fill(Color(hex: 0xFF8FA3).opacity(l.blush * 0.55)).frame(width: size * 0.16).blur(radius: 5)
                }
                .offset(y: size * 0.1)

                // eyes + brows
                HStack(spacing: size * 0.2) {
                    eye(l, blinking: blinking, side: -1)
                    eye(l, blinking: blinking, side: 1)
                }
                .offset(x: l.look.width, y: -size * 0.06 + l.look.height)

                // mouth
                MouthShape(curve: l.mouthCurve, open: max(l.mouthOpen, talk))
                    .fill(Color(hex: 0x2B2640).opacity(0.85))
                    .overlay(MouthShape(curve: l.mouthCurve, open: max(l.mouthOpen, talk)).stroke(Color(hex: 0x2B2640).opacity(0.85), style: .init(lineWidth: size * 0.025, lineCap: .round, lineJoin: .round)))
                    .frame(width: size * 0.3, height: size * 0.12)
                    .offset(y: size * 0.2)
            }
            .scaleEffect(breathe)
            .offset(y: bob)
        }
        .animation(.spring(response: 0.6, dampingFraction: 0.7), value: mood)
        .frame(width: size * 1.7, height: size * 1.5)
    }

    private func eye(_ l: Mood.Look, blinking: Bool, side: CGFloat) -> some View {
        VStack(spacing: size * 0.045) {
            Capsule()
                .fill(Color(hex: 0x2B2640).opacity(0.7))
                .frame(width: size * 0.13, height: size * 0.028)
                .rotationEffect(.degrees(Double(side * l.brow * -18)))
                .offset(y: CGFloat(abs(l.brow)) * -1)
            EyeShape(open: blinking ? 0.05 : l.eyeOpen, smile: l.eyeSmile)
                .fill(Color(hex: 0x2B2640).opacity(0.9))
                .frame(width: size * 0.12, height: size * 0.14)
        }
    }
}

struct EyeShape: Shape {
    var open: CGFloat
    var smile: CGFloat
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(open, smile) }
        set { open = newValue.first; smile = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        let midY = r.midY, h = r.height / 2 * max(open, 0.05)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: midY))
        p.addCurve(to: CGPoint(x: r.maxX, y: midY),
                   control1: CGPoint(x: r.minX, y: midY - h * 1.3), control2: CGPoint(x: r.maxX, y: midY - h * 1.3))
        let bottom = midY + h * 1.3 * (1 - 1.6 * smile)
        p.addCurve(to: CGPoint(x: r.minX, y: midY),
                   control1: CGPoint(x: r.maxX, y: bottom), control2: CGPoint(x: r.minX, y: bottom))
        p.closeSubpath()
        return p
    }
}

struct MouthShape: Shape {
    var curve: CGFloat
    var open: CGFloat
    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { .init(curve, open) }
        set { curve = newValue.first; open = newValue.second }
    }

    func path(in r: CGRect) -> Path {
        let midY = r.midY - curve * r.height * 0.4
        let top = midY + curve * r.height
        let bottom = top + open * r.height * 1.6
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: midY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: midY), control: CGPoint(x: r.midX, y: top))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: midY), control: CGPoint(x: r.midX, y: bottom))
        p.closeSubpath()
        return p
    }
}
