import Foundation
import Combine

@MainActor
final class RideModel: ObservableObject {
    // MARK: - Persistent configuration
    @Published var riderWeightKg: Double { didSet { save() } }
    @Published var bikeWeightKg: Double { didSet { save() } }
    @Published var ftpW: Int { didSet { save() } }
    @Published var maxHR: Int { didSet { save() } }
    @Published var wheelCircumferenceM: Double { didSet { save() } }
    @Published var crr: Double { didSet { save() } }
    @Published var cda: Double { didSet { save() } }
    @Published var airDensity: Double { didSet { save() } }
    @Published var drivetrainEfficiency: Double { didSet { save() } }
    @Published var frontChainrings: [Int] { didSet { normalizeDrivetrain(); save() } }
    @Published var frontIndex: Int { didSet { save() } }
    @Published var cassette: [Int] { didSet { normalizeDrivetrain(); save() } }
    @Published var rearIndex: Int { didSet { save() } }

    // MARK: - Session state
    @Published var route: GPXRoute?
    @Published var routeName: String?
    @Published var distanceM: Double = 0
    @Published var elapsedSeconds: TimeInterval = 0
    @Published var status: String = "No route loaded"
    @Published var isRiding = false
    @Published var currentGradePercent: Double = 0
    @Published var currentElevationM: Double = 0
    @Published var virtualSpeedKPH: Double = 0
    @Published var targetPowerW: Int = 0
    @Published var targetResistancePercent: Double = 0
    @Published var rawGradePercent: Double = 0
    @Published var smoothedGradePercent: Double = 0
    @Published var logSampleCount: Int = 0

    private let defaults = UserDefaults.standard
    private let key = "RideClimb.PersistentConfig.v3"
    private var isLoading = true
    private var isNormalizing = false
    private var lastTick: Date?
    private var lastGearSignature: String?
    private var resistanceRampFrom: Double?
    private var resistanceRampTo: Double?
    private var resistanceRampStartedAt: Date?
    private var resistanceRampDurationS: Double = 0.6
    private var sessionLog: [SessionSample] = []

    // Terrain response / smoothing retained from the validated V1 control path.
    private let maxGradeLookAheadM: Double = 150.0
    private let minResistanceRampDurationS: Double = 0.6
    private let maxResistanceRampDurationS: Double = 3.0
    private let rampSecondsPerResistancePoint: Double = 0.045

    // Validated baseline controller retained for V1.
    private let flatResistancePercent: Double = 12.0
    private let resistancePointsPerGradePercent: Double = 2.25
    private let hardGearResistanceFloorFactor: Double = 18.5

    // Native Wahoo/Zwift virtual ratios, gear 1 ... 24.
    static let nativeVirtualRatios: [Double] = [
        0.75, 0.87, 0.99, 1.11, 1.23, 1.38, 1.53, 1.68,
        1.86, 2.04, 2.22, 2.40, 2.6099, 2.82, 3.03, 3.24,
        3.49, 3.74, 3.99, 4.2399, 4.54, 4.84, 5.14, 5.4899
    ]

    struct SessionSample {
        let timestamp: Date
        let elapsedSeconds: TimeInterval
        let distanceM: Double
        let rawGradePercent: Double
        let smoothedGradePercent: Double
        let elevationM: Double
        let frontTeeth: Int
        let rearTeeth: Int
        let requestedGearRatio: Double
        let nativeGear: Int
        let nativeGearRatio: Double
        let cadenceRPM: Double
        let virtualSpeedKPH: Double
        let targetPowerW: Int
        let targetResistancePercent: Double
        let actualPowerW: Int
        let power3sW: Int
        let heartRateBPM: Int
        let trainerSpeedKPH: Double
    }

    private struct PersistentConfig: Codable {
        var riderWeightKg: Double
        var bikeWeightKg: Double
        var ftpW: Int
        var maxHR: Int
        var wheelCircumferenceM: Double
        var crr: Double
        var cda: Double
        var airDensity: Double
        var drivetrainEfficiency: Double
        var frontChainrings: [Int]
        var frontIndex: Int
        var cassette: [Int]
        var rearIndex: Int
    }

