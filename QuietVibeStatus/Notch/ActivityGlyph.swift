import SwiftUI

/// How the "something is running" indicator animates.
enum ActivityAnimation: String, CaseIterable, Identifiable {
    case equalizer
    case pulse
    case wave
    case chomp
    case bug

    var id: String { rawValue }

    var title: String {
        switch self {
        case .equalizer: return "Equalizer"
        case .pulse: return "Pulse"
        case .wave: return "Wave"
        case .chomp: return "Chomp"
        case .bug: return "Bug"
        }
    }

    var subtitle: String {
        switch self {
        case .equalizer: return "Pixel bars rising and falling"
        case .pulse: return "A single block breathing"
        case .wave: return "A ripple travelling across"
        case .chomp: return "A pixel muncher eating its way along"
        case .bug: return "A pixel critter with a pulsing bar"
        }
    }
}

/// The pixel-art activity indicator.
///
/// Every style animates one plain value — a frame height or an opacity — and gets its stepped look
/// from *layout*, never from a mask or a per-frame timeline. Masking the column was the previous
/// approach and it stopped the animation dead: the mask is rebuilt on each render, which discards
/// the in-flight implicit animation on the thing being masked.
struct ActivityGlyph: View {
    let active: Bool
    let color: Color
    var size: CGFloat = 12

    @EnvironmentObject private var prefs: Preferences
    /// Lets the Settings picker show all three styles side by side, independent of what's saved.
    @Environment(\.activityAnimationOverride) private var override

    var body: some View {
        Group {
            switch override ?? prefs.activityAnimation {
            case .equalizer: EqualizerGlyph(active: active, color: color, size: size)
            case .pulse: PulseGlyph(active: active, color: color, size: size)
            case .wave: WaveGlyph(active: active, color: color, size: size)
            case .chomp: ChompGlyph(active: active, color: color, size: size)
            case .bug: BugGlyph(active: active, color: color, size: size)
            }
        }
        // Height-constrained only. The sprite styles are wider than they are tall, and forcing a
        // square would clip the muncher's dots and the critter's bar.
        .frame(height: size)
        .animation(Theme.ease, value: color)
    }
}

// MARK: - Equalizer

private struct EqualizerGlyph: View {
    let active: Bool
    let color: Color
    let size: CGFloat

    private let columns: [(low: CGFloat, high: CGFloat, duration: Double, delay: Double)] = [
        (0.30, 0.62, 0.52, 0.00),
        (0.20, 1.00, 0.43, 0.13),
        (0.38, 0.80, 0.61, 0.07),
        (0.24, 0.92, 0.47, 0.21),
    ]

    var body: some View {
        HStack(alignment: .bottom, spacing: max(1, size * 0.08)) {
            ForEach(columns.indices, id: \.self) { index in
                PixelBar(
                    spec: columns[index],
                    color: color,
                    active: active,
                    total: size,
                    thickness: max(2, size * 0.17)
                )
            }
        }
    }
}

private struct PixelBar: View {
    let spec: (low: CGFloat, high: CGFloat, duration: Double, delay: Double)
    let color: Color
    let active: Bool
    let total: CGFloat
    let thickness: CGFloat

    /// Tracks `active` for the view's lifetime so the repeating animation re-arms whenever work
    /// starts. Setting it once on appear left a glyph that mounted idle stuck forever.
    @State private var raised = false

    var body: some View {
        // The squares are drawn at full height and revealed by an animating frame. Animating a
        // frame height is something SwiftUI interpolates natively; the stepped look comes from
        // clipping whole squares rather than from any per-frame maths.
        pixels
            .frame(height: raised ? total * spec.high : total * spec.low, alignment: .bottom)
            .clipped()
            .frame(height: total, alignment: .bottom)
            .animation(raised ? loop : Theme.ease, value: raised)
            .onAppear { raised = active }
            .onChange(of: active) { _, isActive in raised = isActive }
    }

    private var pixels: some View {
        VStack(spacing: max(1, thickness * 0.3)) {
            ForEach(0 ..< Int(ceil(total / thickness)) + 1, id: \.self) { _ in
                RoundedRectangle(cornerRadius: thickness * 0.25, style: .continuous)
                    .fill(color)
                    .frame(width: thickness, height: thickness)
            }
        }
    }

    private var loop: Animation {
        .easeInOut(duration: spec.duration)
            .repeatForever(autoreverses: true)
            .delay(spec.delay)
    }
}

// MARK: - Pulse

private struct PulseGlyph: View {
    let active: Bool
    let color: Color
    let size: CGFloat

    @State private var big = false

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
            .fill(color)
            .frame(width: size * 0.62, height: size * 0.62)
            .scaleEffect(active && big ? 1.0 : 0.55)
            .opacity(active ? (big ? 1 : 0.45) : 0.5)
            .animation(
                active
                    ? .easeInOut(duration: 0.75).repeatForever(autoreverses: true)
                    : Theme.ease,
                value: big
            )
            .onAppear { big = active }
            .onChange(of: active) { _, isActive in big = isActive }
    }
}

// MARK: - Wave

private struct WaveGlyph: View {
    let active: Bool
    let color: Color
    let size: CGFloat

    private let count = 3

    var body: some View {
        HStack(spacing: max(1.5, size * 0.12)) {
            ForEach(0 ..< count, id: \.self) { index in
                WaveDot(
                    color: color,
                    active: active,
                    dot: max(2.5, size * 0.24),
                    delay: Double(index) * 0.16
                )
            }
        }
    }
}

private struct WaveDot: View {
    let color: Color
    let active: Bool
    let dot: CGFloat
    let delay: Double

