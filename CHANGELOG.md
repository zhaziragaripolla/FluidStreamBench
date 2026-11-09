# Changelog

## [Unreleased]

### Added
- `FluidStreamBenchmarkKit`:
  - a deterministic token-stream simulator (seeded, with jitter and stalls);
  - a hitch meter (hitch time ratio, dropped frames);
  - per-scroll stats (median, 1 in 16, 1 in 32), kept per mode across runs, with Clear;
  - a per-hitch log (time, duration, refresh rate, scroll context), copyable from the app.
- Time while the app is inactive (Control Center, notifications, app switcher) is excluded from every metric and noted in the log.
- BenchmarkApp: FluidStreamKit, Naive SwiftUI and Split (demo only) modes, plus TestFlight build settings.
- RFC-004: benchmark methodology and the per-scroll metric (Addendum A).
