import SwiftUI

/// Keeps related form sections together while making use of wider sheet presentations.
struct AdaptiveSheetForm<PrimaryContent: View, SecondaryContent: View>: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private let primaryContent: PrimaryContent
    private let secondaryContent: SecondaryContent

    init(
        @ViewBuilder primary: () -> PrimaryContent,
        @ViewBuilder secondary: () -> SecondaryContent
    ) {
        primaryContent = primary()
        secondaryContent = secondary()
    }

    var body: some View {
        GeometryReader { geometry in
            // Size classes alone don't describe the space available inside a sheet.
            if horizontalSizeClass == .regular,
               geometry.size.width >= 700,
               !dynamicTypeSize.isAccessibilitySize {
                HStack(alignment: .top, spacing: 0) {
                    Form {
                        primaryContent
                    }

                    Form {
                        secondaryContent
                    }
                }
                .contentMargins(.horizontal, 16, for: .scrollContent)
            } else {
                Form {
                    primaryContent
                    secondaryContent
                }
            }
        }
    }
}
