import SwiftData

/// Rewrites older UIKit-keyed text payloads before they reach the Mac app.
@MainActor
enum RichTextMigration {
    static func run(in container: ModelContainer) throws {
        let context = ModelContext(container)
        let elements = try context.fetch(FetchDescriptor<PageElement>())
        var changed = false
        for element in elements {
            guard let data = element.richTextData, !RichTextCodec.isPortable(data),
                  let attributed = PageElement.decodeRichText(from: data),
                  let portable = RichTextCodec.encode(attributed) else { continue }
            element.richTextData = portable
            changed = true
        }
        if changed { try context.save() }
    }
}
