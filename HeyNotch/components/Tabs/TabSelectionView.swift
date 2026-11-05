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
    @ObservedObject var coordinator = HeyViewCoordinator.shared
    @Default(.heyShelf) private var shelfEnabled
    @Namespace var animation
    var body: some View {
        HStack(spacing: 0) {
            ForEach(tabs.filter { $0.view != .shelf || shelfEnabled }) { tab in
                    TabButton(label: tab.label, icon: tab.icon, selected: coordinator.currentView == tab.view) {
                        withAnimation(.smooth) {
                            coordinator.currentView = tab.view
                        }
                    }
                    .frame(height: 26)
                    .foregroundStyle(tab.view == coordinator.currentView ? .white : .gray)
                    .background {
                        if tab.view == coordinator.currentView {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                        } else {
                            Capsule()
                                .fill(coordinator.currentView == tab.view ? Color(nsColor: .secondarySystemFill) : Color.clear)
                                .matchedGeometryEffect(id: "capsule", in: animation)
                                .hidden()
                        }
                    }
            }
        }
        .clipShape(Capsule())
        .onChange(of: shelfEnabled) { _, enabled in
            if !enabled && coordinator.currentView == .shelf { coordinator.currentView = .tasks }
        }
    }
}

#Preview {
    HeyHeader().environmentObject(HeyViewModel())
}
