import Foundation
import WidgetKit

@MainActor
enum ComplicationPublisher {
    static func publish(_ metadata: SessionMetadata?) {
        let state = ComplicationState(metadata: metadata, now: Date())
        guard ComplicationStore.appGroup().update(state) else { return }
        WidgetCenter.shared.reloadAllTimelines()
    }
}
