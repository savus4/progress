import SwiftUI
import CoreData

struct PhotoPagerView: View {
    let photos: [DailyPhoto]
    @Binding var selectedIndex: Int
    @State private var currentPage: Int?

    var body: some View {
        GeometryReader { proxy in
            ScrollView(.horizontal) {
                LazyHStack(spacing: 0) {
                    ForEach(photos.indices, id: \.self) { index in
                        PhotoDetailView(photo: photos[index])
                            .frame(width: proxy.size.width, height: proxy.size.height)
                            .tag(index)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollIndicators(.hidden)
            .scrollPosition(id: $currentPage)
        }
        .background(Color.black.ignoresSafeArea())
        .onAppear {
            currentPage = selectedIndex
        }
        .onChange(of: currentPage) { _, newValue in
            if let newValue {
                selectedIndex = newValue
            }
        }
        .onChange(of: selectedIndex) { _, newValue in
            if currentPage != newValue {
                currentPage = newValue
            }
        }
    }
}

#Preview {
    PhotoPagerView(
        photos: [],
        selectedIndex: .constant(0)
    )
}
