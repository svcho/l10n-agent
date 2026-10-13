import Foundation

/// Known APIs and the argument labels that carry user-facing text.
enum APITables {
    struct Entry {
        let labels: Set<String>
        let role: String
    }

    /// SwiftUI APIs whose text parameter is a `LocalizedStringKey` when given a literal.
    static let swiftUIKeyAPIs: [String: Entry] = [
        "Text": Entry(labels: ["_"], role: "text"),
        "Button": Entry(labels: ["_"], role: "button"),
        "Label": Entry(labels: ["_"], role: "label"),
        "Toggle": Entry(labels: ["_"], role: "toggle"),
        "Picker": Entry(labels: ["_"], role: "picker"),
        "Link": Entry(labels: ["_"], role: "link"),
        "NavigationLink": Entry(labels: ["_"], role: "link"),
        "TextField": Entry(labels: ["_"], role: "placeholder"),
        "SecureField": Entry(labels: ["_"], role: "placeholder"),
        "Menu": Entry(labels: ["_"], role: "menu"),
        "Stepper": Entry(labels: ["_"], role: "label"),
        "DatePicker": Entry(labels: ["_"], role: "label"),
        "ColorPicker": Entry(labels: ["_"], role: "label"),
        "ProgressView": Entry(labels: ["_"], role: "label"),
        "GroupBox": Entry(labels: ["_"], role: "title"),
        "DisclosureGroup": Entry(labels: ["_"], role: "title"),
        "LabeledContent": Entry(labels: ["_"], role: "label"),
        "Section": Entry(labels: ["_"], role: "header"),
        "ContentUnavailableView": Entry(labels: ["_"], role: "title"),
        "Tab": Entry(labels: ["_"], role: "tab"),
        "navigationTitle": Entry(labels: ["_"], role: "title"),
        "navigationSubtitle": Entry(labels: ["_"], role: "subtitle"),
        "help": Entry(labels: ["_"], role: "help"),
        "accessibilityLabel": Entry(labels: ["_"], role: "a11yLabel"),
        "accessibilityHint": Entry(labels: ["_"], role: "a11yHint"),
        "accessibilityValue": Entry(labels: ["_"], role: "a11yValue"),
        "alert": Entry(labels: ["_"], role: "alertTitle"),
        "confirmationDialog": Entry(labels: ["_"], role: "dialogTitle"),
        "badge": Entry(labels: ["_"], role: "badge"),
        "searchable": Entry(labels: ["prompt"], role: "searchPrompt"),
    ]

    /// UIKit / AppKit / other APIs that take plain `String` text.
    static let stringAPIs: [String: Entry] = [
        "UIAlertController": Entry(labels: ["title", "message"], role: "alert"),
        "UIAlertAction": Entry(labels: ["title"], role: "button"),
        "UIBarButtonItem": Entry(labels: ["title"], role: "button"),
        "UIAction": Entry(labels: ["title", "subtitle", "discoverabilityTitle"], role: "action"),
        "UIMenu": Entry(labels: ["title"], role: "menu"),
        "UIContextualAction": Entry(labels: ["title"], role: "action"),
        "UIApplicationShortcutItem": Entry(labels: ["localizedTitle", "localizedSubtitle"], role: "shortcut"),
        "UNNotificationAction": Entry(labels: ["title"], role: "action"),
        "UNTextInputNotificationAction": Entry(labels: ["title", "textInputButtonTitle", "textInputPlaceholder"], role: "action"),
        "setTitle": Entry(labels: ["_"], role: "button"),
        "addButton": Entry(labels: ["withTitle"], role: "button"),
        "NSAttributedString": Entry(labels: ["string"], role: "text"),
        "NSMutableAttributedString": Entry(labels: ["string"], role: "text"),
        "AttributedString": Entry(labels: ["_"], role: "text"),
        "NSMenuItem": Entry(labels: ["title"], role: "menu"),
        "NSButton": Entry(labels: ["title", "checkboxWithTitle", "radioButtonWithTitle"], role: "button"),
        "NSTextField": Entry(labels: ["labelWithString", "wrappingLabelWithString", "string"], role: "label"),
    ]

    /// Property names whose assigned string value is user-facing.
    static let userFacingProperties: Set<String> = [
        "text", "title", "subtitle", "placeholder", "prompt", "message", "messageText", "informativeText",
        "accessibilityLabel", "accessibilityHint", "accessibilityValue", "toolTip", "stringValue",
        "headerText", "footerText", "secondaryText", "localizedTitle", "localizedSubtitle",
        "attributedTitle", "body", "headline", "caption", "label",
    ]

    /// Last camel-case word of a variable/parameter name that marks user-facing text.
    static let userFacingNameWords: Set<String> = [
        "title", "subtitle", "message", "label", "text", "caption", "placeholder", "prompt", "hint",
        "headline", "heading",
    ]

    /// Argument labels of unknown functions that carry user-facing text.
    static let userFacingLabels: Set<String> = [
        "title", "subtitle", "message", "label", "text", "caption", "placeholder", "prompt", "hint",
        "headline", "buttonTitle", "errorMessage", "header", "footer",
    ]

    /// Calls whose arguments are never user-facing.
    static let ignoredCallees: Set<String> = [
        "print", "debugPrint", "NSLog", "os_log", "assert", "assertionFailure", "precondition",
        "preconditionFailure", "fatalError", "dump", "Image", "UIImage", "NSImage", "Color", "UIColor",
        "NSColor", "URL", "URLRequest", "NSPredicate", "Notification", "NSNotification", "Selector",
        "accessibilityIdentifier", "UserDefaults", "Bundle", "NSRegularExpression", "Regex", "Logger",
        "fileImporter", "font", "debug", "trace", "notice", "fault", "critical",
    ]

    static func lastCamelWord(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        var lastWordStart = trimmed.startIndex
        for index in trimmed.indices where trimmed[index].isUppercase {
            lastWordStart = index
        }
        return trimmed[lastWordStart...].lowercased()
    }

    static func isUserFacingName(_ name: String) -> Bool {
        userFacingNameWords.contains(lastCamelWord(name))
    }
}
