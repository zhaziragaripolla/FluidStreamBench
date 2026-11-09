import SwiftUI
import FluidStreamCore
import FluidStreamUI
import FluidStreamBenchmarkKit

struct ContentView: View {
    @State private var controller = BenchmarkController(makeTicker: { DisplayLinkTicker() })
    @State private var monitor = FrameMonitor(ticker: DisplayLinkTicker())
    @State private var showingLog = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ControlsBar(controller: controller, monitor: monitor)
                HitchHUD(
                    snapshot: monitor.snapshot,
                    scrolls: monitor.scrollSummary,
                    scrollRuns: monitor.scrollRuns,
                    mode: controller.mode,
                    isRunning: controller.isRunning,
                    onClearScrolls: { monitor.clearScrollStats() },
                    hitchLogCount: monitor.hitchLog.count,
                    onShowLog: { showingLog = true }
                )
                Divider()
                panes
                    .id(controller.runID)            // every run starts from fresh views
            }
            .navigationTitle("FluidStream Benchmark")
            .navigationBarTitleDisplayMode(.inline)
        }
        .onAppear {
            monitor.start()
            monitor.selectScrollKey(controller.mode.rawValue)
            // Recording begins with the first packet, not the Start tap (see onFirstPacket).
            controller.onFirstPacket = { [monitor] in monitor.beginRecording() }
            autostartIfRequested()
        }
        .onChange(of: controller.isRunning) { _, running in
            if !running { monitor.endRecording() }
        }
        // Time spent behind Control Center, notifications or the app switcher isn't measured.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { monitor.appDidBecomeActive() } else { monitor.appWillResignActive() }
        }
        .sheet(isPresented: $showingLog) {
            HitchLogView(events: monitor.hitchLog, mode: controller.mode, snapshot: monitor.snapshot)
        }
        // Scroll stats accumulate per mode across runs, so modes are never mixed.
        .onChange(of: controller.mode) { _, mode in
            monitor.selectScrollKey(mode.rawValue)
        }
    }

    /// `-FSAutostart fluid` or `-FSAutostart naive` (launch arguments, e.g. via
    /// `xcrun devicectl device process launch`) starts one run after a short settle, with no
    /// taps, so profiled runs follow an identical procedure.
    private func autostartIfRequested() {
        let modes: [String: BenchmarkController.Mode] = ["fluid": .fluidOnly, "naive": .naiveOnly]
        guard let key = UserDefaults.standard.string(forKey: "FSAutostart"), let mode = modes[key] else { return }
        controller.mode = mode
        monitor.selectScrollKey(mode.rawValue)
        monitor.reset()
        // `-FSAutostartDelay 10` leaves time to attach Instruments to the running app first.
        let delay = UserDefaults.standard.double(forKey: "FSAutostartDelay")
        Task {
            try? await Task.sleep(for: .seconds(delay > 0 ? delay : 2))
            await controller.start()
        }
    }

    @ViewBuilder
    private var panes: some View {
        switch controller.mode {
        case .fluidOnly:
            fluidPane
        case .naiveOnly:
            NaivePane(model: controller.naive, onScrollActivityChanged: scrollActivity)
        case .split:
            HStack(spacing: 0) {
                PaneLabel(title: "Naive SwiftUI") {
                    NaivePane(model: controller.naive, onScrollActivityChanged: scrollActivity)
                }
                Divider()
                PaneLabel(title: "FluidStreamKit") { fluidPane }
            }
        }
    }

    /// Both panes report finger scrolls to the meter, which splits frames into per-scroll stats.
    private var scrollActivity: (Bool) -> Void {
        { [monitor] scrolling in
            if scrolling { monitor.scrollBegan() } else { monitor.scrollEnded() }
        }
    }

    @ViewBuilder
    private var fluidPane: some View {
        if let session = controller.session {
            FluidStreamView(renderer: session.renderer, onScrollActivityChanged: scrollActivity)
        } else {
            ContentUnavailableView("Press Start", systemImage: "play.circle")
        }
    }
}

private struct ControlsBar: View {
    @Bindable var controller: BenchmarkController
    let monitor: FrameMonitor

