/// All delayed close paths protect the same active interactions. Explicit
/// close actions remain separate so the user can still dismiss the notch.
struct NotchAutoCloseState {
    var isOpen: Bool
    var pointerInside: Bool
    var menuActive: Bool
    var popoverActive: Bool
    var sharingActive: Bool
    var dropTargeted: Bool

    var permitsClose: Bool {
        isOpen && !pointerInside && !menuActive && !popoverActive
            && !sharingActive && !dropTargeted
    }
}
