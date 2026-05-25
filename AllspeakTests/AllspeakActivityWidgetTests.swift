import Foundation

// AllspeakActivityWidget intentionally has no unit tests.
//
// Per docs/plans/2026-05-25-watch-live-activity.md §Testing Strategy:
// "No widget snapshot tests: ActivityKit views cannot be reliably unit-tested
// without a real device. Visual verification is in Post-Completion (cinema-trip
// + simulator dry run)."
//
// The testable logic surrounding the widget lives in:
//   - LiveActivityCoordinatorTests (state machine + idempotency)
//   - TogglePlaybackIntentTests (intent metadata)
//   - AllspeakActivityAttributesTests (Codable round-trip + size budget)
//   - PlaybackCoordinatorTests (lifecycle wiring)
