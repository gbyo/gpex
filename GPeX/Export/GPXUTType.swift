import UniformTypeIdentifiers

nonisolated extension UTType {
    /// The GPS Exchange Format.
    ///
    /// *Imported*, not exported: `com.topografix.gpx` is Topografix's identifier for an
    /// open interchange format that GPeX merely writes. Declaring it as an exported
    /// type would claim GPeX invented it, and would be wrong in the one place it
    /// matters — every other app that reads `.gpx` uses this same identifier.
    ///
    /// The matching `UTImportedTypeDeclarations` entry lives in `GPeX-Info.plist`.
    static let gpx = UTType(
        importedAs: "com.topografix.gpx",
        conformingTo: .xml
    )
}
