import Foundation

struct AlignmentGuide: Codable {
    var eyeLinePosition: CGFloat // 0.0 to 1.0, from top
    var mouthLinePosition: CGFloat // 0.0 to 1.0, from top
    
    static let `default` = AlignmentGuide(
        eyeLinePosition: 0.35,
        mouthLinePosition: 0.65
    )
}
