import SwiftUI

/// §15.1 model routing: role → provider, cost floor, timeout, inline
/// spend, and validation results. Shown in Settings → Providers when no
/// provider is selected — the tab's overview state. Fallback *chains* are
/// hand-edited in roles.yaml (documented there); this surface covers the
/// common bindings.
struct RoutingSettingsView: View {
    let appState: AppState

    @State private var spendTotals: [String: SpendLedger.RoleTotals] = [:]

    private let loc = Loc.shared
    private var providerStore: ProviderStore { appState.providerStore }
    private var roleStore: EngineRoleStore { appState.magicCoordinator.roleStore }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(loc.t("settings.routing.title"))
                    .font(.headline)

                ForEach(EngineRole.allCases, id: \.rawValue) { role in
                    roleRow(role)
                }

                let warnings = providerStore.loadWarnings + roleStore.loadWarnings
                if !warnings.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(loc.t("settings.routing.warnings"), systemImage: "exclamationmark.triangle")
                            .font(.subheadline).fontWeight(.medium)
                            .foregroundStyle(.orange)
                        ForEach(warnings, id: \.self) { warning in
                            Text(warning)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(10)
                    .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }

                Text(loc.t("settings.routing.fallbacks_hint"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear {
            providerStore.reloadIfChanged()
            roleStore.reloadIfChanged()
            reloadSpend()
        }
    }

    // MARK: - Rows

    @ViewBuilder
    private func roleRow(_ role: EngineRole) -> some View {
        let binding = roleStore.binding(for: role)
        VStack(alignment: .leading, spacing: 6) {
            Text(loc.t("settings.routing.role.\(role.rawValue)"))
                .font(.subheadline).fontWeight(.medium)

            HStack(spacing: 12) {
                Picker("", selection: providerSelection(role)) {
                    Text(loc.t("settings.routing.provider_default")).tag(UUID?.none)
                    ForEach(candidateProviders(for: role)) { provider in
                        Text(provider.name).tag(Optional(provider.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 220)

                Picker(loc.t("settings.routing.min_cost"), selection: minCostSelection(role)) {
                    Text(loc.t("settings.routing.off")).tag(ProviderCostClass?.none)
                    ForEach(ProviderCostClass.allCases, id: \.rawValue) { costClass in
                        Text(costClass.rawValue).tag(Optional(costClass))
                    }
                }
                .fixedSize()

                Picker(loc.t("settings.routing.timeout"), selection: timeoutSelection(role)) {
                    Text(loc.t("settings.routing.off")).tag(Int?.none)
                    ForEach([15, 30, 60, 120, 300], id: \.self) { seconds in
                        Text("\(seconds)").tag(Optional(seconds))
                    }
                }
                .fixedSize()
            }

            statusLine(role, binding: binding)
            spendLine(role)
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func statusLine(_ role: EngineRole, binding: RoleBinding) -> some View {
        switch roleStore.resolution(for: role, in: providerStore) {
        case .resolved(let provider):
            let missingKey = provider.providerType.requiresAPIKey
                && KeychainService.load(key: provider.apiKeyRef)?.isEmpty != false
            if missingKey {
                Label(loc.t("settings.routing.missing_key", provider.name), systemImage: "key.slash")
                    .font(.caption).foregroundStyle(.orange)
            } else if binding.provider != nil && binding.provider != provider.id {
                Label(loc.t("settings.routing.falls_back", provider.name), systemImage: "arrow.uturn.down")
                    .font(.caption).foregroundStyle(.orange)
            } else {
                Label("\(provider.name) · \(provider.modelID)", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .refusedBelowMinCost(let min):
            Label(loc.t("settings.routing.refused_cost", min.rawValue), systemImage: "xmark.octagon")
                .font(.caption).foregroundStyle(.red)
        case .noneAvailable:
            Label(loc.t("settings.routing.no_provider"), systemImage: "xmark.octagon")
                .font(.caption).foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private func spendLine(_ role: EngineRole) -> some View {
        if let totals = spendTotals[role.rawValue] {
            let estimate = totals.anyEstimated ? "≈" : ""
            Text(loc.t(
                "settings.routing.spend",
                "\(estimate)\(compact(totals.todayInput + totals.todayOutput))",
                "\(estimate)\(compact(totals.monthInput + totals.monthOutput))"
            ))
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Bindings

    private func candidateProviders(for role: EngineRole) -> [AIProviderConfig] {
        role.requiresToolCalling
            ? providerStore.providers.filter { $0.providerType.supportsToolCalling }
            : providerStore.providers
    }

    private func providerSelection(_ role: EngineRole) -> Binding<UUID?> {
        Binding(
            get: { roleStore.mapping[role] },
            set: { roleStore.setProvider($0, for: role) }
        )
    }

    private func minCostSelection(_ role: EngineRole) -> Binding<ProviderCostClass?> {
        Binding(
            get: { roleStore.binding(for: role).minCostClass },
            set: { newValue in
                var binding = roleStore.binding(for: role)
                binding.minCostClass = newValue
                roleStore.setBinding(binding, for: role)
            }
        )
    }

    private func timeoutSelection(_ role: EngineRole) -> Binding<Int?> {
        Binding(
            get: { roleStore.binding(for: role).timeoutSeconds },
            set: { newValue in
                var binding = roleStore.binding(for: role)
                binding.timeoutSeconds = newValue
                roleStore.setBinding(binding, for: role)
            }
        )
    }

    // MARK: - Helpers

    private func reloadSpend() {
        Task {
            let totals = await Task.detached {
                SpendLedger.totals(records: SpendLedger.load(from: Constants.Engine.logsDirectory))
            }.value
            spendTotals = totals
        }
    }

    private func compact(_ tokens: Int) -> String {
        switch tokens {
        case 0..<1_000: "\(tokens)"
        case 1_000..<1_000_000: String(format: "%.1fk", Double(tokens) / 1_000)
        default: String(format: "%.1fM", Double(tokens) / 1_000_000)
        }
    }
}
