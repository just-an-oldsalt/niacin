import Foundation

struct ActivationDuration: Identifiable, Hashable {
    let seconds: Int? // nil = indefinite

    var id: Int { seconds ?? -1 }

    static let indefinite = ActivationDuration(seconds: nil)

    static func minutes(_ m: Int) -> ActivationDuration {
        ActivationDuration(seconds: m * 60)
    }

    static func hours(_ h: Int) -> ActivationDuration {
        ActivationDuration(seconds: h * 3600)
    }

    var displayTitle: String {
        guard let s = seconds else { return "Indefinitely" }
        let h = s / 3600
        let m = (s % 3600) / 60
        switch (h, m) {
        case (0, _): return "\(m) \(m == 1 ? "minute" : "minutes")"
        case (_, 0): return "\(h) \(h == 1 ? "hour" : "hours")"
        default:     return "\(h)h \(m)m"
        }
    }

    var timeInterval: TimeInterval? {
        seconds.map { TimeInterval($0) }
    }
}
