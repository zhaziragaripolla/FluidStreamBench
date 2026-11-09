# BenchmarkApp

Compares naive SwiftUI streaming against `FluidStreamKit` with the same deterministic token stream. The methodology is in [RFC-004](../Docs/RFCs/RFC-004-benchmark-methodology.md).

## Set up (needs full Xcode, not just Command Line Tools)

This repo benchmarks the library from a **sibling checkout**. Clone both side by side:
```bash
git clone https://github.com/zhaziragaripolla/FluidStreamKit.git
git clone https://github.com/zhaziragaripolla/FluidStreamBench.git
```

```
FluidStreamKit/     ← the library (zero dependencies)
FluidStreamBench/   ← this repo: the benchmark kit, BenchmarkApp, RFC-004
```

**Option A: XcodeGen**
```bash
brew install xcodegen
cd BenchmarkApp && xcodegen generate && open FluidStreamBenchmark.xcodeproj
```

**Option B: by hand**
1. In Xcode, create a new iOS App (SwiftUI, iOS 17+) and delete its generated `ContentView.swift` and `App` file.
2. Drag the three files in `Sources/` into the target.
3. Choose File ▸ Add Package Dependencies ▸ Add Local… twice: pick the `FluidStreamKit` folder and add `FluidStreamCore` and `FluidStreamUI`, then pick the `FluidStreamBench` folder and add `FluidStreamBenchmarkKit`.
4. In the target's Info tab, add `CADisableMinimumFrameDurationOnPhone` = `YES`.

## Measuring: required conditions
- A **physical 120 Hz iPhone or iPad**. The Simulator's frame timing doesn't mean anything here.
- A **Release** build. Product ▸ Profile (⌘I) uses Release by default. Debug Swift is about 10× slower.
- Low Power Mode **off**, and the device not hot.
- **Fluid only** or **Naive only** mode. Split mode shares one main thread, so it's for demos only.

## Steps
1. Press ⌘I and choose the **Animation Hitches** template. Add the **Points of Interest** instrument.
2. In the app, pick a mode, keep 150 tok/s with jitter on, and press **Start**.
3. Let it run to the end (6,000 tokens ≈ 40 s), then stop recording.
4. Read the **hitch time ratio** from Instruments, which is the number to publish. The in-app HUD is a rough guide.
5. Repeat for the other mode. Run each mode 3 times and report the median.

The `Frame` intervals on Points of Interest are `FluidStreamKit` flushes, each labelled with its byte count. `Naive update` intervals are the baseline's appends. Select a hitch to see which interval caused it.

## Reporting template
> Fluid: __ ms/s · Naive: __ ms/s (median of 3) — iPhone __, iOS __, seed 42, 6,000 tokens, 150 tok/s, jitter on, Release.
