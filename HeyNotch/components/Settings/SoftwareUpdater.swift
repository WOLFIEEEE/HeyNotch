//
//  SoftwareUpdater.swift
//  HeyNotch
//
//  Created by Richard Kunkli on 09/08/2024.
//

import SwiftUI
import Sparkle

final class CheckForUpdatesViewModel: ObservableObject {
    @Published var canCheckForUpdates = false

    init(updater: SPUUpdater) {
        updater.publisher(for: \.canCheckForUpdates)
            .map { AppUpdatePolicy.current.allowsUpdates && $0 }
            .assign(to: &$canCheckForUpdates)
    }
}

struct CheckForUpdatesView: View {
    @ObservedObject private var checkForUpdatesViewModel: CheckForUpdatesViewModel
    private let updater: SPUUpdater
    
    init(updater: SPUUpdater) {
        self.updater = updater
        
        // Create our view model for our CheckForUpdatesView
        self.checkForUpdatesViewModel = CheckForUpdatesViewModel(updater: updater)
    }
    
    var body: some View {
        Button("Check for Updates…") {
            guard AppUpdatePolicy.current.allowsUpdates else { return }
            updater.checkForUpdates()
        }
        .disabled(!checkForUpdatesViewModel.canCheckForUpdates)
        .help(AppUpdatePolicy.current.allowsUpdates
              ? "Check for a new version of HeyNotch."
              : "Automatic updates are not enabled for this preview. Download new versions from HeyNotch releases.")
    }
}

struct UpdaterSettingsView: View {
    private let updater: SPUUpdater
    
    @State private var automaticallyChecksForUpdates: Bool
    @State private var automaticallyDownloadsUpdates: Bool
    
    init(updater: SPUUpdater) {
        self.updater = updater
        self.automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        self.automaticallyDownloadsUpdates = updater.automaticallyDownloadsUpdates
    }
    
    var body: some View {
        Section {
            if AppUpdatePolicy.current.allowsUpdates {
                Toggle("Automatically check for updates", isOn: $automaticallyChecksForUpdates)
                    .onChange(of: automaticallyChecksForUpdates) { _, newValue in
                        updater.automaticallyChecksForUpdates = newValue
                    }

                Toggle("Automatically download updates", isOn: $automaticallyDownloadsUpdates)
                    .disabled(!automaticallyChecksForUpdates)
                    .onChange(of: automaticallyDownloadsUpdates) { _, newValue in
                        updater.automaticallyDownloadsUpdates = newValue
                    }
            } else {
                Text("Automatic updates are not enabled for this preview. Download new versions from HeyNotch releases.")
                    .foregroundStyle(.secondary)
                Link("Download updates", destination: URL(string: "https://github.com/WOLFIEEEE/HeyNotch/releases")!)
            }
        } header: {
            HStack {
                Text("Software updates")
            }
        }
    }
}
