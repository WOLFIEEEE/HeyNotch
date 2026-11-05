//
//  TabSelectionView.swift
//  HeyNotch
//
//  Created by Hugo Persson on 2024-08-25.
//

import SwiftUI
import Defaults

struct TabModel: Identifiable {
    let id = UUID()
    let label: String
    let icon: String
    let view: NotchViews
}

let tabs = [
    TabModel(label: "Tasks", icon: "rectangle.split.3x1", view: .tasks),
    TabModel(label: "Music", icon: "music.note", view: .home),
    TabModel(label: "Shelf", icon: "tray.fill", view: .shelf)
]

struct TabSelectionView: View {
    var presentation: NotchNavigationPolicy.Presentation = .tabs
    @ObservedObject var coordinator = HeyViewCoordinator.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Default(.heyShelf) private var shelfEnabled
    @Namespace var animation
    private var availableTabs: [TabModel] {
        tabs.filter { NotchNavigationPolicy.pages(shelfEnabled: shelfEnabled).contains($0.view) }
    }
    var body: some View {
        Group {
            if presentation == .menu {
                Menu {
                    Picker("Page", selection: $coordinator.currentView) {
                        ForEach(availableTabs) { tab in
                            Label(tab.label, systemImage: tab.icon).tag(tab.view)
                        }
                    }
                } label: {
                    if let current = availableTabs.first(where: { $0.view == coordinator.currentView }) {
                        Label(current.label, systemImage: current.icon)
                            .font(.system(size: 11, weight: .semibold))
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .frame(height: 26)
                .help("Switch page")
                .accessibilityLabel("Notch page")
                .accessibilityValue(availableTabs.first(where: { $0.view == coordinator.currentView })?.label ?? "")
            } else {
                tabBar
            }
        }
        .onChange(of: shelfEnabled) { _, enabled in
            if !enabled && coordinator.currentView == .shelf { coordinator.currentView = .tasks }
        }
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(availableTabs) { tab in
                    TabButton(label: tab.label, icon: tab.icon, selected: coordinator.currentView == tab.view) {
                        withAnimation(reduceMotion ? nil : .smooth) {
                            coordinator.currentView = tab.view
                        }
                    }
                    .frame(height: 26)
                    .foregroundStyle(tab.view == coordinator.currentView ? .white : .gray)
                    .background {
                        if tab.view == coordinator.currentView {
                            Capsule()
                                .fill(Color(nsColor: .secondarySystemFill))
                                .matchedGeometryEffect(id: "capsule", in: animation)
                        }
                    }
            }
        }
        .clipShape(Capsule())
    }
}

#Preview {
    HeyHeader().environmentObject(HeyViewModel())
}
