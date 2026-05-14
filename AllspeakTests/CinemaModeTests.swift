import Testing
@testable import Allspeak

@Suite("CinemaMode state machine")
struct CinemaModeTests {

    @Test(
        "next(for:) covers every (state, input) -> result transition",
        arguments: [
            (CinemaMode.off,  CinemaInput.pill,           CinemaMode.on),
            (CinemaMode.on,   CinemaInput.pill,           CinemaMode.off),
            (CinemaMode.deep, CinemaInput.pill,           CinemaMode.off),

            (CinemaMode.off,  CinemaInput.tapRiver,       CinemaMode.off),
            (CinemaMode.on,   CinemaInput.tapRiver,       CinemaMode.off),
            (CinemaMode.deep, CinemaInput.tapRiver,       CinemaMode.off),

            (CinemaMode.off,  CinemaInput.longPressRiver, CinemaMode.off),
            (CinemaMode.on,   CinemaInput.longPressRiver, CinemaMode.deep),
            (CinemaMode.deep, CinemaInput.longPressRiver, CinemaMode.deep),
        ]
    )
    func transitions(state: CinemaMode, input: CinemaInput, expected: CinemaMode) {
        #expect(state.next(for: input) == expected)
    }

    @Test("apply(_:) mutates in place using next(for:)")
    func applyMutatesInPlace() {
        var s: CinemaMode = .off
        s.apply(.pill)
        #expect(s == .on)
        s.apply(.longPressRiver)
        #expect(s == .deep)
        s.apply(.tapRiver)
        #expect(s == .off)
    }

    @Test("pill cycles off -> on -> off")
    func pillCycle() {
        var s: CinemaMode = .off
        s.apply(.pill); #expect(s == .on)
        s.apply(.pill); #expect(s == .off)
    }

    @Test("entering deep requires .on (long-press from .off is a no-op)")
    func longPressOnlyFromOnEntersDeep() {
        var s: CinemaMode = .off
        s.apply(.longPressRiver)
        #expect(s == .off)
        s.apply(.pill)
        s.apply(.longPressRiver)
        #expect(s == .deep)
    }

    @Test("tap exits cinema from any active state")
    func tapExitsFromAnyActiveState() {
        var s: CinemaMode = .on
        s.apply(.tapRiver)
        #expect(s == .off)

        s = .deep
        s.apply(.tapRiver)
        #expect(s == .off)
    }

    @Test(
        "derived flags per state",
        arguments: [
            (CinemaMode.off,  false, false, false, false, 0.0),
            (CinemaMode.on,   true,  true,  false, true,  0.22),
            (CinemaMode.deep, true,  true,  true,  false, 0.5),
        ]
    )
    func derivedFlags(
        state: CinemaMode,
        isCinema: Bool,
        hidesChrome: Bool,
        usesDeepBackground: Bool,
        showsExitChip: Bool,
        dim: Double
    ) {
        #expect(state.isCinema == isCinema)
        #expect(state.hidesChrome == hidesChrome)
        #expect(state.usesDeepBackground == usesDeepBackground)
        #expect(state.showsExitChip == showsExitChip)
        #expect(state.dimOpacity == dim)
    }
}
