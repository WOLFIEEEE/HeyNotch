enum NotchNavigationPolicy {
    enum Presentation: Equatable { case tabs, menu }

    static func presentation(alwaysShowTabs: Bool, shelfEmpty: Bool, page: NotchViews) -> Presentation {
        alwaysShowTabs || !shelfEmpty || page == .tasks ? .tabs : .menu
    }

    static func pages(shelfEnabled: Bool) -> [NotchViews] {
        shelfEnabled ? [.tasks, .home, .shelf] : [.tasks, .home]
    }
}
