import SwiftUI

struct AboutView: View {
    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return String(localized: "Version \(v) (\(b))")
    }

    private var appIcon: NSImage {
        NSRunningApplication.current.icon ?? NSApp.applicationIconImage
    }

    private let productName = "Niacin"
    private let tagline = "Keep your computer awake — driven by you or your AI agents."

    var body: some View {
        VStack(spacing: 20) {
            Image(nsImage: appIcon)
                .resizable()
                .frame(width: 80, height: 80)

            VStack(spacing: 4) {
                Text(productName)
                    .font(.title2)
                    .fontWeight(.semibold)
                Text(version)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Text(tagline)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Divider()

            VStack(spacing: 8) {
                HStack(spacing: 16) {
                    Link("Website", destination: URL(string: "https://niacin.dort.zone/")!)
                    Link("GitHub", destination: URL(string: "https://github.com/just-an-oldsalt/niacin")!)
                }
                .font(.callout)
            }

            Text("MIT License")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(28)
        .frame(width: 340)
    }
}
