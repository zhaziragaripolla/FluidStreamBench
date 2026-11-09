import Testing
@testable import FluidStreamBenchmarkKit
import FluidStreamCore
import FluidStreamUI

// MARK: - Tokenizer

@Suite("Tokenizer")
struct TokenizerTests {
    @Test func tokensReassembleToTheInput() {
        let text = BenchmarkCorpus.mixedAnswer
        #expect(Tokenizer.tokens(text).joined() == text)
    }

    @Test func longWordsAreCutSoTagsSplitAcrossTokens() {
        #expect(Tokenizer.tokens("<thinking>hi") == ["<thi", "nkin", "g>hi"])
    }

    @Test func averageTokenLengthIsRealistic() {
        let tokens = Tokenizer.tokens(BenchmarkCorpus.mixedAnswer)
        let average = Double(tokens.map(\.count).reduce(0, +)) / Double(tokens.count)
        #expect((3.0...6.5).contains(average), "average \(average)")
    }
}

// MARK: - Simulator

@Suite("TokenStreamSimulator")
struct SimulatorTests {
    @Test func sameSeedSameSchedule() {
        let config = TokenStreamConfiguration(tokenCount: 2_000)
        #expect(TokenStreamSimulator(config).schedule() == TokenStreamSimulator(config).schedule())
    }

    @Test func differentSeedDifferentSchedule() {
        var other = TokenStreamConfiguration(tokenCount: 2_000)
        other.seed = 7
        #expect(TokenStreamSimulator(TokenStreamConfiguration(tokenCount: 2_000)).schedule() != TokenStreamSimulator(other).schedule())
    }

    @Test func packetsDeliverEveryTokenInOrder() {
        let simulator = TokenStreamSimulator(TokenStreamConfiguration(tokenCount: 3_000))
        let schedule = simulator.schedule()
        #expect(schedule.map(\.text).joined() == simulator.tokens().joined())
        #expect(schedule.map(\.tokenCount).reduce(0, +) == 3_000)
        #expect(zip(schedule, schedule.dropFirst()).allSatisfy { $0.time < $1.time })
    }

    @Test func jitterMakesArrivalsBurstyButKeepsTheAverageRate() {
        let config = TokenStreamConfiguration(tokensPerSecond: 150, tokenCount: 6_000)
        let schedule = TokenStreamSimulator(config).schedule()
        let effectiveRate = 6_000 / schedule.last!.time
        #expect(abs(effectiveRate - 150) / 150 < 0.10, "rate \(effectiveRate)")
        #expect(schedule.count < 6_000)                              // grouped into packets
        #expect(schedule.map(\.tokenCount).max()! > 5)               // with real bursts
    }

    @Test func stallsCreateLongGaps() {
        let config = TokenStreamConfiguration(tokenCount: 500, stallProbability: 1)
        let schedule = TokenStreamSimulator(config).schedule()
        let gaps = zip(schedule, schedule.dropFirst()).map { $1.time - $0.time }
        #expect(gaps.allSatisfy { $0 >= 0.2 })
    }

    @Test func withoutJitterTokensArriveOneAtATimeOnCadence() {
        let config = TokenStreamConfiguration(tokensPerSecond: 100, tokenCount: 50, jitterEnabled: false)
        let schedule = TokenStreamSimulator(config).schedule()
        #expect(schedule.count == 50)
        #expect(schedule.allSatisfy { $0.tokenCount == 1 })
        #expect(abs(schedule[9].time - 0.10) < 1e-9)
    }