    init() {
        riderWeightKg = 75
        bikeWeightKg = 9
        ftpW = 180
        maxHR = 190
        wheelCircumferenceM = 2.10
        crr = 0.005
        cda = 0.40
        airDensity = 1.225
        drivetrainEfficiency = 0.97
        frontChainrings = [40]
        frontIndex = 0
        cassette = [10,12,14,16,18,21,24,28,33,39,45,51]
        rearIndex = 7

        if let data = defaults.data(forKey: key),
           let cfg = try? JSONDecoder().decode(PersistentConfig.self, from: data) {
            riderWeightKg = cfg.riderWeightKg
            bikeWeightKg = cfg.bikeWeightKg
            ftpW = cfg.ftpW
            maxHR = cfg.maxHR
            wheelCircumferenceM = cfg.wheelCircumferenceM
            crr = cfg.crr
            cda = cfg.cda
            airDensity = cfg.airDensity
            drivetrainEfficiency = cfg.drivetrainEfficiency
            frontChainrings = cfg.frontChainrings.isEmpty ? frontChainrings : cfg.frontChainrings
            frontIndex = cfg.frontIndex
            cassette = cfg.cassette.isEmpty ? cassette : cfg.cassette
            rearIndex = cfg.rearIndex
        }
        normalizeDrivetrain()
        isLoading = false
    }

    var frontChainring: Int {
        guard !frontChainrings.isEmpty else { return 0 }
        return frontChainrings[min(max(frontIndex, 0), frontChainrings.count - 1)]
    }

    var rearSprocket: Int {
        guard !cassette.isEmpty else { return 0 }
        return cassette[min(max(rearIndex, 0), cassette.count - 1)]
    }

    var gearRatio: Double {
        guard frontChainring > 0, rearSprocket > 0 else { return 0 }
        return Double(frontChainring) / Double(rearSprocket)
    }

    var currentGearLabel: String { "\(frontChainring)×\(rearSprocket)" }
    var currentRatio: Double { gearRatio }
    var totalMassKg: Double { riderWeightKg + bikeWeightKg }

    var nativeGear: Int {
        nearestNativeGear(for: gearRatio)
    }

    var nativeGearRatio: Double {
        let index = min(max(nativeGear - 1, 0), Self.nativeVirtualRatios.count - 1)
        return Self.nativeVirtualRatios[index]
    }

    var progress: Double {
        guard let route, route.totalDistanceM > 0 else { return 0 }
        return min(1, distanceM / route.totalDistanceM)
    }

    var remainingDistanceM: Double {
        guard let route else { return 0 }
        return max(0, route.totalDistanceM - distanceM)
    }

    func nearestNativeGear(for ratio: Double) -> Int {
        guard ratio > 0 else { return 1 }
        var bestIndex = 0
        var bestDelta = Double.greatestFiniteMagnitude
        for (index, native) in Self.nativeVirtualRatios.enumerated() {
            let delta = abs(native - ratio)
            if delta < bestDelta {
                bestDelta = delta
                bestIndex = index
            }
        }
        return bestIndex + 1
    }

    // MARK: - Drivetrain setup
    func setChainringCount(_ count: Int) {
        if count <= 1 {
            let selected = frontChainring > 0 ? frontChainring : 40
            frontChainrings = [selected]
            frontIndex = 0
        } else {
            if frontChainrings.count == 1 {
                let current = frontChainrings[0]
                frontChainrings = current >= 48 ? [39, current] : [39, 53]
            }
            frontChainrings = Array(frontChainrings.prefix(2)).sorted()
            frontIndex = min(frontIndex, 1)
        }
        normalizeDrivetrain()
        save()
    }

    func setFrontTeeth(at index: Int, teeth: Int) {
        guard frontChainrings.indices.contains(index) else { return }
        frontChainrings[index] = min(70, max(20, teeth))
        frontChainrings.sort()
        normalizeDrivetrain()
        save()
    }

    func setCassette(_ values: [Int]) {
        let cleaned = Array(Set(values.filter { $0 >= 9 && $0 <= 60 })).sorted()
        guard cleaned.count >= 2 else { return }
        cassette = cleaned
        normalizeDrivetrain()
        save()
    }

