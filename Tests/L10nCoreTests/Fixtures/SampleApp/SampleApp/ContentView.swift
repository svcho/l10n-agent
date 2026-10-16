import SwiftUI
import os

struct ContentView: View {
    let name: String
    let count: Int
    @State private var email = ""
    @State private var showAlert = false
    private let logger = Logger(subsystem: "app", category: "ui")

    var body: some View {
        NavigationStack {
            VStack {
                Text("Welcome back")
                Text("Hello, \(name)!")
                Text("onboarding.title")
                Text(verbatim: "Build 42")
                Text("•")
                Button("Save changes") { save() }
                TextField("Email address", text: $email)
                Toggle("Dark mode", isOn: .constant(true))
                Label("Settings", systemImage: "gear")
                Image("logo")
                Text("You have \(count) messages")
                Text("Greeting: " + name)
                Text(String(localized: "Sign out"))
            }
            .navigationTitle("Home")
            .accessibilityLabel("Main screen")
            .alert("Delete item?", isPresented: $showAlert) {
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private func save() {
        logger.info("Saved \(email)")
        print("debug output")
        UserDefaults.standard.set(true, forKey: "didSave")
    }
}

#Preview {
    ContentView(name: "Preview Name", count: 3)
}