    var body: some View {
        VStack(spacing: 8) {
            Picker("Mode", selection: $controller.mode) {
                ForEach(BenchmarkController.Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .disabled(controller.isRunning)        // changing settings mid-run would corrupt the measurement

            HStack {
                Stepper(
                    "\(Int(controller.configuration.tokensPerSecond)) tok/s",
                    value: $controller.configuration.tokensPerSecond,
                    in: 50...400,
                    step: 25
                )
                Toggle("Jitter", isOn: $controller.configuration.jitterEnabled)
                    .fixedSize()
            }
            .disabled(controller.isRunning)

            Button(controller.isRunning ? "Stop" : "Start") {
                if controller.isRunning {
                    controller.stop()
                } else {
                    monitor.reset()
                    Task { await controller.start() }
                }
            }
            .buttonStyle(.borderedProminent)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }
}

private struct HitchHUD: View {
    let snapshot: HitchAccumulator
    let scrolls: ScrollSummary
    let scrollRuns: Int
    let mode: BenchmarkController.Mode
    let isRunning: Bool
    let onClearScrolls: () -> Void
    let hitchLogCount: Int
    let onShowLog: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(String(format: "%.1f ms/s", snapshot.hitchTimeRatio))
                    .font(.title3.monospacedDigit().bold())
                    .foregroundStyle(color)
                Text("hitch time ratio")
                    .foregroundStyle(.secondary)
                Spacer()
                if isRunning { ProgressView() }
                if hitchLogCount > 0 {
                    Button("Log (\(hitchLogCount))", action: onShowLog)
                        .font(.caption)
                }
            }
            Text("\(snapshot.hitches) hitches · \(snapshot.droppedFrames) dropped · \(snapshot.frames) frames · worst \(String(format: "%.1f", snapshot.worstFrameInterval * 1000)) ms")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if isRunning || scrolls.count > 0 {
                HStack(alignment: .firstTextBaseline) {
                    Text(scrollLine)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    if scrolls.count > 0 && !isRunning {
                        Spacer(minLength: 4)
                        Button("Clear", action: onClearScrolls)
                            .font(.caption)
                    }
                }
            }
            if !mode.isMeasurable {
                Text("Split mode is for demos: both panes share one main thread, so these numbers aren't comparable.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    /// e.g. "Scrolls 52 (3 runs) · median 0 · 1 in 16: 2 (21 ms) · 1 in 32: needs 96 · janky 12%"
    private var scrollLine: String {
        guard scrolls.count > 0 else { return "Scroll while it streams to measure dropped frames per scroll" }
        let runs = scrollRuns == 1 ? "1 run" : "\(scrollRuns) runs"
        var parts = ["Scrolls \(scrolls.count) (\(runs))", "median \(scrolls.medianDroppedFrames ?? 0)"]
        for n in [16, 32] {
            if let frames = scrolls.droppedFrames(oneIn: n), let ms = scrolls.hitchMilliseconds(oneIn: n) {
                parts.append("1 in \(n): \(frames) (\(Int(ms.rounded())) ms)")
            } else {
                parts.append("1 in \(n): needs \(ScrollSummary.minimumScrolls(oneIn: n))")
            }
        }
        if let rate = scrolls.jankyScrollRate { parts.append("janky \(Int((rate * 100).rounded()))%") }
        return parts.joined(separator: " · ")
    }

    private var color: Color {
        switch snapshot.rating {
        case .good: .green
        case .warning: .orange
        case .critical: .red
        }
    }
}

private struct PaneLabel<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .padding(4)
            content
        }
    }
}

/// Every hitch in the last run, with when it happened and what was going on. Copy it to share.
private struct HitchLogView: View {
    let events: [HitchEvent]
    let mode: BenchmarkController.Mode
    let snapshot: HitchAccumulator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(events.indices, id: \.self) { index in
                Text(events[index].line)
                    .font(.caption.monospaced())
            }
            .navigationTitle("Hitch log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button("Copy") { UIPasteboard.general.string = report }
                }
            }
        }
    }

    private var report: String {
        let header = String(format: "%@ · %.1f ms/s · %d hitches · %d frames", mode.rawValue,
                            snapshot.hitchTimeRatio, snapshot.hitches, snapshot.frames)
        return ([header] + events.map(\.line)).joined(separator: "\n")
    }
}
