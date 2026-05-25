import SwiftUI
import WidgetKit

@main
struct AllspeakLiveActivityBundle: WidgetBundle {
    var body: some Widget {
        AllspeakLiveActivityPlaceholderWidget()
    }
}

struct AllspeakLiveActivityPlaceholderWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(
            kind: "dev.karpovich.allspeak.liveactivity.placeholder",
            provider: AllspeakLiveActivityPlaceholderProvider()
        ) { _ in
            Text(verbatim: "")
        }
        .supportedFamilies([])
    }
}

struct AllspeakLiveActivityPlaceholderEntry: TimelineEntry {
    let date: Date
}

struct AllspeakLiveActivityPlaceholderProvider: TimelineProvider {
    func placeholder(in context: Context) -> AllspeakLiveActivityPlaceholderEntry {
        AllspeakLiveActivityPlaceholderEntry(date: .now)
    }

    func getSnapshot(in context: Context, completion: @escaping (AllspeakLiveActivityPlaceholderEntry) -> Void) {
        completion(AllspeakLiveActivityPlaceholderEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<AllspeakLiveActivityPlaceholderEntry>) -> Void) {
        completion(Timeline(entries: [AllspeakLiveActivityPlaceholderEntry(date: .now)], policy: .never))
    }
}
