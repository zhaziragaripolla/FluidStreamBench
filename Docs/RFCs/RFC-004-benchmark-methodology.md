# RFC-004: Benchmark Methodology for `BenchmarkApp`

| | |
|---|---|
| **Status** | Implemented in 1.0.0 |
| **Module** | `FluidStreamBenchmarkKit` + `BenchmarkApp` (the FluidStreamBench repo) |
| **Depends on** | RFC-001–003 in the FluidStreamKit repo (the system under test) |

## TL;DR

**Measure one renderer at a time (A/B runs), feed both from the same deterministic, seeded token schedule, and treat Instruments' Animation Hitches as the ground truth.** An in-app HUD gives quick feedback, but it's an approximation. **The split-screen view is for demos only, never for measurement:** both panes share one main thread, so the naive pane's hitches also land on `FluidStreamKit`'s pane. A side-by-side "measurement" would therefore make our library look worse than it is, and would undermine trust in every number we publish.

## Problem

- The benchmark compares naive SwiftUI with `FluidStreamKit` at 150 tok/s with jitter. A benchmark is only worth something if a skeptical reviewer can't dismiss it. That means the comparison has to be **fair**, **repeatable** and **measured where the user feels it**.
- Common ways these benchmarks go wrong:
  - a strawman baseline;
  - non-deterministic input, so runs can't be compared;
  - profiling Debug builds, where Swift is ~10× slower;
  - measuring both contenders in one process at once.

## Options & Trade-off Matrix (how to measure)

| Criterion | A. XCTest performance tests (`XCTOSSignpostMetric`, hitch metrics in UI tests) | B. Instruments: Animation Hitches + Time Profiler | **C. In-app frame monitor (`CADisplayLink` deltas) + signposts (chosen, alongside B)** |
|---|---|---|---|
| **Accuracy** | High, using system metrics | **Ground truth.** Includes render-server and commit hitches | Approximate. Sees main-thread lateness only, and misses render-server hitches |
| **Automation / CI** | ✅ Can gate regressions | ❌ Manual | ⚠️ Logs only |
| **Feedback speed** | Minutes per run | Minutes per run | **Instant**, a live HUD |
| **Overhead on the measured run** | Low | Low | Low (one extra display link; the HUD refreshes at 2 Hz, not per frame) |
| **Setup cost** | High: needs a UI test target and a real device | Low | Low |

**Decision:** C during development, and B for any number we publish. A is a follow-up, to gate CI on regressions once the numbers are stable.

## Design

1. **Deterministic input.** `TokenStreamSimulator` turns `(corpus, rate, seed)` into a fixed schedule of *packets*:
   - The model emits tokens at a steady 150 tok/s.
   - The network delivers whatever has accumulated, every 15–120 ms.
   - There's a 2% chance per packet of a 200–600 ms stall.

   The same seed always gives the same packets. Tokens are ~4 characters, so tags like `<thinking>` naturally get split across packets, which exercises RFC-002 for free.
2. **A fair baseline.** The naive pane is what a competent engineer would write first, not a strawman: an `@Observable` string, appended to on every network packet and rendered with `Text(AttributedString(markdown:))` in a `ScrollView` that scrolls to the bottom on change. It doesn't parse `<thinking>` or tool calls, which makes it do *less* work than we do. The comparison is therefore conservative.
3. **Modes:**
   - **Fluid only:** for measurement.
   - **Naive only:** for measurement.
   - **Split:** for demos. The UI labels it as unmeasured.
4. **The HUD shows the hitch time ratio** (total ms of hitch per second), the same metric Instruments and Xcode Organizer use:
   - **Good:** < 5 ms/s
   - **Warning:** 5–10 ms/s
   - **Critical:** > 10 ms/s

   A frame counts as a hitch when it arrives more than half a frame late.
