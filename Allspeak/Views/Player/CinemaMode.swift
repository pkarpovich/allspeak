import Foundation

enum CinemaMode: Hashable, Sendable {
    case off
    case on
    case deep
}

enum CinemaInput: Hashable, Sendable {
    case pill
    case tapRiver
    case longPressRiver
}

extension CinemaMode {
    func next(for input: CinemaInput) -> CinemaMode {
        switch (self, input) {
        case (.off,  .pill):            return .on
        case (.on,   .pill):            return .off
        case (.deep, .pill):            return .off

        case (.off,  .tapRiver):        return .off
        case (.on,   .tapRiver):        return .off
        case (.deep, .tapRiver):        return .off

        case (.off,  .longPressRiver):  return .off
        case (.on,   .longPressRiver):  return .deep
        case (.deep, .longPressRiver):  return .deep
        }
    }

    mutating func apply(_ input: CinemaInput) {
        self = next(for: input)
    }

    var isCinema: Bool { self != .off }
    var hidesChrome: Bool { self != .off }
    var usesDeepBackground: Bool { self == .deep }
    var showsExitChip: Bool { self == .on }

    var dimOpacity: Double {
        switch self {
        case .off:  return 0
        case .on:   return 0.22
        case .deep: return 0.5
        }
    }
}
