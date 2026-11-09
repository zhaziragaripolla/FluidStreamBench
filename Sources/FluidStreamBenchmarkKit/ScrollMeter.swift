public import FluidStreamCore

/// The result of one scroll gesture, from when the content starts moving under a finger
/// until it comes to rest (RFC-004 Addendum A).
public struct ScrollSessionStats: Sendable, Equatable {
    /// 1 for the first scroll of the run, 2 for the second, and so on.
    public let index: Int
    public let droppedFrames: Int
    /// Seconds of hitch during this scroll.
    public let hitchTime: Double
    /// Seconds.
    public let duration: Double
    public let frames: Int
}

/// Splits frame timings into scroll sessions.
///
/// Feed it every frame tick. Only ticks between `begin()` and `end()` count. Each session
/// gets its own `HitchAccumulator`, so a slow frame before the finger touched down never
/// leaks into the scroll's numbers.
public struct ScrollSessionMeter: Sendable, Equatable {
    public private(set) var sessions: [ScrollSessionStats] = []
    private var current: HitchAccumulator?

    public init() {}

    public var isInSession: Bool { current != nil }

    public mutating func begin() {
        guard current == nil else { return }
        current = HitchAccumulator()
    }

    public mutating func record(_ tick: FrameTick) {
        current?.record(tick)
    }

    public mutating func end() {
        guard let session = current else { return }
        current = nil
        guard session.frames > 0 else { return }       // a touch that never produced a frame
        sessions.append(ScrollSessionStats(
            index: sessions.count + 1,
            droppedFrames: session.droppedFrames,
            hitchTime: session.totalHitchTime,
            duration: session.duration,
            frames: session.frames
        ))
    }

    public var summary: ScrollSummary { ScrollSummary(sessions: sessions) }
}

/// The distribution of per-scroll results, focused on the bad tail users remember.
public struct ScrollSummary: Sendable, Equatable {
    public let sessions: [ScrollSessionStats]
    private let sortedDropped: [Int]
    private let sortedHitchMilliseconds: [Double]

    public init(sessions: [ScrollSessionStats]) {
        self.sessions = sessions
        sortedDropped = sessions.map(\.droppedFrames).sorted()
        sortedHitchMilliseconds = sessions.map { $0.hitchTime * 1000 }.sorted()
    }

    public var count: Int { sessions.count }

    /// The share of scrolls that dropped at least one frame.
    public var jankyScrollRate: Double? {
        count > 0 ? Double(sortedDropped.filter { $0 > 0 }.count) / Double(count) : nil
    }

    public var medianDroppedFrames: Int? { nearestRank(sortedDropped, numerator: 1, denominator: 2) }
    public var maxDroppedFrames: Int? { sortedDropped.last }

    /// "1 in `n` scrolls drops at least this many frames": the nearest-rank percentile at
    /// 1 − 1/n (1 in 16 is p93.75, 1 in 32 is p96.9). Returns `nil` until there are
    /// `minimumScrolls(oneIn:)` scrolls, so the tail rests on at least 3 samples.
    public func droppedFrames(oneIn n: Int) -> Int? {
        guard count >= Self.minimumScrolls(oneIn: n) else { return nil }
        return nearestRank(sortedDropped, numerator: n - 1, denominator: n)
    }

    /// The same tail, as milliseconds of hitch in one scroll.
    public func hitchMilliseconds(oneIn n: Int) -> Double? {
        guard count >= Self.minimumScrolls(oneIn: n) else { return nil }
        return nearestRank(sortedHitchMilliseconds, numerator: n - 1, denominator: n)
    }

    public static func minimumScrolls(oneIn n: Int) -> Int {
        precondition(n >= 2)
        return 3 * n
    }

    /// The nearest-rank percentile at `numerator / denominator`, in integer arithmetic so
    /// a rank can't drift through floating-point rounding.
    private func nearestRank<T>(_ sorted: [T], numerator: Int, denominator: Int) -> T? {
        guard !sorted.isEmpty else { return nil }
        let rank = (sorted.count * numerator + denominator - 1) / denominator   // ceil
        return sorted[max(rank, 1) - 1]
    }
}
