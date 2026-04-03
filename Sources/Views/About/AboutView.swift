import SwiftUI

struct AboutView: View {
    @State private var showLibraries = false

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "doc.on.clipboard")
                .font(.system(size: 56))
                .foregroundStyle(.blue)

            Text("ClipSlop")
                .font(.largeTitle).fontWeight(.bold)

            Text("AI-powered clipboard processor")
                .foregroundStyle(.secondary)

            Text("Version 0.1.0")
                .font(.caption)
                .foregroundStyle(.tertiary)

            Divider()
                .frame(width: 200)

            VStack(spacing: 12) {
                aboutLink("GitHub Repository", icon: "chevron.left.forwardslash.chevron.right",
                          url: "https://github.com/mekedron/ClipSlop")

                aboutLink("Buy Me a Coffee", icon: "cup.and.saucer",
                          url: "https://buymeacoffee.com/mekedron",
                          tint: .orange)

                Button {
                    showLibraries = true
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "books.vertical")
                            .frame(width: 20)
                        Text("Third-Party Libraries")
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
    ]

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Third-Party Libraries")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }

            Text("ClipSlop uses the following open-source libraries:")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

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

            Spacer()

            Text("All libraries are used under their respective open-source licenses.")
                .font(.caption2)
                .foregroundStyle(.quaternary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(width: 380, height: 320)
    }
}
