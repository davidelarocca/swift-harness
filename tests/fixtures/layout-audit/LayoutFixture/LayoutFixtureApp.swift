import SwiftUI

/// A player screen with two layout faults, fixed with the `-fixed` launch argument: the
/// transport row has fixed-width buttons that the smallest window (macOS) or an iPhone cuts,
/// and two labels sit on top of each other. Its scrolling track list is the negative control:
/// tracks past the scroll view's edge, and over the footer below it, are not faults.
@main
struct LayoutFixtureApp: App {
    var body: some Scene {
        WindowGroup {
            if CommandLine.arguments.contains("-presented") {
                PresentedScreen(fixed: CommandLine.arguments.contains("-fixed"))
            } else {
                PlayerScreen(fixed: CommandLine.arguments.contains("-fixed"))
            }
        }
    }
}

struct PlayerScreen: View {
    let fixed: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Library").font(.title).accessibilityIdentifier("title")
            HStack(spacing: 8) {
                ForEach(["Play", "Shuffle", "Repeat"], id: \.self) { name in
                    Button {} label: {
                        if fixed {
                            Text(name).frame(maxWidth: .infinity)
                        } else {
                            Text(name).frame(width: 140)
                        }
                    }
                    .accessibilityIdentifier(name.lowercased())
                }
            }
            // The row takes the width it is given and overflows it on both sides: the overflow
            // is hidden from the views' sizes (#34), not from the window.
            .frame(minWidth: 0, maxWidth: .infinity)
            if fixed {
                VStack(alignment: .leading, spacing: 4) { nowPlaying; upNext }
            } else {
                ZStack(alignment: .topLeading) { nowPlaying; upNext.offset(y: 8) }
            }
            ScrollView {
                VStack(alignment: .leading) {
                    ForEach(0..<30) { i in Text("Track \(i)").accessibilityIdentifier("track\(i)") }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: 80)
            .accessibilityIdentifier("tracks")
            Text("30 tracks").accessibilityIdentifier("footer")
        }
        .padding(16)
        .frame(minWidth: 280, maxWidth: .infinity, minHeight: 280, maxHeight: .infinity)
    }

    private var nowPlaying: some View { Text("Now playing: Blue in Green").accessibilityIdentifier("nowPlaying") }
    private var upNext: some View { Text("Up next: So What").accessibilityIdentifier("upNext") }
}

/// Presented UI, for `LayoutAudit.checkPresented` (`-presented`): a menu, a popover and a
/// dropdown built in the window. Broken, the popover is wider than the smallest window and the
/// dropdown sits at a fixed offset past its right edge; with `-fixed` the popover is small enough
/// for the middle of the window, and the dropdown opens under its button, inside the window.
/// The short menu is the control that passes in both.
struct PresentedScreen: View {
    let fixed: Bool
    @State private var more = false
    @State private var sort = false

    var body: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Menu("Actions") {
                    Button("Copy") {}
                    Button("Paste") {}
                }
                .accessibilityIdentifier("actions")
                .fixedSize()
                Button("More") { more.toggle() }
                    .accessibilityIdentifier("more")
                    .popover(isPresented: $more, arrowEdge: .bottom) {
                        Text("Details of the track")
                            .accessibilityIdentifier("moreContent")
                            .frame(width: fixed ? 100 : 460, height: fixed ? 60 : 160)
                    }
                Button("Sort") { sort.toggle() }
                    .accessibilityIdentifier("sort")
            }
            Spacer()
            Text("Presented UI").accessibilityIdentifier("caption")
        }
        .padding(16)
        .frame(minWidth: 280, maxWidth: .infinity, minHeight: 280, maxHeight: .infinity)
        .overlay(alignment: .topLeading) {
            if sort {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(["Title", "Artist", "Album", "Year"], id: \.self) { name in
                        Text(name).frame(maxWidth: .infinity, alignment: .leading).accessibilityIdentifier("sort\(name)")
                    }
                }
                .padding(8)
                .frame(width: 160)
                .background(.background)
                .border(.separator)
                .offset(x: fixed ? 60 : 200, y: 44)
            }
        }
    }
}