    @Test func playerDeliversInOrderAndHonoursCancellation() async throws {
        let packets = (1...5).map { StreamPacket(time: Double($0) * 0.002, text: "\($0)", tokenCount: 1) }
        var received: [String] = []
        try await SchedulePlayer(packets).play { received.append($0.text) }
        #expect(received == ["1", "2", "3", "4", "5"])

        let slow = SchedulePlayer([StreamPacket(time: 60, text: "never", tokenCount: 1)])
        let task = Task { try await slow.play { _ in } }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

// MARK: - Hitch measurement

private func ticks(_ intervals: [Double], frame: Double = 1.0 / 120) -> [FrameTick] {
    var t = 0.0
    var result = [FrameTick(timestamp: 0, targetTimestamp: frame)]
    for interval in intervals {
        t += interval
        result.append(FrameTick(timestamp: t, targetTimestamp: t + frame))
    }
    return result
}

@Suite("HitchAccumulator")
struct HitchAccumulatorTests {
    @Test func steadyFramesHaveNoHitches() {
        var meter = HitchAccumulator()
        for tick in ticks(Array(repeating: 1.0 / 120, count: 120)) { meter.record(tick) }
        #expect(meter.frames == 120)
        #expect(meter.hitches == 0)
        #expect(meter.hitchTimeRatio == 0)
        #expect(meter.rating == .good)
    }

    @Test func aLongFrameCountsItsLateness() {
        var meter = HitchAccumulator()
        var intervals = Array(repeating: 1.0 / 120, count: 119)
        intervals[60] = 0.050                                      // one 50 ms frame
        for tick in ticks(intervals) { meter.record(tick) }
        #expect(meter.hitches == 1)
        #expect(abs(meter.totalHitchTime - (0.050 - 1.0 / 120)) < 1e-9)
        #expect(abs(meter.worstFrameInterval - 0.050) < 1e-9)
        // ~41.7 ms of hitch over ~1.03 s ≈ 40 ms/s, which is critical.
        #expect(meter.rating == .critical)
    }

    @Test func slightlyLateFramesAreNotHitches() {
        var meter = HitchAccumulator()
        for tick in ticks(Array(repeating: 1.0 / 120 * 1.4, count: 50)) { meter.record(tick) }
        #expect(meter.hitches == 0)
    }

    @Test func refreshRateDropIsNotAHitch() {
        // When ProMotion drops to 60 Hz, targetTimestamp reflects the new frame duration.
        var meter = HitchAccumulator()
        for tick in ticks(Array(repeating: 1.0 / 60, count: 60), frame: 1.0 / 60) { meter.record(tick) }
        #expect(meter.hitches == 0)
    }

    @Test(arguments: [(4.9, HitchAccumulator.Rating.good), (7.0, .warning), (12.0, .critical)])
    func ratingThresholds(msPerSecond: Double, expected: HitchAccumulator.Rating) {
        // 10 s at 120 Hz with one long frame sized to hit the target ratio.
        var intervals = Array(repeating: 1.0 / 120, count: 1_200)
        intervals[600] += msPerSecond * 10 / 1000
        var meter = HitchAccumulator()
        for tick in ticks(intervals) { meter.record(tick) }
        #expect(meter.rating == expected, "ratio \(meter.hitchTimeRatio)")
    }
}

@Suite("FrameMonitor")
@MainActor
struct FrameMonitorTests {
    @Test func countsOnlyWhileRecordingAndThrottlesSnapshots() {
        let ticker = ManualFrameTicker()
        let monitor = FrameMonitor(ticker: ticker, snapshotsPerSecond: 2)
        monitor.start()
        for _ in 0..<30 { ticker.fire() }
        #expect(monitor.snapshot.frames == 0)                      // not recording yet

        monitor.beginRecording()
        for _ in 0..<30 { ticker.fire() }                          // 0.25 s: first snapshot only
        #expect(monitor.snapshot.frames == 0)
        for _ in 0..<40 { ticker.fire() }                          // past 0.5 s: a new snapshot
        #expect(monitor.snapshot.frames > 0)

        monitor.endRecording()
        let final = monitor.snapshot
        #expect(final.frames == 69)                                // 70 ticks after recording began → 69 intervals
        for _ in 0..<30 { ticker.fire() }
        #expect(monitor.snapshot == final)                         // idle frames don't dilute the result
    }
}

// MARK: - Controller end-to-end

@MainActor
private func fastConfiguration(tokens: Int = 400) -> TokenStreamConfiguration {
    TokenStreamConfiguration(
        tokensPerSecond: 20_000,
        tokenCount: tokens,
        packetInterval: 0.0005...0.002,
        stallProbability: 0
    )
}

@Suite("BenchmarkController")
@MainActor
struct BenchmarkControllerTests {
    private func drive(_ ticker: ManualFrameTicker, until done: () -> Bool) async throws {
        var ticks = 0
        while !done() && ticks < 20_000 {
            if !ticker.fire() { try await Task.sleep(for: .milliseconds(1)) }
            await Task.yield()
            ticks += 1
        }
    }

    @Test func splitModeFeedsBothRenderersIdenticalInput() async throws {
        var ticker: ManualFrameTicker!
        let controller = BenchmarkController(makeTicker: { ticker = ManualFrameTicker(); return ticker })
        controller.mode = .split
        controller.configuration = fastConfiguration()
        await controller.start()
        let session = try #require(controller.session)
        try await drive(ticker) { session.renderer.completion != nil }

        let expected = TokenStreamSimulator(controller.configuration).tokens().joined()
        #expect(controller.naive.text == expected)
        #expect(controller.naive.updates > 1)
        #expect(session.renderer.completion == .finished)

        let reference = StreamRenderer()
        reference.apply(text: expected, isFinal: true)
        #expect(session.renderer.document.attributedString.isEqual(to: reference.document.attributedString))
        try await drive(ticker) { !controller.isRunning }
        #expect(!controller.isRunning)
    }

    @Test func naiveOnlyModeHasNoSession() async throws {
        let controller = BenchmarkController(makeTicker: { ManualFrameTicker() })
        controller.mode = .naiveOnly
        controller.configuration = fastConfiguration(tokens: 200)
        await controller.start()
        #expect(controller.session == nil)
        try await drive(ManualFrameTicker()) { !controller.isRunning }
        #expect(controller.naive.text == TokenStreamSimulator(controller.configuration).tokens().joined())
    }

    @Test func stopCancelsTheRunAndNewRunStartsClean() async throws {
        var ticker: ManualFrameTicker!
        let controller = BenchmarkController(makeTicker: { ticker = ManualFrameTicker(); return ticker })
        controller.configuration = TokenStreamConfiguration(tokensPerSecond: 50, tokenCount: 1_000)   // ~20 s
        await controller.start()
        let first = try #require(controller.session)
        controller.stop()
        #expect(!controller.isRunning)
        try await drive(ticker) { first.renderer.completion != nil }
        #expect(first.renderer.completion == .cancelled)

        let previousRun = controller.runID
        controller.configuration = fastConfiguration(tokens: 100)
        await controller.start()
        #expect(controller.runID == previousRun + 1)
        #expect(controller.session !== first)
        controller.stop()
    }
}

// MARK: - Warm-up exclusion

@Suite("Recording starts at first packet")
@MainActor
struct FirstPacketTests {
    @Test(arguments: [BenchmarkController.Mode.fluidOnly, .naiveOnly, .split])
    func firesOncePerRunAfterContentArrives(mode: BenchmarkController.Mode) async throws {
        var ticker: ManualFrameTicker?
        let controller = BenchmarkController(makeTicker: { let t = ManualFrameTicker(); ticker = t; return t })
        controller.mode = mode
        controller.configuration = fastConfiguration(tokens: 300)

        var fired = 0
        var sawContentWhenFired = false
        controller.onFirstPacket = {
            fired += 1
            // Naive appends happen before the signal; for fluid-only, the buffer already has bytes.
            sawContentWhenFired = mode == .fluidOnly || !controller.naive.text.isEmpty
        }
        #expect(fired == 0)                                        // pressing Start alone doesn't record
        await controller.start()

        var spins = 0
        while controller.isRunning && spins < 20_000 {
            if ticker?.fire() != true { try await Task.sleep(for: .milliseconds(1)) }
            await Task.yield()
            spins += 1
        }
        #expect(fired == 1)
        #expect(sawContentWhenFired)
    }

    @Test func staleRunDoesNotFireForNewRun() async throws {
        let controller = BenchmarkController(makeTicker: { ManualFrameTicker() })
        controller.mode = .naiveOnly
        controller.configuration = TokenStreamConfiguration(tokenCount: 50, packetInterval: 0.5...0.6, stallProbability: 0)
        var fired = 0
        controller.onFirstPacket = { fired += 1 }
        await controller.start()
        controller.stop()                                          // cancelled before its first packet
        try await Task.sleep(for: .milliseconds(700))
        #expect(fired == 0)
    }
}

@Suite("FrameMonitor reset")
@MainActor
struct FrameMonitorResetTests {
    @Test func resetClearsAndStopsCounting() {
        let ticker = ManualFrameTicker()
        let monitor = FrameMonitor(ticker: ticker)
        monitor.start()
        monitor.beginRecording()
        for _ in 0..<130 { ticker.fire() }
        #expect(monitor.snapshot.frames > 0)
        monitor.reset()
        #expect(!monitor.isRecording)
        #expect(monitor.snapshot == HitchAccumulator())
        for _ in 0..<130 { ticker.fire() }                       // e.g. pane rebuild after Start
        #expect(monitor.snapshot == HitchAccumulator())
    }
}

// MARK: - Dropped frames per scroll (RFC-004 Addendum A)

@Suite("Dropped frames")
struct DroppedFrameTests {
    private let frame = 1.0 / 120

    @Test(arguments: [(1.0, 0), (1.49, 0), (1.51, 1), (2.0, 1), (3.0, 2), (6.0, 5)])
    func refreshesSkipped(multiple: Double, expected: Int) {
        #expect(HitchAccumulator.droppedFrames(actual: frame * multiple, expected: frame) == expected)
    }

    @Test func droppedFramesAgreeWithHitches() {
        var meter = HitchAccumulator()
        var intervals = Array(repeating: frame, count: 100)
        intervals[10] = frame * 2      // 1 dropped
        intervals[50] = frame * 4      // 3 dropped
        intervals[70] = frame * 1.4    // late, but not a hitch
        for tick in ticks(intervals) { meter.record(tick) }
        #expect(meter.hitches == 2)
        #expect(meter.droppedFrames == 4)
    }
}

@Suite("ScrollSessionMeter")
struct ScrollSessionMeterTests {
    private let frame = 1.0 / 120

    @Test func onlyFramesInsideASessionCount() {
        var meter = ScrollSessionMeter()
        var timeline = ticks([frame, frame * 5, frame, frame, frame * 3, frame, frame])   // 7 intervals
        // A slow frame before the finger lands must not leak into the scroll.
        for tick in timeline.prefix(3) { meter.record(tick) }
        meter.begin()
        for tick in timeline[3...] { meter.record(tick) }
        meter.end()
        timeline.removeAll()
        #expect(meter.sessions.count == 1)
        #expect(meter.sessions[0].droppedFrames == 2)          // only the 3× frame
        #expect(meter.sessions[0].index == 1)
        #expect(meter.sessions[0].frames == 4)
    }

    @Test func emptySessionsAreDiscardedAndIndicesStayDense() {
        var meter = ScrollSessionMeter()
        meter.begin(); meter.end()                             // touch with no frames
        meter.begin()
        for tick in ticks([frame, frame]) { meter.record(tick) }
        meter.end()
        #expect(meter.sessions.map(\.index) == [1])
        meter.end()                                            // stray end is harmless
        #expect(meter.sessions.count == 1)
    }
}

@Suite("ScrollSummary tails")
struct ScrollSummaryTests {
    private func summary(dropped values: [Int]) -> ScrollSummary {
        ScrollSummary(sessions: values.enumerated().map { i, d in
            ScrollSessionStats(index: i + 1, droppedFrames: d, hitchTime: Double(d) / 120, duration: 0.5, frames: 60)
        })
    }

    @Test func oneInSixteenAndThirtyTwoUseNearestRank() {
        let s = summary(dropped: Array((0..<96).reversed()))  // input order mustn't matter
        #expect(s.droppedFrames(oneIn: 16) == 89)              // rank ⌈96 × 15/16⌉ = 90
        #expect(s.droppedFrames(oneIn: 32) == 92)              // rank ⌈96 × 31/32⌉ = 93
        #expect(s.medianDroppedFrames == 47)
        #expect(s.maxDroppedFrames == 95)
        #expect(abs(s.hitchMilliseconds(oneIn: 16)! - 89 / 120 * 1000) < 1e-9)
        #expect(abs(s.jankyScrollRate! - 95.0 / 96) < 1e-12)
    }

    @Test func tailsNeedThreeTimesNScrolls() {
        #expect(summary(dropped: Array(repeating: 1, count: 47)).droppedFrames(oneIn: 16) == nil)
        #expect(summary(dropped: Array(repeating: 1, count: 48)).droppedFrames(oneIn: 16) == 1)
        #expect(summary(dropped: Array(repeating: 1, count: 95)).droppedFrames(oneIn: 32) == nil)
    }

    @Test func rareBadScrollShowsUpInTheTailNotTheMedian() {
        // 100 scrolls: 93 clean, 7 drop 8 frames. Run-wide averages hide this; the tail doesn't.
        let s = summary(dropped: Array(repeating: 0, count: 93) + Array(repeating: 8, count: 7))
        #expect(s.medianDroppedFrames == 0)
        #expect(s.droppedFrames(oneIn: 16) == 8)               // 7% of scrolls ≥ 1 in 16 (6.25%)
        #expect(s.droppedFrames(oneIn: 32) == 8)

        // Boundary: 6 in 100 is fewer than 1 in 16, so that tail is clean, but 1 in 32 isn't.
        let six = summary(dropped: Array(repeating: 0, count: 94) + Array(repeating: 8, count: 6))
        #expect(six.droppedFrames(oneIn: 16) == 0)
        #expect(six.droppedFrames(oneIn: 32) == 8)
    }

    @Test func emptySummary() {
        let s = summary(dropped: [])
        #expect(s.count == 0)
        #expect(s.medianDroppedFrames == nil)
        #expect(s.jankyScrollRate == nil)
    }
}

@Suite("FrameMonitor scrolls")
@MainActor
struct FrameMonitorScrollTests {
    @Test func scrollsOnlyCountDuringARecordedRun() {
        let ticker = ManualFrameTicker()
        let monitor = FrameMonitor(ticker: ticker)
        monitor.start()

        monitor.scrollBegan()                                  // not recording: ignored
        for _ in 0..<10 { ticker.fire() }
        monitor.scrollEnded()
        #expect(monitor.scrollSummary.count == 0)

        monitor.beginRecording()
        monitor.scrollBegan()
        for _ in 0..<10 { ticker.fire() }
        monitor.scrollEnded()
        #expect(monitor.scrollSummary.count == 1)              // published as soon as the scroll ends

        monitor.scrollBegan()
        for _ in 0..<10 { ticker.fire() }
        monitor.endRecording()                                 // run ends mid-scroll: close it
        #expect(monitor.scrollSummary.count == 2)

        monitor.beginRecording()                               // the next run's hitch score starts clean...
        #expect(monitor.snapshot.frames == 0)
        #expect(monitor.scrollSummary.count == 2)              // ...but scrolls carry over
    }

    /// One recorded scroll in the currently selected bucket.
    private func scroll(_ monitor: FrameMonitor, _ ticker: ManualFrameTicker) {
        monitor.scrollBegan()
        for _ in 0..<5 { ticker.fire() }
        monitor.scrollEnded()
    }

    @Test func scrollsAccumulateAcrossRunsOfTheSameMode() {
        let ticker = ManualFrameTicker()
        let monitor = FrameMonitor(ticker: ticker)
        monitor.start()
        monitor.selectScrollKey("FluidStreamKit")
        for _ in 0..<3 {                                       // three runs, 20 scrolls each
            monitor.reset()                                    // Start tapped
            monitor.beginRecording()                           // first packet
            for _ in 0..<20 { scroll(monitor, ticker) }
            monitor.endRecording()
        }
        #expect(monitor.scrollSummary.count == 60)
        #expect(monitor.scrollRuns == 3)
        #expect(monitor.scrollSummary.droppedFrames(oneIn: 16) != nil)        // 60 ≥ 48: tail now reported
        #expect(monitor.scrollSummary.sessions.map(\.index) == Array(1...60))   // numbering continues
    }

    @Test func modesNeverMix() {
        let ticker = ManualFrameTicker()
        let monitor = FrameMonitor(ticker: ticker)
        monitor.start()
        monitor.selectScrollKey("FluidStreamKit")
        monitor.beginRecording()
        for _ in 0..<4 { scroll(monitor, ticker) }
        monitor.endRecording()

        monitor.selectScrollKey("Naive SwiftUI")
        #expect(monitor.scrollSummary.count == 0)
        #expect(monitor.scrollRuns == 0)
        monitor.beginRecording()
        scroll(monitor, ticker)
        monitor.endRecording()
        #expect(monitor.scrollSummary.count == 1)

        monitor.selectScrollKey("FluidStreamKit")               // switching back restores its bucket
        #expect(monitor.scrollSummary.count == 4)
    }

    @Test func clearOnlyAffectsTheSelectedModeAndNotDuringARun() {
        let ticker = ManualFrameTicker()
        let monitor = FrameMonitor(ticker: ticker)
        monitor.start()
        for key in ["A", "B"] {
            monitor.selectScrollKey(key)
            monitor.beginRecording()
            scroll(monitor, ticker)
            monitor.selectScrollKey("ignored while recording")
            monitor.clearScrollStats()                         // ignored while recording
            #expect(monitor.scrollSummary.count == 1)
            monitor.endRecording()
        }
        monitor.clearScrollStats()                             // clears B only
        #expect(monitor.scrollSummary.count == 0)
        #expect(monitor.scrollRuns == 0)
        monitor.selectScrollKey("A")
        #expect(monitor.scrollSummary.count == 1)
    }
}

// MARK: - Hitch log and inactive time (build 4)

/// A ticker that fires at chosen timestamps, so tests can create real gaps.
@MainActor
private final class TimedTicker: FrameTicker {
    var isPaused = false
    private var handler: (@MainActor (FrameTick) -> Void)?
    private(set) var now = 0.0
    let frame = 1.0 / 120

    func start(_ handler: @escaping @MainActor (FrameTick) -> Void) { self.handler = handler }
    func invalidate() { handler = nil }

    /// Advances by `frames` frame durations, then fires once.
    func fire(after frames: Double = 1) {
        now += frame * frames
        handler?(FrameTick(timestamp: now, targetTimestamp: now + frame))
    }
}

@Suite("Hitch log")
@MainActor
struct HitchLogTests {
    @Test func logsEachHitchWithItsScrollContext() {
        let ticker = TimedTicker()
        let monitor = FrameMonitor(ticker: ticker, snapshotsPerSecond: 1000)
        monitor.start()
        monitor.beginRecording()
        for _ in 0..<10 { ticker.fire() }
        ticker.fire(after: 4)                                  // plain hitch: 3 dropped
        monitor.scrollBegan()
        ticker.fire(); ticker.fire(after: 3)                   // during a scroll
        monitor.scrollEnded()
        for _ in 0..<5 { ticker.fire() }
        ticker.fire(after: 10)                                 // shortly after the scroll
        monitor.endRecording()

        let log = monitor.hitchLog
        #expect(log.count == 3)
        #expect(log[0].context == .none)
        #expect(log[0].droppedFrames == 3)
        #expect(abs(log[0].refreshRate - 120) < 0.001)
        #expect(log[1].context == .duringScroll)
        guard case .afterScroll(let ms) = log[2].context else { Issue.record("expected afterScroll"); return }
        #expect(abs(ms - 5 * 1000.0 / 120) < 0.01)             // 5 frames after the scroll ended
        #expect(log[2].line.contains("after a scroll"))
        #expect(monitor.snapshot.hitches == 3)                  // the log and the score agree
    }

    @Test func inactiveTimeIsExcludedAndNoted() {
        let ticker = TimedTicker()
        let monitor = FrameMonitor(ticker: ticker, snapshotsPerSecond: 1000)
        monitor.start()
        monitor.beginRecording()
        for _ in 0..<60 { ticker.fire() }
        monitor.appWillResignActive()                           // Control Center pulled down
        ticker.fire(after: 228)                                 // ~1.9 s with the app inactive
        ticker.fire()
        monitor.appDidBecomeActive()
        for _ in 0..<60 { ticker.fire() }
        monitor.endRecording()

        #expect(monitor.snapshot.hitches == 0)                  // not scored as a hitch
        #expect(monitor.snapshot.hitchTimeRatio == 0)
        #expect(abs(monitor.snapshot.duration - 118.0 / 120) < 0.001)   // the gap isn't counted as time either
        #expect(monitor.hitchLog.count == 1)
        #expect(monitor.hitchLog[0].context == .excludedInactive)
        #expect(monitor.hitchLog[0].line.contains("excluded"))
    }

    @Test func logClearsWithEachRunButIsCapped() {
        let ticker = TimedTicker()
        let monitor = FrameMonitor(ticker: ticker, snapshotsPerSecond: 1000)
        monitor.start()
        monitor.beginRecording()
        ticker.fire()
        for _ in 0..<(FrameMonitor.maxLogEntries + 20) { ticker.fire(after: 3) }
        monitor.endRecording()
        #expect(monitor.hitchLog.count == FrameMonitor.maxLogEntries)
        monitor.beginRecording()
        #expect(monitor.hitchLog.isEmpty)
    }
}
