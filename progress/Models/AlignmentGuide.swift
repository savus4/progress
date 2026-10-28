import Foundation

struct AlignmentGuide: Codable {
    var eyeLinePosition: CGFloat // 0.0 to 1.0, from top
    var mouthLinePosition: CGFloat // 0.0 to 1.0, from top
    var isVisible: Bool

    init(eyeLinePosition: CGFloat, mouthLinePosition: CGFloat, isVisible: Bool = true) {
        self.eyeLinePosition = eyeLinePosition
        self.mouthLinePosition = mouthLinePosition
        self.isVisible = isVisible
    }

    private enum CodingKeys: String, CodingKey {
        case eyeLinePosition, mouthLinePosition, isVisible
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        eyeLinePosition = try values.decode(CGFloat.self, forKey: .eyeLinePosition)
        mouthLinePosition = try values.decode(CGFloat.self, forKey: .mouthLinePosition)
        // Guides saved before visibility was configurable remain visible.
        isVisible = try values.decodeIfPresent(Bool.self, forKey: .isVisible) ?? true
    }

    static let `default` = AlignmentGuide(
        eyeLinePosition: 0.35,
        mouthLinePosition: 0.65
    )
}
