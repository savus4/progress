import Foundation

actor LocationNameCacheService {
    static let shared = LocationNameCacheService()

    private let storageKey = "cachedLocationNamesByCoordinate"
    private var cache: [String: String]

    private init() {
        if let persisted = UserDefaults.standard.dictionary(forKey: storageKey) as? [String: String] {
            cache = persisted
        } else {
            cache = [:]
        }
    }

    func cachedName(for latitude: Double, longitude: Double) -> String? {
        cache[cacheKey(latitude: latitude, longitude: longitude)]
    }

    func setCachedName(_ name: String, for latitude: Double, longitude: Double) {
        cache[cacheKey(latitude: latitude, longitude: longitude)] = name
        UserDefaults.standard.set(cache, forKey: storageKey)
    }

    private func cacheKey(latitude: Double, longitude: Double) -> String {
        let roundedLatitude = (latitude * 10_000).rounded() / 10_000
        let roundedLongitude = (longitude * 10_000).rounded() / 10_000
        return "\(roundedLatitude),\(roundedLongitude)"
    }
}
