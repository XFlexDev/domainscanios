import SwiftUI
import UserNotifications

@main
struct DomainScannerApp: App {
    init() {
        // Alustetaan ilmoituskeskus ja pyydetään käyttöoikeus käynnistyksessä
        NotificationManager.shared.requestAuthorization()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
