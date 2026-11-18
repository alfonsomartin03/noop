import Foundation
import Combine
import StrandAnalytics

/// User profile (age/sex/body metrics/HR-max) persisted in UserDefaults.
/// Powers HR zones, calories and recovery baselines.
@MainActor
// Each property writes itself to UserDefaults in didSet, so there is no separate 'save' step.
final class ProfileStore: ObservableObject {
    @Published var age: Int { didSet { d.set(age, forKey: K.age) } }
    @Published var sex: String { didSet { d.set(sex, forKey: K.sex) } }          // "male" | "female" | "nonbinary"
    @Published var weightKg: Double { didSet { d.set(weightKg, forKey: K.weight) } }
    @Published var heightCm: Double { didSet { d.set(heightCm, forKey: K.height) } }
    /// 0 = auto-estimate from age.
    @Published var hrMaxOverride: Int { didSet { d.set(hrMaxOverride, forKey: K.hrMax) } }
    /// Optional; used only by the Health functional-age model (#49) for a continuous age without birthday steps.
    @Published var birthDate: Date? {
        didSet { if let b = birthDate { d.set(b.timeIntervalSince1970, forKey: K.birth) } else { d.removeObject(forKey: K.birth) } }
    }

    /// Optional measured VO₂max (ml/kg/min) with its test method and date; used only by the functional-age model (#49).
    /// NOOP's HR-ratio estimate is never stored here.
    @Published var measuredVO2: Double? {
        didSet { if let v = measuredVO2 { d.set(v, forKey: K.vo2) } else { d.removeObject(forKey: K.vo2) } }
    }
    @Published var measuredVO2Method: String { didSet { d.set(measuredVO2Method, forKey: K.vo2Method) } }
    @Published var measuredVO2Date: Date { didSet { d.set(measuredVO2Date.timeIntervalSince1970, forKey: K.vo2Date) } }

    /// The measured VO₂max as the model input, or nil when none is entered.
    var measuredVO2Input: FunctionalAgeSnapshot.MeasuredVO2? {
        measuredVO2.map { FunctionalAgeSnapshot.MeasuredVO2(value: $0, method: measuredVO2Method, testedAt: measuredVO2Date) }
    }

    private let d = UserDefaults.standard
    private enum K {
        static let age = "profile.age", sex = "profile.sex", weight = "profile.weightKg"
        static let height = "profile.heightCm", hrMax = "profile.hrMaxOverride", birth = "profile.birthDate"
        static let vo2 = "profile.vo2max", vo2Method = "profile.vo2maxMethod", vo2Date = "profile.vo2maxDate"
    }

    init() {
        age = d.object(forKey: K.age) as? Int ?? 30
        sex = d.string(forKey: K.sex) ?? "male"
        weightKg = d.object(forKey: K.weight) as? Double ?? 75
        heightCm = d.object(forKey: K.height) as? Double ?? 178
        hrMaxOverride = d.object(forKey: K.hrMax) as? Int ?? 0
        birthDate = (d.object(forKey: K.birth) as? Double).map { Date(timeIntervalSince1970: $0) }
        measuredVO2 = d.object(forKey: K.vo2) as? Double
        measuredVO2Method = d.string(forKey: K.vo2Method) ?? "Lab test (CPET)"
        measuredVO2Date = (d.object(forKey: K.vo2Date) as? Double).map { Date(timeIntervalSince1970: $0) } ?? Date()
    }

    /// Tanaka estimate unless overridden.
    // 0 means 'not overridden': fall back to the Tanaka age formula.
    var hrMax: Int { hrMaxOverride > 0 ? hrMaxOverride : Int((208 - 0.7 * Double(age)).rounded()) }
}
