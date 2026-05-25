import SwiftUI

struct ContentView: View {
    enum Page: Hashable {
        case currentLine
        case subtitleList
        case trackList
    }

    @Binding var selection: Page

    init(selection: Binding<Page>) {
        self._selection = selection
    }

    var body: some View {
        TabView(selection: $selection) {
            CurrentLineView()
                .tag(Page.currentLine)
            SubtitleListView()
                .tag(Page.subtitleList)
            TrackListView()
                .tag(Page.trackList)
        }
        .tabViewStyle(.page)
    }
}
