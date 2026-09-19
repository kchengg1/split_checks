import SwiftUI
import UIKit
import SettledCore

/// Chip colors, indexed by `Person.colorIndex` (wraps around for big parties).
enum ChipPalette {
    static let colors: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .indigo, .red]

    static func color(for person: Person) -> Color {
        colors[person.colorIndex % colors.count]
    }
}

/// A tappable person chip: gradient avatar plus the name.
struct PersonChip: View {
    let person: Person
    var isSelected: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            Avatar(person: person, size: 28)
            Text(person.name)
                .font(.subheadline.weight(isSelected ? .semibold : .medium))
                .lineLimit(1)
        }
        .padding(.leading, 4)
        .padding(.trailing, 12)
        .padding(.vertical, 4)
        .background(
            Capsule().fill(isSelected ? ChipPalette.color(for: person).opacity(0.18) : Color(uiColor: .systemGray6))
        )
        .overlay(
            Capsule().strokeBorder(isSelected ? ChipPalette.color(for: person) : .clear, lineWidth: 2)
        )
        .accessibilityLabel(Text(person.name))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Tiny stacked avatars showing who's on an item.
struct AssigneeStack: View {
    let people: [Person]

    var body: some View {
        AvatarStack(people: people, size: 22, max: 5)
    }
}

/// A text field that edits an integer-cents binding through `Money` parsing,
/// committing on every keystroke that parses and restoring on focus loss.
struct CurrencyField: View {
    let title: String
    @Binding var cents: Int
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        TextField(title, text: $text)
            .keyboardType(.decimalPad)
            .focused($focused)
            .multilineTextAlignment(.trailing)
            .font(.amount)
            .onAppear { text = cents == 0 ? "" : displayString }
            .onChange(of: text) {
                if let parsed = Money.parse(text) { cents = parsed }
                else if text.isEmpty { cents = 0 }
            }
            .onChange(of: focused) {
                if !focused { text = cents == 0 ? "" : displayString }
            }
            // The decimal pad has no return key, so give it an explicit
            // Done button to dismiss. Guarded by `focused` so only the
            // active field contributes a keyboard toolbar.
            .toolbar {
                if focused {
                    ToolbarItemGroup(placement: .keyboard) {
                        Spacer()
                        Button("Done") { focused = false }
                    }
                }
            }
    }

    private var displayString: String {
        String(format: "%.2f", Double(cents) / 100)
    }
}
