import AppKit
import SwiftUI

@main
struct TickerMenuBarApp: App {
    @StateObject private var bootstrap = AppBootstrap()

    var body: some Scene {
        MenuBarExtra {
            Group {
                if let model = bootstrap.model {
                    JobListView(model: model)
                } else if let errorMessage = bootstrap.errorMessage {
                    BootstrapErrorView(message: errorMessage)
                } else {
                    BootstrapLoadingView()
                }
            }
        } label: {
            if let model = bootstrap.model {
                MenuBarStatusIcon(model: model)
            } else if bootstrap.errorMessage != nil {
                Image(systemName: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.monochrome)
                    .foregroundColor(.red)
                    .accessibilityLabel("Ticker could not start")
            } else {
                Image(systemName: "clock.badge.questionmark")
                    .accessibilityLabel("Ticker is starting")
            }
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarStatusIcon: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if model.jobs.isEmpty {
            Image(systemName: "clock.badge.questionmark")
                .accessibilityLabel("Ticker found no scheduled jobs")
        } else if model.jobs.contains(where: { model.outcome(for: $0) == .failure }) {
            Image(systemName: "exclamationmark.triangle.fill")
                .symbolRenderingMode(.monochrome)
                .foregroundColor(.red)
                .accessibilityLabel("Ticker found a failed job")
        } else {
            Image(systemName: "clock")
                .accessibilityLabel("Ticker jobs have no known failures")
        }
    }
}

private struct BootstrapLoadingView: View {
    var body: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Opening run history…")
                .foregroundColor(.secondary)
        }
        .frame(width: 360, height: 180)
    }
}

private struct BootstrapErrorView: View {
    let message: String

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Ticker could not start", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundColor(.red)
            Text(message)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Quit") {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding(18)
        .frame(width: 400)
    }
}
