public import FluidStreamCore
public import Observation

/// Accumulates frame timings into Apple's **hitch time ratio**: milliseconds of hitch per
/// second of run time. Xcode Organizer and Instruments report the same metric.
///
/// A frame is a hitch when it's displayed more than half a frame later than expected. Its
/// hitch time is how late it was. This is an in-app approximation: it sees main-thread
/// lateness but not render-server hitches. For published numbers, use Instruments (RFC-004).
public struct HitchAccumulator: Sendable, Equatable {
    public enum Rating: String, Sendable {
        case good, warning, critical
    }

    public private(set) var frames = 0
    public private(set) var hitches = 0
    /// Display refreshes that passed without a new frame (see `droppedFrames(actual:expected:)`).
    public private(set) var droppedFrames = 0
    /// Seconds.
    public private(set) var totalHitchTime = 0.0
    /// Seconds. The longest interval between two frames.
    public private(set) var worstFrameInterval = 0.0
    /// Seconds of measured time: the sum of the frame intervals counted, so excluded gaps
    /// (see `breakContinuity()`) don't dilute the ratio.
    public private(set) var duration = 0.0
    private var previous: FrameTick?

    public init() {}

    public mutating func record(_ tick: FrameTick) {
        defer { previous = tick }
        guard let previous else { return }
        let actual = tick.timestamp - previous.timestamp
        let expected = previous.targetTimestamp - previous.timestamp
        guard actual > 0, expected > 0 else { return }
        frames += 1
        duration += actual
        worstFrameInterval = max(worstFrameInterval, actual)
        let lateness = actual - expected
        if lateness > expected / 2 {
            hitches += 1
            totalHitchTime += lateness
            droppedFrames += Self.droppedFrames(actual: actual, expected: expected)
        }
    }

    /// The number of refreshes skipped in one frame interval: a 25 ms gap at 120 Hz
    /// (8.33 ms per frame) skips 2. It's ≥ 1 exactly when the interval counts as a hitch,
    /// so the two metrics never disagree about whether a frame was late.
    public static func droppedFrames(actual: Double, expected: Double) -> Int {
        guard expected > 0, actual > expected * 1.5 else { return 0 }
        return max(1, Int((actual / expected).rounded()) - 1)
    }

    /// Forgets the previous frame, so the next interval isn't measured across a gap that
    /// shouldn't count, such as time the app spent inactive behind Control Center.
    public mutating func breakContinuity() {
        previous = nil
    }

    /// Milliseconds of hitch per second.
    public var hitchTimeRatio: Double {
        duration > 0 ? totalHitchTime * 1000 / duration : 0
    }

    /// Apple's thresholds: below 5 ms/s is good, 5–10 is a warning, above 10 is critical.
    public var rating: Rating {
        switch hitchTimeRatio {
        case ..<5: .good
        case ..<10: .warning
        default: .critical
        }
    }
}

/// One entry in the per-hitch log: when it happened, how bad it was, and what was going on.
public struct HitchEvent: Sendable, Equatable {
    public enum Context: Sendable, Equatable {
        case duringScroll
        /// Milliseconds since the most recent scroll came to rest.
        case afterScroll(milliseconds: Double)
        case none
        /// Not a hitch: the app was inactive (Control Center, notifications, app switcher) for
        /// this long, and the gap was excluded from every metric.
        case excludedInactive
    }

    /// Seconds since recording began.
    public let time: Double
    /// Milliseconds the frame took, or the gap length for `.excludedInactive`.
    public let duration: Double
    public let droppedFrames: Int
    /// The display's refresh rate at that moment, from the frame's expected duration.
    public let refreshRate: Double
    public let context: Context

