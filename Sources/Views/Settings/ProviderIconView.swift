import SwiftUI

/// Renders a provider icon from either the asset catalog or SF Symbols.
struct ProviderIconView: View {
    let name: String
    let isAsset: Bool
    var size: CGFloat = 18

    init(providerType: AIProviderType, modelID: String? = nil, size: CGFloat = 18) {
        let resolved = providerType.resolvedIconName(modelID: modelID)
        self.name = resolved.name
        self.isAsset = resolved.isAsset
        self.size = size
    }

    var body: some View {
        if isAsset {
            Image(name, bundle: .module)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        } else {
            Image(systemName: name)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size, height: size)
        }
    }
}
