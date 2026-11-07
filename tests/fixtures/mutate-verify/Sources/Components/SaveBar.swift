import SwiftUI

public struct SaveBar: View {
    let onSave: () -> Void
    let onCancel: () -> Void
    public init(onSave: @escaping () -> Void, onCancel: @escaping () -> Void) {
        self.onSave = onSave
        self.onCancel = onCancel
    }
    public var body: some View {
        HStack {
            Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
            Button("Save", action: onSave).keyboardShortcut(.defaultAction)
        }
        .padding(Spacing.medium)
    }
}
