import Foundation

/// Stub provider for Cursor — disabled in v0.2.0; real implementation lands in v0.3.
struct CursorProvider: UsageProvider {
    let id: String = ProviderID.cursor
    let displayName: String = "Cursor"
    let isEnabled: Bool = false

    func fetch() async -> [UsageEntry] { [] }
}
