import SwiftUI

struct ContentView: View {
    enum Page: Hashable {
        case currentLine
        case listen
        case subtitleList
        case trackList
    }

    @Environment(WatchSessionClient.self) private var client
    @State private var selection: Page = .currentLine

    private var showsListen: Bool { client.hasFingerprint }
    private var showsTrackList: Bool { client.tracks.count > 1 }

    var body: some View {
        TabView(selection: $selection) {
            TransportView()
                .tag(Page.currentLine)
            if showsListen {
                ListenView()
                    .tag(Page.listen)
            }
            SubtitleListView()
                .tag(Page.subtitleList)
            if showsTrackList {
                TrackListView()
                    .tag(Page.trackList)
            }
        }
        .tabViewStyle(.page)
        .onChange(of: showsListen) { _, shows in
            guard !shows, selection == .listen else { return }
            selection = .currentLine
        }
        .onChange(of: showsTrackList) { _, shows in
            guard !shows, selection == .trackList else { return }
            selection = .currentLine
        }
    }
}