    @State private var lifted = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: dot, height: dot)
            .offset(y: active && lifted ? -dot * 0.7 : dot * 0.35)
            .opacity(active ? (lifted ? 1 : 0.4) : 0.55)
            .animation(
                active
                    ? .easeInOut(duration: 0.5).repeatForever(autoreverses: true).delay(delay)
                    : Theme.ease,
                value: lifted
            )
            .onAppear { lifted = active }
            .onChange(of: active) { _, isActive in lifted = isActive }
    }
}


private struct ActivityAnimationOverrideKey: EnvironmentKey {
    static let defaultValue: ActivityAnimation? = nil
}

extension EnvironmentValues {
    var activityAnimationOverride: ActivityAnimation? {
        get { self[ActivityAnimationOverrideKey.self] }
        set { self[ActivityAnimationOverrideKey.self] = newValue }
    }
}


// MARK: - Pixel sprites

/// Steps through discrete frames on a timer.
///
/// Sprite animation is frame-based by nature — the whole look depends on snapping between drawings
/// rather than smoothly interpolating between them, which is exactly what SwiftUI's implicit
/// animations do. So these styles tick instead. The tick is deliberately slow (a few frames per
/// second, and only while work is happening) rather than display-linked: a 60fps invalidation
/// inside the panel is what previously wedged its expand transition.
private struct SpriteFrames<Content: View>: View {
    let active: Bool
    let interval: Double
    let frameCount: Int
    @ViewBuilder let content: (Int) -> Content

    @State private var frame = 0

    var body: some View {
        content(active ? frame : 0)
            .onReceive(Timer.publish(every: interval, on: .main, in: .common).autoconnect()) { _ in
                guard active else { return }
                frame = (frame + 1) % frameCount
            }
    }
}

/// Draws a sprite from a bitmap, one square per set bit.
private struct PixelSprite: View {
    /// Rows of `#` (lit) and anything else (empty).
    let rows: [String]
    let color: Color
    let pixel: CGFloat
    var dimmed: Bool = false

    var body: some View {
        VStack(spacing: 0) {
            ForEach(rows.indices, id: \.self) { row in
                HStack(spacing: 0) {
                    ForEach(Array(rows[row].enumerated()), id: \.offset) { _, character in
                        Rectangle()
                            .fill(character == "#" ? color : .clear)
                            .frame(width: pixel, height: pixel)
                    }
                }
            }
        }
        .opacity(dimmed ? 0.45 : 1)
    }
}

// MARK: - Chomp

private struct ChompGlyph: View {
    let active: Bool
    let color: Color
    let size: CGFloat

    /// Mouth shut, then progressively wider — a 4-frame cycle reads as a chomp at this scale.
    private static let mouths: [[String]] = [
        [
            ".#####.",
            "#######",
            "#######",
            "#######",
            "#######",
            "#######",
            ".#####.",
        ],
        [
            ".#####.",
            "#######",
            "####...",
            "#####..",
            "####...",
            "#######",
            ".#####.",
        ],
        [
            ".#####.",
            "###....",
            "##.....",
            "#......",
            "##.....",
            "###....",
            ".#####.",
        ],
        [
            ".#####.",
            "#######",
            "####...",
            "#####..",
            "####...",
            "#######",
            ".#####.",
        ],
    ]

    private var pixel: CGFloat { max(1.5, size / 7) }

    var body: some View {
        SpriteFrames(active: active, interval: 0.13, frameCount: Self.mouths.count) { frame in
            HStack(spacing: pixel) {
                PixelSprite(rows: Self.mouths[frame], color: color, pixel: pixel)

                // The pellets ahead get eaten as it advances, then the row refills.
                HStack(spacing: pixel) {
                    ForEach(0 ..< 2, id: \.self) { index in
                        Rectangle()
                            .fill(color)
                            .frame(width: pixel, height: pixel)
                            .opacity(active && index < frame / 2 ? 0.15 : 1)
                    }
                }
            }
        }
    }
}

// MARK: - Bug

private struct BugGlyph: View {
    let active: Bool
    let color: Color
    let size: CGFloat

    /// Two-frame critter — the classic legs-up / legs-down swap.
    private static let frames: [[String]] = [
        [
            "..#.#..",
            ".#####.",
            "##.#.##",
            "#######",
            "#.###.#",
            "#.#.#.#",
            "..#.#..",
        ],
        [
            "..#.#..",
            ".#####.",
            "##.#.##",
            "#######",
            "#.###.#",
            ".#...#.",
            "#.#.#.#",
        ],
    ]

    private var pixel: CGFloat { max(1.5, size / 7) }

    var body: some View {
        HStack(spacing: pixel * 1.5) {
            SpriteFrames(active: active, interval: 0.22, frameCount: Self.frames.count) { frame in
                PixelSprite(rows: Self.frames[frame], color: color, pixel: pixel)
            }

            PulsingBar(active: active, color: color, height: size, width: pixel * 1.2)
        }
    }
}

private struct PulsingBar: View {
    let active: Bool
    let color: Color
    let height: CGFloat
    let width: CGFloat

    @State private var tall = false

    var body: some View {
        RoundedRectangle(cornerRadius: width * 0.3, style: .continuous)
            .fill(color)
            .frame(width: width, height: active && tall ? height : height * 0.35)
            .frame(height: height, alignment: .center)
            .opacity(active ? 1 : 0.5)
            .animation(
                active
                    ? .easeInOut(duration: 0.45).repeatForever(autoreverses: true)
                    : Theme.ease,
                value: tall
            )
            .onAppear { tall = active }
            .onChange(of: active) { _, isActive in tall = isActive }
    }
}
