import Foundation

/// Builds the final system prompt for the ⌘K one-off instruction bar.
enum AdHocPromptComposer {
    static let instructionPlaceholder = "{instruction}"

    /// Substitutes the typed instruction into the configurable template.
    /// If the template contains `{instruction}` the instruction replaces it
    /// (every occurrence); otherwise the instruction is appended at the end
    /// so a user who deleted the placeholder still gets a working prompt.
    static func compose(template: String, instruction: String) -> String {
        let trimmedInstruction = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        if template.contains(instructionPlaceholder) {
            return template.replacingOccurrences(of: instructionPlaceholder, with: trimmedInstruction)
        }
        return template + "\n\nInstruction:\n" + trimmedInstruction
    }

    /// Compact single-line name for the history sidebar tab — the first line
    /// of the instruction, truncated with an ellipsis.
    static func stepName(for instruction: String, maxLength: Int = 40) -> String {
        let firstLine = instruction
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines)[0]
        guard firstLine.count > maxLength else { return firstLine }
        return String(firstLine.prefix(maxLength)) + "…"
    }
}
