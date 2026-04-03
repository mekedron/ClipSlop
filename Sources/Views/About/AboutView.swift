import SwiftUI

struct AboutView: View {
    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            // App icon
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

            // Links
            VStack(spacing: 12) {
                Link(destination: URL(string: "https://github.com/mekedron/ClipSlop")!) {
                    HStack(spacing: 8) {
                        Image(systemName: "chevron.left.forwardslash.chevron.right")
                            .frame(width: 20)
                        Text("GitHub Repository")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)

                Link(destination: URL(string: "https://buymeacoffee.com/mekedron")!) {
                    HStack(spacing: 8) {
                        Image(systemName: "cup.and.saucer")
                            .frame(width: 20)
                        Text("Buy Me a Coffee")
                        Spacer()
                        Image(systemName: "arrow.up.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
                .buttonStyle(.plain)
            }
            .frame(width: 260)

            Spacer()
        }
        .padding(32)
        .frame(width: 360, height: 440)
    }
}
