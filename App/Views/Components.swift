import SwiftUI
import UIKit
import SplitChecksCore

/// Chip colors, indexed by `Person.colorIndex` (wraps around for big parties).
enum ChipPalette {
    static let colors: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .indigo, .red]

    static func color(for person: Person) -> Color {
        colors[person.colorIndex % colors.count]
    }
}

/// A tappable person chip: colored circle with initials plus the name.
struct PersonChip: View {
    let person: Person
    var isSelected: Bool = false

    private var initials: String {
        let parts = person.name.split(separator: " ").prefix(2)
        return parts.map { String($0.prefix(1)).uppercased() }.joined()
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(initials.isEmpty ? "?" : initials)
                .font(.caption.bold())
                .foregroundStyle(.white)
                .frame(width: 28, height: 28)
                .background(ChipPalette.color(for: person), in: Circle())
            Text(person.name)
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(isSelected ? ChipPalette.color(for: person).opacity(0.2) : Color(uiColor: .systemGray6))
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
        HStack(spacing: -8) {
            ForEach(people) { person in
                Text(String(person.name.prefix(1)).uppercased())
                    .font(.caption2.bold())
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(ChipPalette.color(for: person), in: Circle())
                    .overlay(Circle().strokeBorder(Color(uiColor: .systemBackground), lineWidth: 1.5))
            }
        }
        .accessibilityLabel(Text(people.map(\.name).joined(separator: ", ")))
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
            .onAppear { text = cents == 0 ? "" : displayString }
            .onChange(of: text) {
                if let parsed = Money.parse(text) { cents = parsed }
                else if text.isEmpty { cents = 0 }
            }
            .onChange(of: focused) {
                if !focused { text = cents == 0 ? "" : displayString }
            }
    }

    private var displayString: String {
        String(format: "%.2f", Double(cents) / 100)
    }
}
