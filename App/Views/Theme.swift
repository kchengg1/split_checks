import SwiftUI
import UIKit
import SettledCore

/// The app's visual system: one accent, two balance colors, rounded
/// numerals, and a handful of reusable pieces so every screen reads the
/// same way.
enum Theme {
    /// Warm teal — money, but friendly.
    static let accent = Color(red: 0.10, green: 0.60, blue: 0.56)
    static let positive = Color(red: 0.16, green: 0.62, blue: 0.38)
    static let negative = Color(red: 0.86, green: 0.33, blue: 0.30)
    static let corner: CGFloat = 16

    static var cardBackground: Color { Color(uiColor: .secondarySystemGroupedBackground) }
    static var groupedBackground: Color { Color(uiColor: .systemGroupedBackground) }

    static func balanceColor(_ cents: Int) -> Color {
        if cents == 0 { return .secondary }
        return cents > 0 ? positive : negative
    }

    static var gradient: LinearGradient {
        LinearGradient(colors: [accent, accent.opacity(0.72)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}

extension Font {
    static let heroAmount = Font.system(.largeTitle, design: .rounded, weight: .bold)
    static let bigAmount = Font.system(.title2, design: .rounded, weight: .bold)
    static let amount = Font.system(.body, design: .rounded, weight: .semibold)
    static let cardTitle = Font.system(.headline, design: .rounded, weight: .semibold)
}

/// Gradient circle with initials.
struct Avatar: View {
    let person: Person
    var size: CGFloat = 36

    private var initials: String {
        let parts = person.name.split(separator: " ").prefix(2)
        let text = parts.map { String($0.prefix(1)).uppercased() }.joined()
        return text.isEmpty ? "?" : text
    }

    var body: some View {
        let color = ChipPalette.color(for: person)
        Text(initials)
            .font(.system(size: size * 0.4, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(colors: [color.opacity(0.8), color], startPoint: .topLeading, endPoint: .bottomTrailing),
                in: Circle()
            )
            .accessibilityHidden(true)
    }
}

/// Overlapping avatars for a group's members.
struct AvatarStack: View {
    let people: [Person]
    var size: CGFloat = 28
    var max: Int = 4

    var body: some View {
        HStack(spacing: -size * 0.35) {
            ForEach(people.prefix(max)) { person in
                Avatar(person: person, size: size)
                    .overlay(Circle().strokeBorder(Theme.cardBackground, lineWidth: 2))
            }
            if people.count > max {
                Text("+\(people.count - max)")
                    .font(.system(size: size * 0.38, weight: .bold, design: .rounded))
                    .foregroundStyle(.secondary)
                    .frame(width: size, height: size)
                    .background(Color(uiColor: .systemGray5), in: Circle())
                    .overlay(Circle().strokeBorder(Theme.cardBackground, lineWidth: 2))
            }
        }
        .accessibilityLabel(Text(people.map(\.name).joined(separator: ", ")))
    }
}

/// A rounded card on the grouped background. Use inside a `List` with
/// `.cardRow()` or on its own.
struct Card<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) { content }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.cardBackground, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
    }
}

/// The accent-gradient card used for the one number that matters on a screen.
struct HeroCard<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .foregroundStyle(.white)
            .background(Theme.gradient, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}

/// Small capsule status, e.g. "you owe $12.00".
struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color.opacity(0.14), in: Capsule())
    }
}

/// Tinted rounded square with a group's kind icon.
struct KindBadge: View {
    let kind: GroupKind
    var size: CGFloat = 42

    var body: some View {
        Image(systemName: kind.systemImage)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .frame(width: size, height: size)
            .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.3, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Symbol in a tinted circle, for rows.
struct IconBadge: View {
    let systemImage: String
    let color: Color
    var size: CGFloat = 34

    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(color)
            .frame(width: size, height: size)
            .background(color.opacity(0.14), in: Circle())
            .accessibilityHidden(true)
    }
}

/// Month over day, the way a ledger shows a date.
struct DateBadge: View {
    let date: Date

    var body: some View {
        VStack(spacing: 0) {
            Text(date.formatted(.dateTime.month(.abbreviated)))
                .font(.caption2.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
            Text(date.formatted(.dateTime.day()))
                .font(.system(.title3, design: .rounded, weight: .bold))
        }
        .frame(width: 40)
        .accessibilityLabel(Text(date.formatted(date: .abbreviated, time: .omitted)))
    }
}

/// A thin bar sized to a balance relative to the largest one on screen.
struct BalanceBar: View {
    let cents: Int
    let maxCents: Int

    var body: some View {
        GeometryReader { geo in
            let fraction = maxCents > 0 ? CGFloat(abs(cents)) / CGFloat(maxCents) : 0
            Capsule()
                .fill(Theme.balanceColor(cents).opacity(0.85))
                .frame(width: cents == 0 ? 0 : Swift.max(6, geo.size.width * fraction), height: 6)
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }
}

extension View {
    /// Lets a card sit in a `List` as its own row, without the cell chrome.
    func cardRow() -> some View {
        self
            .listRowInsets(EdgeInsets(top: 4, leading: 16, bottom: 4, trailing: 16))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }
}
