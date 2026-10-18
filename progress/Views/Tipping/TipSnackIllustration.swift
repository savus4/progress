import SwiftUI

struct TipSnackIllustration: View {
    let option: TipOption

    var body: some View {
        ZStack {
            switch option {
            case .chips:
                chips
            case .fries:
                fries
            case .custom:
                Image(systemName: "heart.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.orange.gradient)
                    .padding(14)
            }
        }
        .frame(width: 80, height: 88)
        .accessibilityHidden(true)
    }

    private var chips: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9)
                .fill(.orange.gradient)
                .frame(width: 58, height: 76)
            ForEach([-1.0, 1.0], id: \.self) { direction in
                UnevenRoundedRectangle(topLeadingRadius: 2, bottomLeadingRadius: 2, bottomTrailingRadius: 2, topTrailingRadius: 2)
                    .fill(.yellow.gradient)
                    .frame(width: 62, height: 7)
                    .offset(y: direction * 35)
            }
            Ellipse()
                .fill(.white.opacity(0.95))
                .frame(width: 44, height: 43)
            Ellipse()
                .fill(.yellow.gradient)
                .strokeBorder(.orange.opacity(0.4), lineWidth: 1)
                .frame(width: 21, height: 30)
                .rotationEffect(.degrees(-28))
                .offset(x: -6, y: -2)
            Ellipse()
                .fill(.yellow.gradient)
                .strokeBorder(.orange.opacity(0.4), lineWidth: 1)
                .frame(width: 21, height: 30)
                .rotationEffect(.degrees(25))
                .offset(x: 7, y: 5)
        }
        .rotationEffect(.degrees(-9))
        .shadow(color: .orange.opacity(0.18), radius: 5, y: 4)
    }

    private var fries: some View {
        ZStack(alignment: .bottom) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<5) { index in
                    RoundedRectangle(cornerRadius: 3)
                        .fill(.yellow.gradient)
                        .frame(width: 8, height: [62.0, 73, 67, 77, 61][index])
                        .rotationEffect(.degrees(Double(index - 2) * 5))
                }
            }
            .padding(.bottom, 6)

            UnevenRoundedRectangle(topLeadingRadius: 3, bottomLeadingRadius: 16, bottomTrailingRadius: 16, topTrailingRadius: 3)
                .fill(.red.gradient)
                .frame(width: 58, height: 43)
                .overlay {
                    Image(systemName: "heart.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                }
        }
        .frame(height: 80)
        .rotationEffect(.degrees(9))
        .shadow(color: .red.opacity(0.14), radius: 5, y: 4)
    }
}