    func shiftFrontSmaller() {
        guard frontChainrings.count > 1 else { return }
        frontIndex = max(0, frontIndex - 1)
    }

    func shiftFrontLarger() {
        guard frontChainrings.count > 1 else { return }
        frontIndex = min(frontChainrings.count - 1, frontIndex + 1)
    }

    func shiftRearSmaller() { // smaller sprocket = harder
        guard !cassette.isEmpty else { return }
        rearIndex = max(0, rearIndex - 1)
    }

    func shiftRearLarger() { // larger sprocket = easier
        guard !cassette.isEmpty else { return }
        rearIndex = min(cassette.count - 1, rearIndex + 1)
    }

    // MARK: - Route
    func loadGPX(url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: url)
        let parsed = try GPXParser().parse(data: data)
        route = parsed
        routeName = url.deletingPathExtension().lastPathComponent
        distanceM = 0
        elapsedSeconds = 0
        currentElevationM = parsed.elevation(at: 0)
        rawGradePercent = parsed.grade(at: 0, windowM: 10)
        smoothedGradePercent = parsed.forwardGrade(at: 0, lookAheadM: terrainLookAheadM(for: parsed))
        currentGradePercent = smoothedGradePercent
        resistanceRampFrom = nil
        resistanceRampTo = nil
        resistanceRampStartedAt = nil
        lastGearSignature = currentGearLabel
        virtualSpeedKPH = 0
        targetPowerW = 0
        isRiding = false
        lastTick = nil
        clearSessionLog()
        status = String(format: "Loaded %@ — %.1f km", routeName ?? "route", parsed.totalDistanceM / 1000)
    }

    func startRide() {
        guard route != nil else { status = "Import a GPX first"; return }
        isRiding = true
        lastTick = Date()
        status = "Ride running"
    }

    func pauseRide() {
        isRiding = false
        lastTick = nil
        status = "Ride paused"
    }

    func resetSession() {
        isRiding = false
        lastTick = nil
        distanceM = 0
        elapsedSeconds = 0
        virtualSpeedKPH = 0
        targetPowerW = 0
        if let route {
            currentElevationM = route.elevation(at: 0)
            rawGradePercent = route.grade(at: 0, windowM: 10)
            smoothedGradePercent = route.forwardGrade(at: 0, lookAheadM: terrainLookAheadM(for: route))
            currentGradePercent = smoothedGradePercent
            resistanceRampFrom = nil
            resistanceRampTo = nil
            resistanceRampStartedAt = nil
            lastGearSignature = currentGearLabel
            status = "Route reset"
        } else {
            currentElevationM = 0
            currentGradePercent = 0
            status = "No route loaded"
        }
    }

    // MARK: - Validated V1 control model
    private func terrainLookAheadM(for route: GPXRoute) -> Double {
        min(maxGradeLookAheadM, route.totalDistanceM / 20.0)
    }

    private func smoothstep(_ progress: Double) -> Double {
        let t = min(1.0, max(0.0, progress))
        return t * t * (3.0 - 2.0 * t)
    }

    private func rampDurationSeconds(from: Double, to: Double) -> Double {
        min(maxResistanceRampDurationS,
            max(minResistanceRampDurationS, abs(to - from) * rampSecondsPerResistancePoint))
    }

    private func currentRampedResistance(at now: Date) -> Double? {
        guard let from = resistanceRampFrom,
              let to = resistanceRampTo,
              let started = resistanceRampStartedAt else { return nil }
        let duration = max(0.001, resistanceRampDurationS)
        let progress = now.timeIntervalSince(started) / duration
        if progress >= 1 { return to }
        return from + (to - from) * smoothstep(progress)
    }

    private var neutralGearRatio: Double {
        guard !cassette.isEmpty else { return max(gearRatio, 1.0) }
        let middle = cassette[cassette.count / 2]
        return Double(max(frontChainring, 1)) / Double(middle)
    }

    func resistanceForCurrentState(gradePercent: Double) -> Double {
        let terrain = min(55.0, max(4.0,
            flatResistancePercent + gradePercent * resistancePointsPerGradePercent))
        let neutral = max(0.1, neutralGearRatio)
        let relativeRatio = max(0.1, gearRatio) / neutral
        let gearFactor = pow(relativeRatio, 2.0)
        let massFactor = max(0.25, min(5.0, totalMassKg / 90.0))
        var result = terrain * gearFactor * massFactor
        if gearFactor > 1.0 {
            let floor = (gearFactor - 1.0) * hardGearResistanceFloorFactor
            result = max(result, floor)
        }
        return min(100.0, max(0.0, result))
    }

    func speedKPH(from cadenceRPM: Double) -> Double {
        guard cadenceRPM > 0, nativeGearRatio > 0, wheelCircumferenceM > 0 else { return 0 }
        return cadenceRPM * nativeGearRatio * wheelCircumferenceM * 60.0 / 1000.0
    }

    func physicalPowerW(gradePercent: Double, speedKPH: Double) -> Double {
        let g = 9.81
        let v = max(0, speedKPH) / 3.6
        guard v > 0 else { return 0 }
        let theta = atan(gradePercent / 100.0)
        let mass = totalMassKg
        let gravity = mass * g * sin(theta)
        let rolling = mass * g * crr * cos(theta)
        let aero = 0.5 * airDensity * cda * v * v
        return max(0, v * (gravity + rolling + aero) / max(0.5, drivetrainEfficiency))
    }

    /// Advances the route and returns the validated V1 resistance command.
    func tick(cadenceRPM: Double, now: Date = Date()) -> Double? {
        guard isRiding, let route else { lastTick = now; return nil }
        guard let previous = lastTick else { lastTick = now; return nil }

        let dt = min(2.0, max(0, now.timeIntervalSince(previous)))
        lastTick = now
        guard dt > 0 else { return targetResistancePercent }

        virtualSpeedKPH = speedKPH(from: cadenceRPM)
        distanceM = min(route.totalDistanceM, distanceM + (virtualSpeedKPH / 3.6) * dt)
        elapsedSeconds += dt
        currentElevationM = route.elevation(at: distanceM)
        rawGradePercent = min(30, max(-30, route.grade(at: distanceM, windowM: 10)))
        let lookAhead = terrainLookAheadM(for: route)
        smoothedGradePercent = route.forwardGrade(at: distanceM, lookAheadM: lookAhead)
        currentGradePercent = smoothedGradePercent

        let requestedResistance = resistanceForCurrentState(gradePercent: currentGradePercent)
        let gearSignature = currentGearLabel
        let gearChanged = lastGearSignature != nil && lastGearSignature != gearSignature
        lastGearSignature = gearSignature

        let outputResistance: Double
        if gearChanged {
            outputResistance = requestedResistance
            resistanceRampFrom = requestedResistance
            resistanceRampTo = requestedResistance
            resistanceRampStartedAt = now
            resistanceRampDurationS = minResistanceRampDurationS
        } else {
            let current = currentRampedResistance(at: now) ?? targetResistancePercent
            if resistanceRampTo == nil || abs(requestedResistance - (resistanceRampTo ?? requestedResistance)) >= 0.5 {
                resistanceRampFrom = current
                resistanceRampTo = requestedResistance
                resistanceRampStartedAt = now
                resistanceRampDurationS = rampDurationSeconds(from: current, to: requestedResistance)
            }
            outputResistance = currentRampedResistance(at: now) ?? requestedResistance
        }

        targetResistancePercent = min(100, max(0, outputResistance))
        targetPowerW = Int(physicalPowerW(gradePercent: currentGradePercent, speedKPH: virtualSpeedKPH).rounded())

        if distanceM >= route.totalDistanceM {
            isRiding = false
            status = "Route complete"
        }
        return targetResistancePercent
    }

    // MARK: - Logging
    func recordSample(actualPowerW: Int,
                      power3sW: Int,
                      heartRateBPM: Int,
                      trainerSpeedKPH: Double,
                      cadenceRPM: Double,
                      now: Date = Date()) {
        guard route != nil else { return }
        sessionLog.append(SessionSample(
            timestamp: now,
            elapsedSeconds: elapsedSeconds,
            distanceM: distanceM,
            rawGradePercent: rawGradePercent,
            smoothedGradePercent: smoothedGradePercent,
            elevationM: currentElevationM,
            frontTeeth: frontChainring,
            rearTeeth: rearSprocket,
            requestedGearRatio: gearRatio,
            nativeGear: nativeGear,
            nativeGearRatio: nativeGearRatio,
            cadenceRPM: cadenceRPM,
            virtualSpeedKPH: virtualSpeedKPH,
            targetPowerW: targetPowerW,
            targetResistancePercent: targetResistancePercent,
            actualPowerW: actualPowerW,
            power3sW: power3sW,
            heartRateBPM: heartRateBPM,
            trainerSpeedKPH: trainerSpeedKPH
        ))
        logSampleCount = sessionLog.count
    }

    func clearSessionLog() {
        sessionLog.removeAll(keepingCapacity: true)
        logSampleCount = 0
    }

    func sessionCSV() -> String {
        var lines = [
            "timestamp,elapsed_s,distance_m,raw_grade_pct,filtered_grade_pct,elevation_m,front_teeth,rear_teeth,requested_ratio,native_gear,native_ratio,cadence_rpm,virtual_speed_kph,theoretical_power_w,target_resistance_pct,actual_power_w,power_3s_w,heart_rate_bpm,trainer_speed_kph"
        ]
        let iso = ISO8601DateFormatter()
        for s in sessionLog {
            lines.append([
                iso.string(from: s.timestamp),
                String(format: "%.1f", s.elapsedSeconds),
                String(format: "%.1f", s.distanceM),
                String(format: "%.3f", s.rawGradePercent),
                String(format: "%.3f", s.smoothedGradePercent),
                String(format: "%.1f", s.elevationM),
                "\(s.frontTeeth)",
                "\(s.rearTeeth)",
                String(format: "%.4f", s.requestedGearRatio),
                "\(s.nativeGear)",
                String(format: "%.4f", s.nativeGearRatio),
                String(format: "%.1f", s.cadenceRPM),
                String(format: "%.2f", s.virtualSpeedKPH),
                "\(s.targetPowerW)",
                String(format: "%.2f", s.targetResistancePercent),
                "\(s.actualPowerW)",
                "\(s.power3sW)",
                "\(s.heartRateBPM)",
                String(format: "%.2f", s.trainerSpeedKPH)
            ].joined(separator: ","))
        }
        return lines.joined(separator: "\n")
    }

    func writeSessionCSV() throws -> URL {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let routePart = (routeName ?? "RideClimb")
            .replacingOccurrences(of: " ", with: "_")
            .replacingOccurrences(of: "/", with: "-")
        let filename = "\(routePart)_\(formatter.string(from: Date())).csv"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
        try sessionCSV().write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func normalizeDrivetrain() {
        guard !isNormalizing else { return }
        isNormalizing = true
        defer { isNormalizing = false }

        if frontChainrings.isEmpty { frontChainrings = [40] }
        if frontChainrings.count > 2 { frontChainrings = Array(frontChainrings.prefix(2)) }
        frontChainrings = frontChainrings.map { min(70, max(20, $0)) }.sorted()
        frontIndex = min(max(0, frontIndex), frontChainrings.count - 1)

        if cassette.isEmpty { cassette = [11,12,13,14,15,17,19,21,24,27,30,34] }
        cassette = Array(Set(cassette.filter { $0 >= 9 && $0 <= 60 })).sorted()
        if cassette.count < 2 { cassette = [11, 28] }
        rearIndex = min(max(0, rearIndex), cassette.count - 1)
    }

    private func save() {
        guard !isLoading, !isNormalizing else { return }
        let cfg = PersistentConfig(
            riderWeightKg: riderWeightKg,
            bikeWeightKg: bikeWeightKg,
            ftpW: ftpW,
            maxHR: maxHR,
            wheelCircumferenceM: wheelCircumferenceM,
            crr: crr,
            cda: cda,
            airDensity: airDensity,
            drivetrainEfficiency: drivetrainEfficiency,
            frontChainrings: frontChainrings,
            frontIndex: frontIndex,
            cassette: cassette,
            rearIndex: rearIndex
        )
        if let data = try? JSONEncoder().encode(cfg) {
            defaults.set(data, forKey: key)
        }
    }
}
