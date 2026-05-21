import SwiftUI

struct ContentView: View {
    enum Page: Hashable {
        case currentLine
        case subtitleList
    }

    @State private var selection: Page = .currentLine

    var body: some View {
        TabView(selection: $selection) {
            CurrentLineView()
                .tag(Page.currentLine)
            SubtitleListView()
                .tag(Page.subtitleList)
        }
        .tabViewStyle(.page)
    }
}
