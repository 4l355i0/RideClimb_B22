import SwiftUI

@main
struct RideClimbApp: App {
    @StateObject private var trainer = TrainerManager()
    @StateObject private var ride = RideModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(trainer)
                .environmentObject(ride)
        }
    }
}
