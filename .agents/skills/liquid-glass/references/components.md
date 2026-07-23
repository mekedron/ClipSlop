# Component Patterns

Full SwiftUI implementations for Liquid Glass design.

## Table of Contents
- [StatCard](#statcard)
- [SettingsSection](#settingssection)
- [InteractiveRow](#interactiverow)
- [EmptyStateView](#emptystateview)
- [OptionRow](#optionrow)
- [ExpandableToolbar](#expandabletoolbar)

---

## StatCard

Dashboard stat card with icon, value, and label.

```swift
struct StatCard: View {
    let value: String
    let label: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                ZStack {
                    Circle()
                        .fill(color.opacity(0.15))
                        .frame(width: 36, height: 36)
                    Image(systemName: icon)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(color)
                }
                Spacer()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(value)
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// Usage
StatCard(value: "1,234", label: "Total Items", icon: "doc.fill", color: .blue)
```

---

## SettingsSection

Grouped settings section with icon header.

```swift
struct SettingsSection<Content: View>: View {
    let title: String
    let icon: String
    let iconColor: Color
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(iconColor.opacity(0.15))
                        .frame(width: 32, height: 32)
                    Image(systemName: icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(iconColor)
                }
                Text(title)
                    .font(.headline)
            }
            content
        }
        .padding(24)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// Usage
SettingsSection(title: "Privacy", icon: "lock.shield", iconColor: .cyan) {
    Toggle("Enable Feature", isOn: $isEnabled)
    Text("Description").font(.caption).foregroundStyle(.secondary)
}
```

---

## InteractiveRow

Row with hover-revealed actions.

```swift
struct InteractiveRow: View {
    let title: String
    let subtitle: String
    let onCopy: () -> Void
    let onDelete: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(.body)
                    .lineLimit(2)
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if isHovering {
                HStack(spacing: 8) {
                    Button(action: onCopy) {
                        Image(systemName: "doc.on.doc").font(.caption)
                    }
                    .buttonStyle(.bordered)
                    Button(action: onDelete) {
                        Image(systemName: "trash").font(.caption)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
                .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(isHovering ? Color.primary.opacity(0.04) : Color.clear)
        )
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.quaternary.opacity(0.5))
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }
}
```

---

## EmptyStateView

Placeholder for empty content states.

```swift
struct EmptyStateView: View {
    let icon: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle()
                    .fill(.quaternary)
                    .frame(width: 64, height: 64)
                Image(systemName: icon)
                    .font(.title)
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 4) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// Usage
EmptyStateView(
    icon: "doc.text",
    title: "No Documents",
    message: "Create your first document to get started"
)
```

---

## OptionRow

Selectable option with checkmark indicator.

```swift
struct OptionRow: View {
    let title: String
    let subtitle: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.medium)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.blue)
                }
            }
            .padding(14)
            .background(isSelected ? Color.blue.opacity(0.08) : Color.clear)
            .background(.quaternary.opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(isSelected ? Color.blue.opacity(0.3) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}
```

---

## ExpandableToolbar

Morphing toolbar with animated expansion (iOS 26+).

```swift
struct ExpandableToolbar: View {
    @State private var isExpanded = false
    @Namespace private var namespace

    var body: some View {
        GlassEffectContainer(spacing: 20) {
            HStack(spacing: 16) {
                if isExpanded {
                    Button("Camera", systemImage: "camera") { }
                        .glassEffect(.regular.interactive())
                        .glassEffectID("camera", in: namespace)

                    Button("Photos", systemImage: "photo") { }
                        .glassEffect(.regular.interactive())
                        .glassEffectID("photos", in: namespace)
                }

                Button {
                    withAnimation(.bouncy) { isExpanded.toggle() }
                } label: {
                    Image(systemName: isExpanded ? "xmark" : "plus")
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .glassEffectID("toggle", in: namespace)
            }
        }
    }
}
```

---

## Badge Variants

```swift
// Status badge
HStack(spacing: 8) {
    Circle()
        .fill(isActive ? Color.green : Color.orange)
        .frame(width: 8, height: 8)
    Text(isActive ? "Active" : "Loading...")
        .font(.caption)
        .fontWeight(.medium)
}
.padding(.horizontal, 12)
.padding(.vertical, 8)
.background(.regularMaterial, in: Capsule())

// Count badge
Text("\(count)")
    .font(.caption2)
    .fontWeight(.medium)
    .foregroundStyle(.secondary)
    .padding(.horizontal, 6)
    .padding(.vertical, 2)
    .background(.quaternary, in: Capsule())
```
