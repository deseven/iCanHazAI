import AppKit
import QuartzCore

/// How a streaming reply eases in. A value of 0 turns that effect off.
@MainActor
enum StreamingMotion {
    /// Newly arrived text fades in over this long.
    nonisolated static let fadeDuration: CFTimeInterval = 0.12
    /// A list pinned to the bottom glides to the new bottom as the reply grows, as a
    /// critically damped spring: it covers about 60% of the way in this long and about
    /// 90% in twice that, starting and ending gently.
    nonisolated static let scrollSmoothTime: CFTimeInterval = 0.1

    static var fades: Bool { fadeDuration > 0 && !reduced }
    static var glides: Bool { scrollSmoothTime > 0 && !reduced }

    /// Advances a critically damped spring toward `target` by `dt`. The velocity carries
    /// over, so a target that moves mid-glide bends the motion instead of restarting it,
    /// and the position never overshoots the target. The step is a closed-form
    /// approximation (Unity's SmoothDamp) that is only accurate for short steps, so a
    /// long frame is split up: a stall then follows the path the lost frames would have.
    nonisolated static func smoothDamp(
        from position: CGFloat, to target: CGFloat, velocity: CGFloat, smoothTime: CFTimeInterval, dt: CFTimeInterval
    ) -> (position: CGFloat, velocity: CGFloat) {
        let maxStep: CFTimeInterval = 1.0 / 60
        let steps = max(1, Int((dt / maxStep).rounded(.up)))
        let h = CGFloat(dt / Double(steps))
        let omega = CGFloat(2 / max(smoothTime, 0.0001))
        let x = omega * h
        let decay = 1 / (1 + x + 0.48 * x * x + 0.235 * x * x * x)
        var position = position
        var velocity = velocity
        for _ in 0..<steps {
            let change = position - target
            let temp = (velocity + omega * change) * h
            velocity = (velocity - omega * temp) * decay
            let next = target + (change + temp) * decay
            // Crossing the target (only possible once the target has moved) lands on it.
            if (target - position > 0) == (next > target) {
                position = target
                velocity = 0
                break
            }
            position = next
        }
        return (position, velocity)
    }

    private static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}

/// Text that is still fading in. Ranges are in the text storage's characters;
/// the alpha is computed from the clock when drawing, so a fade needs no
/// per-frame bookkeeping beyond asking for a redraw.
struct TextFade: Equatable {
    var range: NSRange
    let start: CFTimeInterval
    let duration: CFTimeInterval

    func isRunning(at now: CFTimeInterval) -> Bool { now - start < duration }

    func alpha(at now: CFTimeInterval) -> CGFloat {
        guard duration > 0 else { return 1 }
        return CGFloat(min(max((now - start) / duration, 0), 1))
    }
}

/// Calls `step` once per display frame, with the time since the previous one,
/// until it returns false. The link only exists while it's running.
@MainActor
final class FrameTicker: NSObject {
    private let step: @MainActor (CFTimeInterval) -> Bool
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0

    init(step: @escaping @MainActor (CFTimeInterval) -> Bool) {
        self.step = step
    }

    var isRunning: Bool { link != nil }

    func start(in view: NSView) {
        guard link == nil, view.window != nil else { return }
        let link = view.displayLink(target: self, selector: #selector(fire(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
        lastTimestamp = 0
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func fire(_ link: CADisplayLink) {
        let dt = lastTimestamp == 0 ? link.duration : min(link.timestamp - lastTimestamp, 0.1)
        lastTimestamp = link.timestamp
        if !step(max(dt, 0.001)) { stop() }
    }
}
