import SwiftUI

/// The icon of a dock menu, in a 22-point box.
struct DockMenuIcon: View {
    let systemName: String
    var tint = Theme.textPrimary

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: 22, height: 22)
            .contentShape(Rectangle())
    }
}

extension View {
    /// A borderless icon menu, as in a section header.
    func dockMenuStyle(tint: Color = Theme.textPrimary) -> some View {
        menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            // A borderless menu draws its label in the tint colour.
            .tint(tint)
            .fixedSize()
    }
}

/// A dock row's label, in the inspector's label column.
struct DockLabel: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(Theme.textSecondary)
            .frame(width: Layout.inspectorLabelWidth, alignment: .leading)
    }
}
