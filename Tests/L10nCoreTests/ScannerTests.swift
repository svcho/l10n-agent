import Foundation
import Testing
@testable import L10nCore

@Suite("Swift scanner")
struct ScannerTests {
    func scan(_ source: String, path: String = "App/View.swift") -> [StringSite] {
        SwiftScanner().scan(source: source, path: path)
    }

    @Test func swiftUIKeysAndLocalizedCalls() {
        let sites = scan("""
        import SwiftUI
        struct HomeView: View {
            var body: some View {
                Text("Welcome")
                Text("home.title")
                Button("Save") {}
                Text(String(localized: "Sign out"))
                Text(String(localized: "a.missing.key"))
                Text(String(localized: "a.defaulted.key", defaultValue: "Defaulted"))
                Text(verbatim: "Raw")
                Text(name)
            }
        }
        """)
        let byText = Dictionary(sites.map { ($0.displayText, $0) }, uniquingKeysWith: { first, _ in first })
        #expect(byText["Welcome"]?.kind == .localizedText)
        #expect(byText["Welcome"]?.context == .swiftUIText)
        #expect(byText["home.title"]?.kind == .localizedKey)
        #expect(byText["Save"]?.kind == .localizedText)
        #expect(byText["Save"]?.role == "button")
        #expect(byText["Sign out"]?.context == .stringLocalizedCall)
        #expect(byText["a.missing.key"]?.kind == .localizedKey)
        #expect(byText["a.defaulted.key"]?.hasDefaultValue == true)
        #expect(byText["Raw"] == nil)
        #expect(byText["Defaulted"] == nil, "defaultValue: is part of the localized call")
        #expect(byText["Welcome"]?.enclosingType == "HomeView")
    }

    @Test func uiKitAndNamedValues() {
        let sites = scan("""
        import UIKit
        final class ProfileViewController: UIViewController {
            let headerTitle = "Profile"
            var subtitle: String { "Your account" }
            let reuseIdentifier = "cell"
            override func viewDidLoad() {
                label.text = "Hello \\(user.name)"
                label.text = isOn ? "On" : "Off"
                label.text = nickname ?? "Anonymous"
                navigationItem.title = "Edit profile"
                button.setTitle("Done", for: .normal)
                showError(title: "Oops", message: "Something went wrong")
                let alert = UIAlertController(title: "Delete?", message: nil, preferredStyle: .alert)
                print("Loaded profile")
                logger.error("Failed to load")
                let url = URL(string: "https://example.com/path")
                UserDefaults.standard.set(true, forKey: "seenProfile")
            }
        }
        """)
        let texts = Set(sites.map(\.displayText))
        #expect(texts.isSuperset(of: ["Profile", "Your account", "Hello \\(user.name)", "On", "Off", "Anonymous", "Edit profile", "Done", "Oops", "Something went wrong", "Delete?"]))
        #expect(!texts.contains("cell"))
        #expect(!texts.contains("Loaded profile"))
        #expect(!texts.contains("Failed to load"))
        #expect(!texts.contains("https://example.com/path"))
        #expect(!texts.contains("seenProfile"))
        #expect(sites.allSatisfy { $0.kind == .unlocalized })
        let interpolated = sites.first { $0.hasInterpolation }
        #expect(interpolated?.segments == [.text("Hello "), .expression("user.name")])
    }

    @Test func concatenationIsReportedOnce() {
        let sites = scan("""
        import UIKit
        func update() { label.text = "Hello " + name + ", welcome" }
        """)
        #expect(sites.count == 1)
        #expect(sites[0].kind == .concatenation)
        #expect(sites[0].segments == [.text("Hello "), .expression("name"), .text(", welcome")])
        #expect(sites[0].originalCode == #""Hello " + name + ", welcome""#)
    }

    @Test func skipsPreviewsDebugTestsAndAttributes() {
        let source = """
        import SwiftUI
        struct V: View {
            var body: some View { Text("Shown") }
            #if DEBUG
            func debug() { label.text = "Debug only" }
            #else
            func release() { label.text = "Release text" }
            #endif
            @available(*, deprecated, message: "Use something else")
            func old() {}
        }
        #Preview { Text("Preview text") }
        struct V_Previews: PreviewProvider { static var previews: some View { Text("Old preview") } }
        """
        let texts = Set(scan(source).map(\.displayText))
        #expect(texts == ["Shown", "Release text"])
        #expect(scan(source, path: "AppTests/ViewTests.swift").isEmpty)
        #expect(scan("import XCTest\nfunc t() { label.text = \"x y\" }").isEmpty)
    }

    @Test func ignoresStringsWithoutWords() {
        let texts = scan("""
        import SwiftUI
        struct V: View { var body: some View { VStack { Text("•"); Text("\\(count)"); Text("—"); Text("A") } } }
        """).map(\.displayText)
        #expect(texts.isEmpty)
    }

    @Test func customUserFacingAPIs() {
        let scanner = SwiftScanner(userFacing: UserFacingAPIs(functions: [.init(name: "PrimaryButton", labels: ["_"])], properties: ["headlineCopy"]))
        let sites = scanner.scan(source: """
        func f() {
            PrimaryButton("Continue now") {}
            model.headlineCopy = "Big news"
        }
        """, path: "A.swift")
        #expect(Set(sites.map(\.displayText)) == ["Continue now", "Big news"])
    }

    @Test func multilineAndRawLiteralsAreReportedButNotFixable() {
        let sites = scan("""
        func f() {
            label.text = \"\"\"
            Long text
            here
            \"\"\"
            label.text = #"Raw "quoted" text"#
        }
        """)
        #expect(sites.count == 2)
        #expect(sites.allSatisfy { !$0.fixable })
        #expect(sites[1].staticText == #"Raw "quoted" text"#)
    }
}
