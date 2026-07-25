# Apple Human Interface Guidelines Reference

Complete HIG guidelines for Liquid Glass design.

## Table of Contents
- [Core Principles](#core-principles)
- [Typography](#typography)
- [Spacing System](#spacing-system)
- [SF Symbols](#sf-symbols)
- [Hit Targets](#hit-targets)
- [Accessibility](#accessibility)
- [Resources](#resources)

---

## Core Principles

Apple HIG establishes four pillars:

### Clarity
- Interfaces must be legible, precise, easy to understand
- Every element has a purpose
- Users know what to do without instructions

### Deference
- UI helps users focus on content
- Minimize visual clutter
- Controls don't distract from content

### Depth
- Visual layers convey hierarchy
- Shadows, blur, translucency show relationships
- Spatial metaphors aid understanding

### Consistency
- Standard UI elements feel familiar
- System components adapt to Dark Mode, Dynamic Type
- Leverage proven interaction patterns

---

## Typography

San Francisco is the system font optimized for Apple platforms.

### Font Hierarchy

| Style | Usage | SwiftUI |
|-------|-------|---------|
| Large Title | Page titles | `.font(.largeTitle).fontWeight(.bold)` |
| Headline | Section headers | `.font(.headline).fontWeight(.semibold)` |
| Subheadline | Row/card titles | `.font(.subheadline).fontWeight(.medium)` |
| Body | Content (17pt) | `.font(.body)` |
| Callout | Secondary content | `.font(.callout)` |
| Caption | Metadata | `.font(.caption)` |
| Caption 2 | Timestamps | `.font(.caption2)` |

### Stats/Numbers

```swift
.font(.system(size: 28, weight: .bold, design: .rounded))
.font(.system(size: 48, weight: .bold, design: .rounded))
```

### Rules

- **Minimum size:** 11pt (except legal disclaimers)
- **Default body:** 17pt
- **Avoid:** Ultralight, Thin, Light weights
- **Always:** Use system fonts for Dynamic Type support
- **Contrast:** Use `.primary`, `.secondary`, `.tertiary`

---

## Spacing System

Apple uses an 8-point grid for consistent layouts.

### Standard Values

| Points | Usage |
|--------|-------|
| 4 | Fine adjustments (icons, small text) |
| 8 | Minimum standard spacing |
| 12 | Tight spacing |
| 16 | Standard spacing (most common) |
| 20 | Comfortable spacing |
| 24 | Section spacing, card padding |
| 32 | Large section gaps |
| 40 | Major section separation |
| 48 | Page-level separation |

### Padding Patterns

```swift
// Cards
.padding(24)
.padding(20)

// Rows
.padding(16)
.padding(.horizontal, 16)
.padding(.vertical, 12)

// Badges/buttons
.padding(.horizontal, 12)
.padding(.vertical, 8)

// Tight elements
.padding(8)
```

### Internal ≤ External Rule

External spacing (margins) should equal or exceed internal spacing (padding):

```swift
// CORRECT
VStack(spacing: 24) {  // External: 24pt
    CardView().padding(20)  // Internal: 20pt
}

// WRONG
VStack(spacing: 12) {  // External: 12pt
    CardView().padding(24)  // Internal: 24pt - cramped
}
```

### Line Height

Line heights should be multiples of 8 for grid alignment:

```swift
Text("Content")
    .font(.system(size: 15))
    .lineSpacing(9)  // 15 + 9 = 24pt (multiple of 8)
```

---

## SF Symbols

6,900+ icons that integrate with San Francisco font.

### Rendering Modes

| Mode | Description | Use Case |
|------|-------------|----------|
| Monochrome | Single color, all layers | Default |
| Hierarchical | Single color with opacity depth | **Recommended** |
| Palette | Up to 3 explicit colors | Branded icons |
| Multicolor | Apple-defined colors | Realistic icons |

```swift
// Hierarchical (preferred)
Image(systemName: icon)
    .symbolRenderingMode(.hierarchical)
    .foregroundStyle(color)

// Palette
Image(systemName: "person.3.sequence.fill")
    .symbolRenderingMode(.palette)
    .foregroundStyle(.red, .green, .blue)

// Multicolor
Image(systemName: "externaldrive.badge.plus")
    .symbolRenderingMode(.multicolor)
```

### Variants

```swift
Image(systemName: "heart.fill")    // Fill - selection states
Image(systemName: "mic.slash")     // Slash - unavailable
Image(systemName: "plus.circle.fill")  // Circle - buttons

// Programmatic
Image(systemName: "bell")
    .symbolVariant(.fill)
    .symbolVariant(.slash)
```

### Best Practices

- Match symbol weight to nearby text weight
- Use symbols (not images) on glass backgrounds
- Don't mix rendering modes in same view
- Check SF Symbols app for mode support

---

## Hit Targets

### Minimum Size

**44pt × 44pt** is the absolute minimum for all interactive elements.

```swift
// Icon button with proper target
Button { } label: {
    Image(systemName: "gear")
        .font(.system(size: 16))
}
.frame(minWidth: 44, minHeight: 44)

// Small visual, large target
Image(systemName: "info.circle")
    .font(.caption)
    .frame(width: 44, height: 44)
    .contentShape(Rectangle())  // Expand hit area
```

### Interactive Feedback

```swift
// Hover (macOS)
.onHover { isHovering in
    withAnimation(.easeInOut(duration: 0.15)) {
        self.isHovering = isHovering
    }
}

// Press scale
.scaleEffect(isPressed ? 0.95 : 1.0)

// Glass interactive (iOS 26+)
.glassEffect(.regular.interactive())
```

---

## Accessibility

### Automatic Adaptations

| Setting | Effect |
|---------|--------|
| Reduce Transparency | Opaquer glass |
| Increase Contrast | Visible borders |
| Reduce Motion | No elastic effects |
| Dynamic Type | Text scales |
| VoiceOver | System announces |

### Required Practices

1. **44pt minimum** hit targets
2. **11pt minimum** text size
3. **Sufficient contrast** - use semantic colors
4. **Don't rely on color alone** - combine with icons/text
5. **Support Dynamic Type** - use system font styles

### Manual Control

```swift
@Environment(\.accessibilityReduceTransparency) var reduceTransparency
@Environment(\.accessibilityReduceMotion) var reduceMotion

var body: some View {
    Content()
        .glassEffect(reduceTransparency ? .identity : .regular)
        .animation(reduceMotion ? nil : .spring(), value: state)
}
```

### Testing Checklist

- [ ] VoiceOver enabled
- [ ] Dynamic Type at largest size
- [ ] Reduce Transparency on
- [ ] Increase Contrast on
- [ ] Reduce Motion on
- [ ] Light and Dark modes
- [ ] 44pt touch targets verified
- [ ] Text never below 11pt

---

## Resources

### Apple Official

- [Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines)
- [Design Tips](https://developer.apple.com/design/tips/)
- [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos)
- [Materials](https://developer.apple.com/design/human-interface-guidelines/materials)
- [Typography](https://developer.apple.com/design/human-interface-guidelines/typography)
- [SF Symbols](https://developer.apple.com/design/human-interface-guidelines/sf-symbols)
- [Design Resources](https://developer.apple.com/design/resources/)

### WWDC Sessions

- [WWDC 2025: Meet Liquid Glass](https://developer.apple.com/videos/play/wwdc2025/219/)
- [WWDC 2025: Build a SwiftUI app with the new design](https://developer.apple.com/videos/play/wwdc2025/323/)
- [WWDC 2025: Get to know the new design system](https://developer.apple.com/videos/play/wwdc2025/356/)
- [WWDC 2021: SF Symbols in SwiftUI](https://developer.apple.com/videos/play/wwdc2021/10349/)

### Tools

- [SF Symbols App](https://developer.apple.com/sf-symbols/)
- [Liquid Glass GitHub Reference](https://github.com/conorluddy/LiquidGlassReference)

### Semantic Colors

```swift
Color.blue    // Primary actions, links, selection
Color.green   // Success, active, confirmed
Color.orange  // Warning, loading, attention
Color.red     // Destructive, error
Color.purple  // Premium, AI features
Color.cyan    // Security, privacy
Color.yellow  // Highlights, caution
```
