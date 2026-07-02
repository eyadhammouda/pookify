import SwiftUI
import AppKit
import IslandCore

// MARK: - Decoded assets

/// The Claude "thinking spark" frames. Alpha masks baked orange once via `.destinationIn` so
/// SwiftUI just blits the finished sunburst.
enum SparkAssets {
    private static let masks: [NSImage] = claudeSparkFramePNGs.compactMap {
        Data(base64Encoded: $0).flatMap(NSImage.init(data:))
    }
    private static let orange = NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1)
    static let tinted: [NSImage] = masks.map { mask in
        NSImage(size: NSSize(width: 120, height: 120), flipped: false) { rect in
            orange.setFill(); rect.fill()
            mask.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1.0)
            return true
        }
    }

    /// The COMPLETE Claude mark (not a morph frame) — a full sunburst with every ray. Shown static
    /// when the spark isn't animating (done/resting) so it reads as the whole logo, never cut off.
    static let logoTinted: NSImage? = {
        guard let logo = Data(base64Encoded: claudeLogoPNG).flatMap(NSImage.init(data:)) else { return nil }
        return NSImage(size: NSSize(width: 120, height: 120), flipped: false) { rect in
            orange.setFill(); rect.fill()
            logo.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1.0)
            return true
        }
    }()
}

/// The Clawd crab walk cycle (20 full-color pixel-art frames): the little crab that scuttles while
/// Claude works.
enum CrabAssets {
    static let frames: [NSImage] = clawdCrabFramePNGs.compactMap {
        Data(base64Encoded: $0).flatMap(NSImage.init(data:))
    }
}

// MARK: - Animated glyphs

/// Cycles pre-tinted frames (Claude spark). Driven from absolute time; the timeline samples at
/// ~2× the frame rate (not the display's 120Hz) and pauses entirely while static, so the output
/// is pixel-identical at a fraction of the CPU.
struct FrameSparkView: View {
    let frames: [NSImage]
    var fps: Double = 9
    var size: CGFloat = 18
    var animate: Bool = true
    var restIndex: Int = 0   // frame to hold on when not animating (the "full" pose)
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / (fps * 2), paused: !animate)) { context in
            let idx = frames.isEmpty ? 0
                : (animate ? Int(context.date.timeIntervalSinceReferenceDate * fps) % frames.count
                           : min(max(0, restIndex), frames.count - 1))
            Group {
                if frames.indices.contains(idx) {
                    Image(nsImage: frames[idx]).resizable().interpolation(.high)
                } else {
                    Circle().fill(Theme.accent(.claude)).frame(width: size * 0.5, height: size * 0.5)
                }
            }
            .frame(width: size, height: size)
        }
        .frame(width: size, height: size)
    }
}

/// The Clawd crab, walking (frame cycle) while working, still otherwise. Pixel-art, so nearest-
/// neighbour scaling keeps it crisp.
struct CrabWalkView: View {
    var fps: Double = 12.5
    var size: CGFloat = 18
    var animate: Bool = true
    var body: some View {
        let frames = CrabAssets.frames
        // Sample at ~2× the walk's frame rate and pause while still: identical frames, ~10× less
        // redraw work than the display-refresh-rate default.
        TimelineView(.animation(minimumInterval: 1.0 / (fps * 2), paused: !animate)) { context in
            let n = frames.count
            let tick = (animate && n > 0) ? Int(context.date.timeIntervalSinceReferenceDate * fps) : 0
            let idx = n > 0 ? tick % n : 0
            // The sprite faces one way, so flip it horizontally on every other full walk cycle:
            // the crab paces in one direction, turns around, and paces back — instead of only ever
            // facing right.
            let facingLeft = (animate && n > 0) && (tick / n) % 2 == 1
            Group {
                if frames.indices.contains(idx) {
                    Image(nsImage: frames[idx]).resizable().interpolation(.none).aspectRatio(contentMode: .fit)
                } else {
                    Circle().fill(Theme.accent(.claude)).frame(width: size * 0.5, height: size * 0.5)
                }
            }
            .frame(width: size, height: size)
            .scaleEffect(x: facingLeft ? -1 : 1, y: 1, anchor: .center)
        }
        .frame(width: size, height: size)
    }
}

/// The Claude working-glyph styles the user can pick between.
enum ClaudeStyle: String, CaseIterable {
    case spark   // the official orange thinking-spark
    case crab    // Clawd, the pixel-art crab, walking
}

/// The agent's identity mark — ALWAYS shown on the left wing, in a fixed position regardless of
/// state (so it never jumps around). Animates while working, rests otherwise. The status itself
/// (timer / check / amber dot / warning) is shown separately on the right wing.
struct AgentGlyph: View {
    let provider: Provider
    var claudeStyle: ClaudeStyle = .spark
    var working: Bool = true
    var size: CGFloat = 18

    @ViewBuilder var body: some View {
        if claudeStyle == .crab {
            CrabWalkView(size: size, animate: working)
        } else if working {
            // morphing thinking-spark while active
            FrameSparkView(frames: SparkAssets.tinted, size: size, animate: true)
        } else if let logo = SparkAssets.logoTinted {
            // resting/done → the COMPLETE Claude logo, static (full, never cut off)
            Image(nsImage: logo).resizable().interpolation(.high)
                .frame(width: size, height: size)
        } else {
            // Degenerate fallback (only if the logo asset failed to decode): a paused spark.
            FrameSparkView(frames: SparkAssets.tinted, size: size, animate: false)
        }
    }
}
