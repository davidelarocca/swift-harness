import SwiftUI

public struct LibraryView: View {
    public init() {}
    public var body: some View {
        VStack(alignment: .leading) {
            Text("Library").font(.title)
            Text("Albums, artists and playlists")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}
