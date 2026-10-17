// Copyright (C) 2026 Ivan Novohatski <https://d7.wtf/>
// SPDX-License-Identifier: AGPL-3.0-or-later

import CoreGraphics
import QuartzCore

/// A time-based ease-out interpolation toward a value that can be retargeted
/// at any moment. The clock is supplied by the caller, so the math is pure.
///
/// Retargeting starts from the *current* value, never from the previous
/// target, so a keystroke that lands mid-animation continues smoothly from
/// whatever is on screen instead of jumping.
struct ValueTween {
    private(set) var value: CGFloat
    private(set) var target: CGFloat
    private var origin: CGFloat
    private var startTime: CFTimeInterval = 0
    private var duration: CFTimeInterval = 0

    init(value: CGFloat) {
        self.value = value
        self.target = value
        self.origin = value
    }

    var isFinished: Bool { value == target }

    /// Starts moving from the current value toward `newTarget`.
    mutating func retarget(to newTarget: CGFloat, now: CFTimeInterval, duration: CFTimeInterval) {
        guard newTarget != target || value != target else { return }
        origin = value
        target = newTarget
        startTime = now
        self.duration = duration
        if duration <= 0 { value = newTarget }
    }

    /// Snaps to `newTarget`, cancelling any animation in flight.
    mutating func jump(to newTarget: CGFloat) {
        value = newTarget
        target = newTarget
        origin = newTarget
    }

    /// Advances the animation to `now` and returns the new value.
    @discardableResult
    mutating func advance(now: CFTimeInterval) -> CGFloat {
        guard value != target else { return value }
        let t = duration > 0 ? min(max((now - startTime) / duration, 0), 1) : 1
        value = t >= 1 ? target : origin + (target - origin) * Self.easeOut(CGFloat(t))
        return value
    }

    /// Cubic ease-out: fast start, gentle landing.
    static func easeOut(_ t: CGFloat) -> CGFloat {
        let inverse = 1 - t
        return 1 - inverse * inverse * inverse
    }
}
