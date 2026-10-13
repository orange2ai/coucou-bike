import SwiftUI

@main
struct BikeCuesApp: App {
    var body: some Scene {
        WindowGroup {
            LogView()
                .preferredColorScheme(.dark)
        }
    }
}
