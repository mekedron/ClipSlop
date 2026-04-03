import SwiftUI

struct OnboardingLanguageView: View {
    private let loc = Loc.shared

    var body: some View {
        VStack(spacing: 20) {
            Spacer()

            Image(systemName: "globe")
                .font(.system(size: 48))
                .foregroundStyle(.blue)

            Text(loc.t("onboarding.language.title"))
                .font(.title.bold())

            Text(loc.t("onboarding.language.subtitle"))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ForEach(AppLanguage.allCases) { lang in
                    LanguageCard(language: lang, isSelected: loc.language == lang) {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            loc.language = lang
                        }
                    }
                }
            }
            .frame(maxWidth: 480)

            Spacer()
        }
        .padding(32)
    }
}

private struct LanguageCard: View {
    let language: AppLanguage
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Text(language.flag)
                    .font(.title2)

                Text(language.nativeName)
                    .font(.subheadline.weight(.medium))

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color.clear)
            .background(.background.opacity(0.6))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.3))
            )
        }
        .buttonStyle(.plain)
    }
}
