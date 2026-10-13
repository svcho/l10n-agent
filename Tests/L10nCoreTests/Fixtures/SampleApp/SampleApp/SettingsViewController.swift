import UIKit

final class SettingsViewController: UIViewController {
    private let titleLabel = UILabel()
    private let button = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Settings"
        titleLabel.text = "Notifications"
        button.setTitle("Log out", for: .normal)
        titleLabel.accessibilityHint = "Shows notification options"
        let identifier = "settings-cell" // not user-facing
        _ = identifier
    }

    func confirmLogout(userName: String) {
        let alert = UIAlertController(title: "Log out?", message: "You will be signed out of \(userName).", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Log out", style: .destructive))
        present(alert, animated: true)
        titleLabel.text = "Logged out" // l10n-agent:ignore
    }

    #if DEBUG
    func debugMenu() {
        titleLabel.text = "Debug menu"
    }
    #endif
}
