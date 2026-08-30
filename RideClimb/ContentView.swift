import SwiftUI
import UniformTypeIdentifiers
import Foundation

struct ContentView: View {
    @EnvironmentObject private var trainer: TrainerManager
    @EnvironmentObject private var ride: RideModel

    @State private var showImporter = false
    @State private var lastSentResistance: Double?
    @State private var exportURL: URL?
    @State private var showShareSheet = false
    @State private var lastLogSampleAt: Date?
    @State private var showDiagnostics = false

    // Drivetrain draft: nothing changes until Apply drivetrain is pressed.
    @State private var draftChainringCount = 1
    @State private var draftFront1 = 40
    @State private var draftFront2 = 53
    @State private var draftCassette = ""
    @State private var drivetrainDirty = false
    @State private var appliedMessage = false

    private let timer = Timer.publish(every: 0.2, on: .main, in: .common).autoconnect()

    var body: some View {
        TabView {
            ridePage
                .tabItem { Label("Ride", systemImage: "bicycle") }
            setupPage
                .tabItem { Label("Setup", systemImage: "slider.horizontal.3") }
            dataPage
                .tabItem { Label("Data", systemImage: "doc.text") }
        }
        .onAppear { loadDrivetrainDraft() }
        .onReceive(timer) { now in
            guard trainer.controlReady else { return }
            if let targetResistance = ride.tick(cadenceRPM: trainer.cadenceRPM, now: now) {
                if lastSentResistance == nil || abs(targetResistance - (lastSentResistance ?? 0)) >= 0.5 {
                    trainer.setTargetResistance(targetResistance)
                    lastSentResistance = targetResistance
                }
            }
            if trainer.nativeVirtualShiftReady && trainer.nativeVirtualGear != ride.nativeGear {
                trainer.setVirtualRatio(ride.currentRatio)
            }
            if ride.isRiding {
                if lastLogSampleAt == nil || now.timeIntervalSince(lastLogSampleAt!) >= 0.5 {
                    ride.recordSample(actualPowerW: trainer.powerW, power3sW: trainer.power3sW,
                                      heartRateBPM: trainer.heartRateBPM, trainerSpeedKPH: trainer.speedKPH,
                                      cadenceRPM: trainer.cadenceRPM, now: now)
                    lastLogSampleAt = now
                }
            } else { lastLogSampleAt = nil }
        }
        .sheet(isPresented: $showShareSheet) {
            if let exportURL { ShareSheet(items: [exportURL]) }
        }
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [UTType(filenameExtension: "gpx") ?? .xml],
                      allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                do { try ride.loadGPX(url: url); lastSentResistance = nil }
                catch { ride.status = "GPX error: \(error.localizedDescription)" }
            case .failure(let error): ride.status = "Import error: \(error.localizedDescription)"
            }
        }
    }

    private var ridePage: some View {
        NavigationStack {
            GeometryReader { geo in
                let compact = geo.size.height < 700
                let cardRadius: CGFloat = 22
                let sidePadding: CGFloat = 14
                let verticalGap: CGFloat = compact ? 8 : 10

                VStack(spacing: verticalGap) {
                    connectionStrip
                        .padding(.horizontal, 2)

                    // Main performance cards: intentionally dominant.
                    HStack(spacing: 10) {
                        intensityTile(title: "POWER 3s",
                                      value: "\(trainer.power3sW)",
                                      unit: "W",
                                      subtitle: powerSubtitle,
                                      color: powerZoneColor)
                        intensityTile(title: "HEART RATE",
                                      value: trainer.heartRateBPM > 0 ? "\(trainer.heartRateBPM)" : "—",
                                      unit: trainer.heartRateBPM > 0 ? "bpm" : "",
                                      subtitle: hrSubtitle,
                                      color: hrZoneColor)
                    }
                    .frame(height: compact ? 122 : 138)

                    // Secondary metrics.
                    HStack(spacing: 8) {
                        metricCard("GRADE", String(format: "%.1f%%", ride.currentGradePercent))
                        metricCard("CADENCE", String(format: "%.0f", trainer.cadenceRPM), suffix: "rpm")
                        metricCard("SPEED", String(format: "%.1f", ride.virtualSpeedKPH), suffix: "km/h")
                        metricCard("GEAR", ride.currentGearLabel)
                    }
                    .frame(height: compact ? 62 : 68)

                    // Route profile card.
                    Group {
                        if let route = ride.route {
                            VStack(spacing: 4) {
                                RouteProfileView(route: route, progress: ride.progress)
                                    .frame(height: compact ? 88 : 105)

                                HStack {
                                    Text(ride.routeName ?? "GPX")
                                        .font(.caption.weight(.semibold))
                                        .lineLimit(1)
                                    Spacer()
                                    Text(String(format: "%.1f / %.1f km",
                                                ride.distanceM / 1000,
                                                route.totalDistanceM / 1000))
                                        .font(.caption.monospacedDigit())
                                }
                                .foregroundStyle(.secondary)
                            }
                            .padding(10)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: cardRadius))
                        } else {
                            VStack(spacing: 6) {
                                Image(systemName: "mountain.2.fill")
                                    .font(.title2)
                                    .foregroundStyle(.secondary)
                                Text("Select a route in Setup")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, minHeight: compact ? 108 : 125)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: cardRadius))
                        }
                    }

                    // Large shifter buttons, easy to hit while riding.
                    HStack(spacing: 12) {
                        shiftPad(
                            title: "CHAINRING",
                            minus: { ride.shiftFrontSmaller(); syncNativeGear() },
                            plus: { ride.shiftFrontLarger(); syncNativeGear() },
                            minusDisabled: ride.frontChainrings.count < 2 || ride.frontIndex == 0,
                            plusDisabled: ride.frontChainrings.count < 2 || ride.frontIndex >= ride.frontChainrings.count - 1
                        )

                        shiftPad(
                            title: "SPROCKET",
                            minus: { ride.shiftRearSmaller(); syncNativeGear() },
                            plus: { ride.shiftRearLarger(); syncNativeGear() },
                            minusDisabled: ride.rearIndex == 0,
                            plusDisabled: ride.rearIndex >= ride.cassette.count - 1
                        )
                    }
                    .frame(height: compact ? 72 : 82)

                    // Ride controls only. GPX import lives in Setup.
                    HStack(spacing: 12) {
                        Button {
                            if ride.isRiding {
                                ride.pauseRide()
                            } else {
                                syncNativeGear()
                                ride.startRide()
                            }
                        } label: {
                            Label(ride.isRiding ? "Pause" : "Start",
                                  systemImage: ride.isRiding ? "pause.fill" : "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                        .disabled(ride.route == nil || !trainer.controlReady)

                        Button {
                            ride.resetSession()
                            lastSentResistance = nil
                        } label: {
                            Label("Reset", systemImage: "arrow.counterclockwise")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .disabled(ride.route == nil)
                    }
                    .frame(height: compact ? 46 : 52)
                }
                .padding(.horizontal, sidePadding)
                .padding(.top, 4)
                .padding(.bottom, 4)
                .frame(width: geo.size.width, height: geo.size.height, alignment: .top)
            }
            .navigationTitle("RideClimb")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var setupPage: some View {
        NavigationStack {
            Form {
                Section("Route") {
                    Button("Import GPX") { showImporter = true }
                    if let route = ride.route {
                        Text(ride.routeName ?? "GPX")
                        Text(String(format: "%.1f km", route.totalDistanceM/1000)).foregroundStyle(.secondary)
                    }
                }
                Section("Smart trainer") {
                    HStack {
                        Button("Scan") { trainer.startScan() }
                        Spacer()
                        Button("Disconnect") { trainer.disconnect() }.disabled(!trainer.isConnected)
                    }
                    if !trainer.discoveredTrainers.isEmpty {
                        Picker("Trainer", selection: $trainer.selectedTrainerID) {
                            Text("Select").tag(Optional<UUID>.none)
                            ForEach(trainer.discoveredTrainers) { Text($0.name).tag(Optional($0.id)) }
                        }
                        Button("Connect trainer") { trainer.connectSelected() }
                    }
                }
                Section("Heart-rate sensor") {
                    HStack {
                        Button("Scan HR") { trainer.startHeartRateScan() }
                        Spacer()
                        Button("Disconnect HR") { trainer.disconnectHeartRate() }.disabled(!trainer.heartRateConnected)
                    }
                    if !trainer.discoveredHeartRateDevices.isEmpty {
                        Picker("HR sensor", selection: $trainer.selectedHeartRateID) {
                            Text("Select").tag(Optional<UUID>.none)
                            ForEach(trainer.discoveredHeartRateDevices) { Text($0.name).tag(Optional($0.id)) }
                        }
                        Button("Connect HR") { trainer.connectSelectedHeartRate() }
                    }
                }
                Section("Rider") {
                    Stepper("Rider weight: \(Int(ride.riderWeightKg)) kg", value: $ride.riderWeightKg, in: 40...150)
                    Stepper("Bike + equipment: \(Int(ride.bikeWeightKg)) kg", value: $ride.bikeWeightKg, in: 5...30)
                    Stepper("FTP: \(ride.ftpW) W", value: $ride.ftpW, in: 50...500, step: 5)
                    Stepper("HR max: \(ride.maxHR) bpm", value: $ride.maxHR, in: 100...230)
                }
                Section("Drivetrain") {
                    Picker("Chainrings", selection: dirtyBinding($draftChainringCount)) {
                        Text("1x").tag(1); Text("2x").tag(2)
                    }.pickerStyle(.segmented)
                    Stepper("Chainring 1: \(draftFront1)T", value: dirtyBinding($draftFront1), in: 20...70)
                    if draftChainringCount == 2 {
                        Stepper("Chainring 2: \(draftFront2)T", value: dirtyBinding($draftFront2), in: 20...70)
                    }
                    TextField("Cassette: 11,12,13,14,15,17,19,21,24,27,30,34", text: dirtyBinding($draftCassette))
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button(drivetrainDirty ? "Apply drivetrain" : (appliedMessage ? "Applied ✓" : "Apply drivetrain")) {
                        applyDrivetrain()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!drivetrainDirty)
                    Text("Current: \(ride.frontChainrings.map(String.init).joined(separator: "/")) × \(ride.cassette.map(String.init).joined(separator: "-"))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Setup")
        }
    }

    private var dataPage: some View {
        NavigationStack {
            Form {
                Section("Activity log") {
                    Text("\(ride.logSampleCount) samples")
                    Button("Export CSV") {
                        do { exportURL = try ride.writeSessionCSV(); showShareSheet = true }
                        catch { ride.status = "Log export error: \(error.localizedDescription)" }
                    }.disabled(ride.logSampleCount == 0)
                }
                Section {
                    DisclosureGroup("Diagnostics", isExpanded: $showDiagnostics) {
                        Text(String(format: "raw grade %.2f%% • filtered %.2f%% • target resistance %.2f%% • theoretical %.0f W",
                                    ride.rawGradePercent, ride.smoothedGradePercent, ride.targetResistancePercent, Double(ride.targetPowerW)))
                            .font(.caption2).foregroundStyle(.secondary)
                        ScrollView {
                            Text(trainer.logText).font(.system(.caption2, design: .monospaced))
                                .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                        }.frame(minHeight: 160, maxHeight: 360)
                    }
                }
            }
            .navigationTitle("Data")
        }
    }

    private var connectionStrip: some View {
        HStack(spacing: 8) {
            Circle().fill(trainer.controlReady ? Color.green : (trainer.isConnected ? Color.orange : Color.gray)).frame(width: 8, height: 8)
            Text(trainer.controlReady ? "Trainer ready" : trainer.connectionState).font(.caption.weight(.semibold))
            Spacer()
            if trainer.heartRateConnected { Image(systemName: "heart.fill").foregroundStyle(.red) }
            if trainer.nativeVirtualShiftReady { Text("VSHIFT").font(.caption2.bold()).foregroundStyle(.green) }
        }
    }

    private func intensityTile(title: String, value: String, unit: String, subtitle: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption.weight(.bold)).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value).font(.system(size: 44, weight: .bold, design: .rounded)).minimumScaleFactor(0.6)
                Text(unit).font(.headline.weight(.semibold))
            }.foregroundStyle(color)
            Text(subtitle).font(.caption.weight(.semibold)).foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, minHeight: 115, alignment: .leading).padding(12)
        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(color.opacity(0.22)))
    }

    private func compactMetric(_ title: String, _ value: String) -> some View {
        VStack(spacing: 2) {
            Text(title).font(.system(size: 9, weight: .bold)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 16, weight: .bold, design: .rounded)).minimumScaleFactor(0.55).lineLimit(1)
        }.frame(maxWidth: .infinity).padding(.vertical, 8).background(.thinMaterial, in: RoundedRectangle(cornerRadius: 11))
    }

    private func compactShifter(label: String, minus: @escaping () -> Void, plus: @escaping () -> Void,
                                minusDisabled: Bool, plusDisabled: Bool) -> some View {
        HStack(spacing: 8) {
            Button(action: minus) { Image(systemName: "minus").frame(width: 34, height: 30) }.buttonStyle(.bordered).disabled(minusDisabled)
            Text(label).font(.caption2.bold()).foregroundStyle(.secondary).frame(minWidth: 68)
            Button(action: plus) { Image(systemName: "plus").frame(width: 34, height: 30) }.buttonStyle(.bordered).disabled(plusDisabled)
        }.frame(maxWidth: .infinity)
    }

    private func metricCard(_ title: String, _ value: String, suffix: String = "") -> some View {
        VStack(spacing: 3) {
            Text(title)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .minimumScaleFactor(0.55)
                    .lineLimit(1)
                if !suffix.isEmpty {
                    Text(suffix)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private func shiftPad(title: String,
                          minus: @escaping () -> Void,
                          plus: @escaping () -> Void,
                          minusDisabled: Bool,
                          plusDisabled: Bool) -> some View {
        VStack(spacing: 6) {
            Text(title)
                .font(.caption2.bold())
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                Button(action: minus) {
                    Image(systemName: "minus")
                        .font(.title3.bold())
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(minusDisabled)

                Button(action: plus) {
                    Image(systemName: "plus")
                        .font(.title3.bold())
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(plusDisabled)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    private func dirtyBinding<T>(_ binding: Binding<T>) -> Binding<T> {
        Binding(get: { binding.wrappedValue }, set: { binding.wrappedValue = $0; drivetrainDirty = true; appliedMessage = false })
    }

    private func loadDrivetrainDraft() {
        draftChainringCount = ride.frontChainrings.count
        draftFront1 = ride.frontChainrings.first ?? 40
        draftFront2 = ride.frontChainrings.count > 1 ? ride.frontChainrings[1] : max(53, draftFront1)
        draftCassette = ride.cassette.map(String.init).joined(separator: ",")
        drivetrainDirty = false
    }

    private func applyDrivetrain() {
        let cassette = draftCassette.split(whereSeparator: { $0 == "," || $0 == ";" || $0 == " " || $0 == "-" }).compactMap { Int($0) }
        guard cassette.count >= 2 else { ride.status = "Drivetrain error: enter at least two sprockets"; return }
        ride.setChainringCount(draftChainringCount)
        ride.setFrontTeeth(at: 0, teeth: draftFront1)
        if draftChainringCount == 2 { ride.setFrontTeeth(at: 1, teeth: draftFront2) }
        ride.setCassette(cassette)
        loadDrivetrainDraft()
        syncNativeGear()
        appliedMessage = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { appliedMessage = false }
    }

    private func syncNativeGear() {
        lastSentResistance = nil
        if trainer.nativeVirtualShiftReady { trainer.setVirtualRatio(ride.currentRatio) }
    }

    private var powerFraction: Double { ride.ftpW > 0 ? Double(trainer.power3sW)/Double(ride.ftpW) : 0 }
    private var hrFraction: Double { ride.maxHR > 0 && trainer.heartRateBPM > 0 ? Double(trainer.heartRateBPM)/Double(ride.maxHR) : 0 }
    private var powerSubtitle: String { trainer.power3sW > 0 ? String(format: "%.0f%% FTP", powerFraction*100) : "— % FTP" }
    private var hrSubtitle: String { trainer.heartRateBPM > 0 ? String(format: "%.0f%% HRmax", hrFraction*100) : "Connect HR sensor" }
    private var powerZoneColor: Color { zoneColor(fraction: powerFraction, thresholds: [0.55,0.75,0.90,1.05,1.20]) }
    private var hrZoneColor: Color { trainer.heartRateBPM > 0 ? zoneColor(fraction: hrFraction, thresholds: [0.60,0.70,0.80,0.90,0.95]) : .gray }
    private func zoneColor(fraction: Double, thresholds: [Double]) -> Color {
        if fraction < thresholds[0] { return .gray }; if fraction < thresholds[1] { return .blue }
        if fraction < thresholds[2] { return .green }; if fraction < thresholds[3] { return .yellow }
        if fraction < thresholds[4] { return .orange }; return .red
    }
}

private struct RouteProfileView: View {
    let route: GPXRoute
    let progress: Double
    var body: some View {
        GeometryReader { _ in
            let points = route.points
            if points.count >= 2 {
                let minE = points.map(\.elevationM).min() ?? 0
                let maxE = points.map(\.elevationM).max() ?? minE + 1
                let spanE = max(1, maxE-minE); let maxD = max(1, route.totalDistanceM)
                Canvas { context, size in
                    var profile = Path()
                    for (index, point) in points.enumerated() {
                        let x = CGFloat(point.distanceM/maxD)*size.width
                        let y = size.height - CGFloat((point.elevationM-minE)/spanE)*(size.height-10)-5
                        if index == 0 { profile.move(to: CGPoint(x:x,y:y)) } else { profile.addLine(to: CGPoint(x:x,y:y)) }
                    }
                    context.stroke(profile, with: .color(.primary), lineWidth: 2)
                    let x = CGFloat(min(1,max(0,progress)))*size.width
                    var marker = Path(); marker.move(to: CGPoint(x:x,y:0)); marker.addLine(to: CGPoint(x:x,y:size.height))
                    context.stroke(marker, with: .color(.red), lineWidth: 2)
                }.background(.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }
}
