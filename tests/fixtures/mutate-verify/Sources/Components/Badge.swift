import SwiftUI

public struct Badge: View {
    let text: String
    public init(text: String) { self.text = text }
    public var body: some View {
        Text(text)
            .padding(Spacing.small)
            .background(Capsule().fill(Color.accentColor.opacity(0.2)))
    }
}
