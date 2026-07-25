import SwiftUI

/// The V0 onboarding interview (§9.3): name, role, and three typical
/// messages — "worth more than a week of extraction". Written into the
/// engine's core/ files when the user leaves the step; skippable by leaving
/// the fields empty.
struct OnboardingMagicInterviewView: View {
    let appState: AppState

    @State private var name = ""
    @State private var role = ""
    @State private var messages = ["", "", ""]

    private let loc = Loc.shared

    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 8)

            Image(systemName: "wand.and.stars")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Text(loc.t("onboarding.magic.interview.title"))
                .font(.title.bold())

            Text(loc.t("onboarding.magic.interview.subtitle"))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 440)

            VStack(spacing: 10) {
                TextField(loc.t("onboarding.magic.interview.name"), text: $name)
                    .textFieldStyle(.roundedBorder)
                TextField(loc.t("onboarding.magic.interview.role"), text: $role)
                    .textFieldStyle(.roundedBorder)
            }
            .frame(maxWidth: 420)

            VStack(alignment: .leading, spacing: 8) {
                Text(loc.t("onboarding.magic.interview.messages_heading"))
                    .font(.headline)
                ForEach(0..<3, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(loc.t("onboarding.magic.interview.message_hint_\(index)"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TextEditor(text: $messages[index])
                            .font(.body)
                            .scrollContentBackground(.hidden)
                            .frame(height: 44)
                            .padding(4)
                            .background(.background)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
                    }
                }
            }
            .frame(maxWidth: 420)

            Text(loc.t("onboarding.magic.interview.skip_hint"))
                .font(.caption)
                .foregroundStyle(.tertiary)

            Spacer(minLength: 8)
        }
        .padding(24)
        .onDisappear {
            appState.magicCoordinator.saveOnboardingProfile(
                name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                role: role.trimmingCharacters(in: .whitespacesAndNewlines),
                sampleMessages: messages
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
            )
        }
    }
}
