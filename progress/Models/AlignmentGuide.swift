    import Foundation

struct AlignmentGuide: Codable {
    var eyeLinePosition: CGFloat // 0.0 to 1.0, from top
    var mouthLinePosition: CGFloat // 0.0 to 1.0, from top
    var isVisible: Bool
    var showsReferencePhoto: Bool

    init(eyeLinePosition: CGFloat, mouthLinePosition: CGFloat, isVisible: Bool = true,
         showsReferencePhoto: Bool = false) {
        self.eyeLinePosition = eyeLinePosition
        self.mouthLinePosition = mouthLinePosition
        self.isVisible = isVisible
        self.showsReferencePhoto = showsReferencePhoto
    }

    private enum CodingKeys: String, CodingKey {
        case eyeLinePosition, mouthLinePosition, isVisible, showsReferencePhoto
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        eyeLinePosition = try values.decode(CGFloat.self, forKey: .eyeLinePosition)
        mouthLinePosition = try values.decode(CGFloat.self, forKey: .mouthLinePosition)
        // Guides saved before visibility was configurable remain visible.
        isVisible = try values.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true
        showsReferencePhoto = try values.decodeIfPresent(Bool.self, forKey: .showsReferencePhoto) ?? false
    }

    static let `default` = AlignmentGuide(
        eyeLinePosition: 0.42,
        mouthLinePosition: 0.58
    )
}
