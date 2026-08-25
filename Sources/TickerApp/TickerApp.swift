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
                Image(systemName: "stopwatch.fill")
                    .symbolRenderingMode(.monochrome)
                    .foregroundColor(.red)
                    .accessibilityLabel("Ticker could not start")
            } else {
                Image(systemName: "stopwatch")
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
            Image(systemName: "stopwatch")
                .accessibilityLabel("Ticker found no scheduled jobs")
        } else if model.hasUrgentAttentionOwnedJobs {
            Image(systemName: "stopwatch.fill")
                .symbolRenderingMode(.monochrome)
                .foregroundColor(.red)
                .accessibilityLabel("Ticker found a job that needs attention")
        } else {
            Image(systemName: "stopwatch")
                .accessibilityLabel("Your Ticker jobs have no known issues")
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
        .frame(width: TickerPopoverLayout.width, height: 180)
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
        .frame(width: TickerPopoverLayout.width)
    }
}
