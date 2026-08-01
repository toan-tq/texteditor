import AppKit

/// Centralized theme constants ported from Java AppTheme.java.
/// Unlike SWT, NSColor is reference-counted via ARC -- no manual dispose needed.
struct AppTheme {

    // MARK: - Syntax Colors

    static let kwColor      = NSColor(red: 0/255.0, green: 0/255.0, blue: 180/255.0, alpha: 1)
    static let typeColor    = NSColor(red: 0/255.0, green: 128/255.0, blue: 128/255.0, alpha: 1)
    static let stringColor  = NSColor(red: 163/255.0, green: 21/255.0, blue: 21/255.0, alpha: 1)
    static let commentColor = NSColor(red: 0/255.0, green: 128/255.0, blue: 0/255.0, alpha: 1)
    static let numberColor  = NSColor(red: 180/255.0, green: 0/255.0, blue: 0/255.0, alpha: 1)
    static let preprocColor = NSColor(red: 128/255.0, green: 0/255.0, blue: 128/255.0, alpha: 1)

    // MARK: - Markdown Colors

    static let mdHeadingColor = NSColor(red: 0/255.0, green: 80/255.0, blue: 180/255.0, alpha: 1)
    static let mdBoldColor    = NSColor(red: 50/255.0, green: 50/255.0, blue: 50/255.0, alpha: 1)
    static let mdCodeColor    = NSColor(red: 180/255.0, green: 60/255.0, blue: 0/255.0, alpha: 1)
    static let mdLinkColor    = NSColor(red: 0/255.0, green: 100/255.0, blue: 200/255.0, alpha: 1)
    static let mdQuoteColor   = NSColor(red: 80/255.0, green: 130/255.0, blue: 60/255.0, alpha: 1)

    // MARK: - UI Colors

    static let lineNumBg       = NSColor(red: 240/255.0, green: 240/255.0, blue: 240/255.0, alpha: 1)
    static let lineNumFg       = NSColor(red: 130/255.0, green: 130/255.0, blue: 130/255.0, alpha: 1)
    static let currentLineBg   = NSColor(red: 232/255.0, green: 242/255.0, blue: 254/255.0, alpha: 1)
    static let statusBg        = NSColor(red: 236/255.0, green: 236/255.0, blue: 236/255.0, alpha: 1)
    static let findHighlightBg = NSColor(red: 255/255.0, green: 235/255.0, blue: 120/255.0, alpha: 1)
    static let findCurrentBg   = NSColor(red: 255/255.0, green: 165/255.0, blue: 0/255.0, alpha: 1)
    static let bookmarkBg      = NSColor(red: 180/255.0, green: 220/255.0, blue: 255/255.0, alpha: 1)

    // MARK: - Fonts

    /// The editor font. Everything that draws text derives from this one, so
    /// a font the user picks survives the next highlight pass — the bold and
    /// italic variants used to name Menlo outright, which meant every
    /// re-highlight quietly dragged the whole document back to Menlo.
    static var baseFont: NSFont = defaultMonoFont(size: 14) {
        didSet { variantCache.removeAll() }
    }

    /// Base point size. Setting it keeps the current family.
    static var fontSize: CGFloat {
        get { baseFont.pointSize }
        set { baseFont = NSFontManager.shared.convert(baseFont, toSize: newValue) }
    }

    /// Convenience accessors that always reflect the current `baseFont`.
    static var monoFont: NSFont           { baseFont }
    static var monoFontBold: NSFont       { variant(.boldFontMask) }
    static var monoFontItalic: NSFont     { variant(.italicFontMask) }
    static var monoFontBoldItalic: NSFont { variant([.boldFontMask, .italicFontMask]) }

    /// Returns the editor font at the given point size.
    static func monoFont(size: CGFloat) -> NSFont {
        size == baseFont.pointSize ? baseFont : NSFontManager.shared.convert(baseFont, toSize: size)
    }

    /// Menlo (or a system fallback) — the font used until the user picks one.
    static func defaultMonoFont(size: CGFloat) -> NSFont {
        NSFont(name: "Menlo", size: size)
            ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    /// Derived bold/italic faces of `baseFont`. Cached because the highlighter
    /// asks for these once per styled span, and a family lookup per span shows
    /// up on large files.
    private static var variantCache: [NSFontTraitMask.RawValue: NSFont] = [:]

    private static func variant(_ traits: NSFontTraitMask) -> NSFont {
        if let cached = variantCache[traits.rawValue] { return cached }
        let font = NSFontManager.shared.convert(baseFont, toHaveTrait: traits)
        variantCache[traits.rawValue] = font
        return font
    }

    static let tabBarFont = NSFont.systemFont(ofSize: 12)
}
