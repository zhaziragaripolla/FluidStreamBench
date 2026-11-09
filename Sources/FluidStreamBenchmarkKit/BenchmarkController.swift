public import FluidStreamCore
public import FluidStreamUI
public import Observation
import os

/// The baseline: what a competent engineer would write first (RFC-004).
///
/// Every network packet appends to an observed string. The view re-renders it with
/// `Text(AttributedString(markdown:))`, which is O(document) work per packet on the main thread.
@MainActor
@Observable
public final class NaiveStreamModel {
    public private(set) var text = ""
    @ObservationIgnored public private(set) var updates = 0

    private static let signposter = OSSignposter(subsystem: "FluidStreamKit", category: .pointsOfInterest)

    public init() {}

    public func append(_ chunk: String) {
        let state = Self.signposter.beginInterval("Naive update")
        text += chunk
        updates += 1
        Self.signposter.endInterval("Naive update", state)
    }

    public func reset() {
        text = ""
        updates = 0
    }
}

/// Runs one benchmark: plays a deterministic schedule into the naive model, the
/// `FluidStreamKit` session, or both.
///
/// Its observable surface is deliberately small (mode, configuration, run state). Streamed
/// text never passes through it, so the control UI doesn't re-render per token.
@MainActor
@Observable
public final class BenchmarkController {
    public enum Mode: String, CaseIterable, Sendable, Identifiable {
        case fluidOnly = "FluidStreamKit"
        case naiveOnly = "Naive SwiftUI"
        case split = "Split (demo only)"

        public var id: String { rawValue }
        /// Split mode shares one main thread between both renderers, so its numbers can't be trusted.
        public var isMeasurable: Bool { self != .split }
        var usesFluid: Bool { self != .naiveOnly }
        var usesNaive: Bool { self != .fluidOnly }
    }

    public var mode = Mode.fluidOnly
    public var configuration = TokenStreamConfiguration()
    public private(set) var isRunning = false
    /// Changes on every run. Views use it to rebuild panes from scratch.
    public private(set) var runID = 0

    /// Called once per run, on the main actor, right after the first packet is delivered.
    /// The app starts hitch recording here, not when Start is pressed. Pressing Start
    /// rebuilds the panes, and that one-off setup frame isn't streaming work, so it
    /// shouldn't be in the score.
    @ObservationIgnored public var onFirstPacket: (@MainActor () -> Void)?

    @ObservationIgnored public let naive = NaiveStreamModel()
    @ObservationIgnored public private(set) var session: StreamSession?
    @ObservationIgnored private let makeTicker: @MainActor () -> any FrameTicker
    @ObservationIgnored private var naiveOnlyTask: Task<Void, Never>?

    public init(makeTicker: @escaping @MainActor () -> any FrameTicker) {
        self.makeTicker = makeTicker
    }

    public func start() async {
        stop()
        runID += 1
        isRunning = true
        naive.reset()

        let runID = runID
        let mode = mode
        let player = SchedulePlayer(TokenStreamSimulator(configuration).schedule())
        let firstPacket = player.packets.first
        let naive = naive

        if mode.usesFluid {
            let session = StreamSession(ticker: makeTicker())
            self.session = session
            await session.start { [weak self] buffer in
                do {
                    try await player.play { packet in
                        try await buffer.append(packet.text)
                        if mode.usesNaive { await naive.append(packet.text) }
                        if packet == firstPacket { await self?.firstPacketDelivered(runID) }
                    }
                } catch {
                    await self?.runEnded(runID)
                    throw error
                }
                await self?.runEnded(runID)
            }
        } else {
            session = nil
            naiveOnlyTask = Task.detached { [weak self] in
                try? await player.play { packet in
                    await naive.append(packet.text)
                    if packet == firstPacket { await self?.firstPacketDelivered(runID) }
                }
                await self?.runEnded(runID)
            }
        }
    }

    public func stop() {
        session?.cancel()
        naiveOnlyTask?.cancel()
        naiveOnlyTask = nil
        isRunning = false
    }

    private func firstPacketDelivered(_ id: Int) {
        if id == runID { onFirstPacket?() }
    }

    private func runEnded(_ id: Int) {
        if id == runID { isRunning = false }
    }
}
