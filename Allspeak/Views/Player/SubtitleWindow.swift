import Foundation

enum SubtitleLineState: Hashable {
    case pastFar
    case past
    case current
    case future
    case futureFar
}

struct SubtitleSlot: Equatable, Hashable {
    let absoluteIndex: Int
    let state: SubtitleLineState
    let cue: Subtitle
}

enum SubtitleWindow {
    static let defaultRadius = 3

    static func window(currentIndex: Int, cues: [Subtitle], radius: Int = SubtitleWindow.defaultRadius) -> [SubtitleSlot] {
        guard !cues.isEmpty else { return [] }
        let r = max(0, radius)
        let clamped = max(0, min(currentIndex, cues.count - 1))
        let start = max(0, clamped - r)
        let end = min(cues.count, clamped + r + 1)
        var slots: [SubtitleSlot] = []
        slots.reserveCapacity(end - start)
        for abs in start..<end {
            let d = abs - clamped
            let state: SubtitleLineState
            switch d {
            case ..<(-1): state = .pastFar
            case -1:      state = .past
            case 0:       state = .current
            case 1:       state = .future
            default:      state = .futureFar
            }
            slots.append(SubtitleSlot(absoluteIndex: abs, state: state, cue: cues[abs]))
        }
        return slots
    }
}
