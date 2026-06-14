import SwiftUI

struct ContentView: View {
    enum Page: Hashable {
        case currentLine
        case subtitleList
        case trackList
    }

    @State private var selection: Page = .currentLine

    var body: some View {
        TabView(selection: $selection) {
            TransportView()
                .tag(Page.currentLine)
            SubtitleListView()
                .tag(Page.subtitleList)
            TrackListView()
                .tag(Page.trackList)
        }
        .tabViewStyle(.page)
    }
}
