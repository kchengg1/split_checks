import Foundation
import UniformTypeIdentifiers
import SettledCore

/// The file type a shared group travels as. Declared in the app's
/// Info.plist too, so AirDropped and Messaged files open the app.
extension UTType {
    /// Looked up rather than `exportedAs:` so a missing declaration can't
    /// trap at launch; the app falls back to plain JSON.
    static let settledGroup = UTType("com.kchengg1.settled.group") ?? .json
}

/// Writing a group out and reading one back in. No server involved: a
/// group is a self-contained document, so sharing it is sharing a file.
enum GroupSharing {

    /// Writes the group to a temporary `.settled` file to hand to the
    /// share sheet.
    static func export(_ group: ExpenseGroup, exportedBy: String?) -> URL? {
        let document = GroupDocument(group: group, exportedBy: exportedBy)
        guard let data = try? document.encoded() else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(document.suggestedFileName)
        do {
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Reads a document from a file the system handed us. Files that arrive
    /// from another app are security-scoped, so access is bracketed.
    static func read(from url: URL) -> GroupDocument? {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? GroupDocument.decode(data)
    }
}