    /// One line for the log view and for copying, e.g.
    /// "12.34 s  hitch 133.2 ms, 7 dropped @ 60 Hz  (1.2 s after a scroll)".
    public var line: String {
        let t = String(format: "%7.2f s", time)
        if context == .excludedInactive {
            return "\(t)  app inactive for \(String(format: "%.0f", duration)) ms (excluded)"
        }
        let what = String(format: "hitch %.1f ms, %d dropped @ %.0f Hz", duration, droppedFrames, refreshRate)
        switch context {
        case .duringScroll: return "\(t)  \(what)  (during a scroll)"
        case .afterScroll(let ms): return "\(t)  \(what)  (\(String(format: "%.0f", ms)) ms after a scroll)"
        case .none, .excludedInactive: return "\(t)  \(what)"
        }
    }
}

/// Feeds a `HitchAccumulator` from its own frame ticker, and publishes a snapshot for the
/// HUD at a low rate.
///
/// The snapshot updates at most `snapshotsPerSecond` times. A HUD that changed every frame
/// would make SwiftUI do work on every frame, which would skew the very thing being measured.
@MainActor
@Observable
public final class FrameMonitor {
    public private(set) var snapshot = HitchAccumulator()
    /// Per-scroll results for the selected scroll key (one per benchmark mode), accumulated
    /// across runs. A "1 in 32" tail needs 96 scrolls, more than one 40-second run gives.
    /// Updated whenever a scroll ends.
    public private(set) var scrollSummary = ScrollSummary(sessions: [])
    /// Every hitch in the current run, oldest first (capped at `maxLogEntries`). Published with
    /// the snapshot, not on every hitch, so the HUD never re-renders per frame.
    public private(set) var hitchLog: [HitchEvent] = []
    public static let maxLogEntries = 500

    /// How many recorded runs have contributed to `scrollSummary`.
    public private(set) var scrollRuns = 0
    public private(set) var scrollKey = ""

    @ObservationIgnored private var accumulator = HitchAccumulator()
    @ObservationIgnored private var scrollMeters: [String: ScrollSessionMeter] = [:]
    @ObservationIgnored private var runsPerKey: [String: Int] = [:]
    @ObservationIgnored private var log: [HitchEvent] = []
    @ObservationIgnored private var previousTick: FrameTick?
    @ObservationIgnored private var recordingStart: Double?
    @ObservationIgnored private var lastScrollEnd: Double?
    @ObservationIgnored private var isInactive = false
    @ObservationIgnored private let ticker: any FrameTicker
    @ObservationIgnored private let snapshotsPerSecond: Double
    @ObservationIgnored private var lastSnapshotTime: Double?
    @ObservationIgnored private var isRunning = false

    public init(ticker: any FrameTicker, snapshotsPerSecond: Double = 2) {
        self.ticker = ticker
        self.snapshotsPerSecond = snapshotsPerSecond
    }

    /// Frames are only counted while recording. Idle time before or after a run would dilute
    /// the ratio.
    public private(set) var isRecording = false

    /// Starts the ticker. Recording stays off until `beginRecording()`.
    public func start() {
        guard !isRunning else { return }
        isRunning = true
        ticker.start { [weak self] tick in self?.record(tick) }
        ticker.isPaused = false
    }

    /// Clears the run's hitch results and starts counting frames. Scroll results for the
    /// current scroll key carry over from earlier runs.
    public func beginRecording() {
        clearRun()
        runsPerKey[scrollKey, default: 0] += 1
        publishScrolls()
        isRecording = true
    }

    /// Clears the run's hitch results without recording, so the HUD reads zero until the next
    /// run's first packet arrives. Scroll results are kept.
    public func reset() {
        isRecording = false
        clearRun()
    }

    /// Selects which bucket scroll results go into, for example the benchmark mode, so
    /// FluidStreamKit and Naive SwiftUI scrolls are never mixed. Not while recording.
    public func selectScrollKey(_ key: String) {
        guard !isRecording else { return }
        scrollKey = key
        publishScrolls()
    }

