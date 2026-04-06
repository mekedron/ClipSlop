import SwiftUI

struct AboutView: View {
    @State private var showLibraries = false
    private let loc = Loc.shared

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 56))
                .foregroundStyle(.blue)

            Text(loc.t("about.title"))
                .font(.largeTitle).fontWeight(.bold)

            Text(loc.t("about.subtitle"))
                .foregroundStyle(.secondary)

            Text(loc.t("about.version", Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"))
                .font(.caption)
                .foregroundStyle(.tertiary)

            Divider()
                .frame(width: 200)

            VStack(spacing: 12) {
                aboutLink(loc.t("about.github"), icon: "chevron.left.forwardslash.chevron.right",
                          url: "https://github.com/mekedron/ClipSlop")

                aboutLink(loc.t("about.coffee"), icon: "cup.and.saucer",
                          url: "https://buymeacoffee.com/mekedron",
                          tint: .orange)

                Button {
                    // Lower the settings window so Sparkle's update dialog appears on top
                    if let settingsWindow = NSApp.windows.first(where: { $0.title == Loc.shared.t("window.settings") }) {
                        settingsWindow.level = .normal
                    }
                    SparkleUpdater.shared?.checkForUpdates()
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .frame(width: 20)
                        Text(loc.t("about.updates"))
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)

                Button {
                    showLibraries = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "books.vertical")
                            .frame(width: 20)
                        Text(loc.t("about.libraries"))
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .frame(width: 260)

            Spacer()
        }
        .padding(32)
        .frame(width: 360, height: 480)
        .sheet(isPresented: $showLibraries) {
            ThirdPartyLibrariesView()
        }
    }

    private func aboutLink(_ title: String, icon: String, url: String, tint: Color? = nil) -> some View {
        Link(destination: URL(string: url)!) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .frame(width: 20)
                Text(title)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                (tint ?? .primary).opacity(tint != nil ? 0.1 : 0).opacity(tint != nil ? 1 : 0),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Third-Party Libraries

struct ThirdPartyLibrariesView: View {
    @Environment(\.dismiss) private var dismiss
    private let loc = Loc.shared

    private let libraries: [(name: String, author: String, description: String, url: String)] = [
        (
            "KeyboardShortcuts",
            "Sindre Sorhus",
            "Customizable global keyboard shortcuts for macOS apps",
            "https://github.com/sindresorhus/KeyboardShortcuts"
        ),
        (
            "LaunchAtLogin",
            "Sindre Sorhus",
            "Add launch at login functionality to sandboxed macOS apps",
            "https://github.com/sindresorhus/LaunchAtLogin-Modern"
        ),
        (
            "Sparkle",
            "Sparkle Project",
            "A software update framework for macOS applications",
            "https://github.com/sparkle-project/Sparkle"
        ),
        (
            "swift-markdown",
            "Apple / Swift Project",
            "Swift Markdown parsing and rendering library",
            "https://github.com/swiftlang/swift-markdown"
        ),
        (
            "Textual",
            "Guillermo Gonzalez",
            "Render Markdown as native SwiftUI views with styling support",
            "https://github.com/gonzalezreal/textual"
        ),
        (
            "swift-rich-html-editor",
            "Infomaniak",
            "WYSIWYG rich HTML editor component for SwiftUI",
            "https://github.com/Infomaniak/swift-rich-html-editor"
        ),
    ]

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text(loc.t("about.libraries"))
                    .font(.headline)
                Spacer()
                Button(loc.t("about.done")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            Text(loc.t("about.libraries.intro"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            ScrollView {
                VStack(spacing: 8) {
                    ForEach(libraries, id: \.name) { lib in
                        Link(destination: URL(string: lib.url)!) {
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(lib.name)
                                        .font(.subheadline).fontWeight(.medium)
                                    Spacer()
                                    Image(systemName: "arrow.up.right")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                Text("by \(lib.author)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(lib.description)
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            Text(loc.t("about.libraries.license"))
                .font(.caption2)
                .foregroundStyle(.quaternary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(width: 380)
        .frame(minHeight: 300, idealHeight: 500)
    }
}
