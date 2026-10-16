enum Tab: CaseIterable {
    case home
    case profile

    var title: String {
        switch self {
        case .home: return "Home"
        case .profile: return "Your profile"
        }
    }

    var systemImage: String {
        switch self {
        case .home: return "house"
        case .profile: return "person"
        }
    }
}