    /// Discards the accumulated scroll results for the current scroll key.
    public func clearScrollStats() {
        guard !isRecording else { return }
        scrollMeters[scrollKey] = nil
        runsPerKey[scrollKey] = nil
        publishScrolls()
    }

    /// Stops counting and publishes the final result.
    public func endRecording() {
        scrollEnded()
        isRecording = false
        snapshot = accumulator
        hitchLog = log
    }

    /// Call when the content starts moving under the user's finger. Has no effect unless
    /// a run is being recorded.
    public func scrollBegan() {
        guard isRecording else { return }
        scrollMeters[scrollKey, default: ScrollSessionMeter()].begin()
    }

    /// Call when a scroll comes to rest.
    public func scrollEnded() {
        guard scrollMeters[scrollKey]?.isInSession == true else { return }
        scrollMeters[scrollKey]?.end()
        lastScrollEnd = previousTick?.timestamp
        publishScrolls()
    }

    /// Call when the app stops being active (Control Center, a notification, the app
    /// switcher). Frames stop counting until `appDidBecomeActive()`.
    public func appWillResignActive() {
        isInactive = true
    }

    /// Call when the app is active again. The gap is excluded from every metric and noted in
    /// the log, so a system interruption can't be mistaken for a hitch.
    public func appDidBecomeActive() {
        guard isInactive else { return }
        isInactive = false
        accumulator.breakContinuity()
        pendingGapStart = previousTick?.timestamp
        previousTick = nil
    }
    @ObservationIgnored private var pendingGapStart: Double?

    private func clearRun() {
        accumulator = HitchAccumulator()
        snapshot = accumulator
        lastSnapshotTime = nil
        log = []
        hitchLog = []
        previousTick = nil
        recordingStart = nil
        lastScrollEnd = nil
        pendingGapStart = nil
    }

    private func publishScrolls() {
        scrollSummary = scrollMeters[scrollKey]?.summary ?? ScrollSummary(sessions: [])
        scrollRuns = runsPerKey[scrollKey] ?? 0
    }

    public func stop() {
        endRecording()
        isRunning = false
        ticker.invalidate()
    }

    private func record(_ tick: FrameTick) {
        guard isRecording, !isInactive else { return }
        if recordingStart == nil { recordingStart = tick.timestamp }
        logIfNeeded(tick)
        accumulator.record(tick)
        if scrollMeters[scrollKey]?.isInSession == true { scrollMeters[scrollKey]?.record(tick) }
        let interval = 1 / snapshotsPerSecond
        if let last = lastSnapshotTime, tick.timestamp - last < interval { return }
        lastSnapshotTime = tick.timestamp
        snapshot = accumulator
        hitchLog = log
    }

    private func logIfNeeded(_ tick: FrameTick) {
        defer { previousTick = tick }
        let time = tick.timestamp - (recordingStart ?? tick.timestamp)
        if let gapStart = pendingGapStart {
            pendingGapStart = nil
            append(HitchEvent(time: time, duration: (tick.timestamp - gapStart) * 1000, droppedFrames: 0,
                              refreshRate: 0, context: .excludedInactive))
            return
        }
        guard let previous = previousTick else { return }
        let actual = tick.timestamp - previous.timestamp
        let expected = previous.targetTimestamp - previous.timestamp
        let dropped = HitchAccumulator.droppedFrames(actual: actual, expected: expected)
        guard dropped > 0 else { return }
        let context: HitchEvent.Context
        if scrollMeters[scrollKey]?.isInSession == true {
            context = .duringScroll
        } else if let end = lastScrollEnd {
            context = .afterScroll(milliseconds: (previous.timestamp - end) * 1000)
        } else {
            context = .none
        }
        append(HitchEvent(time: time, duration: actual * 1000, droppedFrames: dropped,
                          refreshRate: 1 / expected, context: context))
    }

    private func append(_ event: HitchEvent) {
        guard log.count < Self.maxLogEntries else { return }
        log.append(event)
    }
}
