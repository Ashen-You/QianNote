import SwiftUI

@main
struct SlateApp: App {
    @StateObject private var store = NoteStore()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(store)
                .tint(Theme.accent)
        }
    }
}