5. **Signposts.** `StreamRenderer` emits a `Frame` interval to Points of Interest, with the byte count, on every flush. The naive model emits `Naive update`. In Instruments you can then put each hitch next to the work that caused it.
6. **Required run conditions** (printed in the README):
   - a **Release** build (Instruments' Profile action defaults to Release);
   - a physical 120 Hz device, not the Simulator;
   - Low Power Mode off;
   - `CADisableMinimumFrameDurationOnPhone = YES`.

## Risks & Open Questions

- **In-app monitor blind spots.** A hitch in the render server shows up in Instruments but not in the HUD. That's why published numbers come from B.
- **The corpus shapes the results.** Code-heavy answers stress different paths from prose-heavy ones. v1 ships one mixed corpus; add more as needed.
- **No Xcode on the authoring machine.** The app shell is type-checked only. It needs a first run on a device to validate.

## Success Metrics

- The same seed produces byte-identical schedules (asserted in tests).
- Effective token rate within ±10% of the target (asserted in tests).
- The headline result is in a form a reviewer can reproduce: "*Fluid: X ms/s vs Naive: Y ms/s, iPhone __, iOS __, seed 42, 6000 tokens, Release.*"

---

## Addendum A: Dropped frames per scroll

| | |
|---|---|
| **Status** | Implemented in 1.0.0 |
| **Origin** | Device testing |

### TL;DR

**Alongside the run-wide hitch time ratio, measure dropped frames for each scroll gesture, and report the tail as "1 in 16 scrolls drops ≥ X frames" and "1 in 32 scrolls drops ≥ Y frames".** Users feel stutter while they scroll, and they remember the bad scroll, not the average. A run-wide ratio can be low while one scroll in 30 still stutters visibly. **Caveat:** a tail number is only as good as its sample size. "1 in 32" needs at least ~96 scrolls, so the HUD shows "needs N scrolls" until there are enough.

### Definitions

- **Scroll session:** from when the content first starts moving under a finger until the scroll comes to rest (dragging plus deceleration). A touch that doesn't move isn't a scroll, and neither is the app's own scroll to follow new text.
- **Dropped frames** for one frame interval: `max(0, round(actual / expected) − 1)`. A 25 ms gap on a 120 Hz screen (8.33 ms per frame) means 2 frames were skipped. This matches the existing hitch rule: an interval counts as a hitch exactly when it drops ≥ 1 frame.
- **Per-scroll stats:** dropped frames, hitch milliseconds and duration.
- **"1 in N" tail:** the nearest-rank percentile at `1 − 1/N`, so 1 in 16 is p93.75 and 1 in 32 is p96.9. It's reported only when there are ≥ 3N scrolls, so the tail rests on at least 3 samples.

### Where the scrolls come from (trade-off matrix)

| Criterion | **A. Human flicks during streaming (chosen)** | B. Scripted programmatic scrolls in the app | C. XCUITest swipes + `XCTOSSignpostMetric` scroll metrics |
|---|---|---|---|
| **Uses the real touch pipeline** | ✅ | ❌ No touch handling or pan recognizer, and SwiftUI and UIKit animate differently, so the comparison isn't fair | ✅ |
| **Repeatable** | ⚠️ Only statistically, given many scrolls | ✅ | ✅ |
| **Fair across both modes** | ✅ The same human gestures in both | ❌ Two different scroll mechanisms | ✅ The same synthesized swipes |
| **Setup** | Low: delegate and scroll-phase hooks | Medium: has to fight the follow-tail logic | High: UI test target, and a cabled device |
| **Useful for CI** | ❌ | ⚠️ | ✅ |

**Decision:** A now, because it needs no cable and measures what users actually feel. C later, for repeatable regression checks. B is rejected, because it can't be made fair between SwiftUI and UIKit scrolling.

### Risks

- **Humans scroll differently in each run.** That's handled by collecting many scrolls per mode, and by comparing distributions, not single scrolls.
- **Scroll phase detection for SwiftUI's `ScrollView`** uses `onScrollPhaseChange`, which needs iOS 18. On iOS 17 the naive pane reports no scrolls, and the HUD says so.
