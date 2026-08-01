import AppKit

// MARK: - Delegate protocol

protocol TabBarViewDelegate: AnyObject {
    func tabBar(_ tabBar: TabBarView, didSelectTabAt index: Int)
    func tabBar(_ tabBar: TabBarView, didCloseTabAt index: Int)
    func tabBar(_ tabBar: TabBarView, contextMenuForTabAt index: Int) -> NSMenu?
    func tabBar(_ tabBar: TabBarView, didMoveTabFrom fromIndex: Int, to toIndex: Int)
}

// MARK: - TabBarView

class TabBarView: NSView {

    // MARK: - Types

    struct Tab {
        var title: String
        var isDirty: Bool
        var tooltip: String
    }

    // MARK: - Public state

    weak var delegate: TabBarViewDelegate?
    private(set) var tabs: [Tab] = []
    private(set) var selectedIndex: Int = -1

    // MARK: - Layout constants

    private let tabHeight: CGFloat = 28
    private let tabMinWidth: CGFloat = 120
    private let tabMaxWidth: CGFloat = 200
    private let tabHorizontalPadding: CGFloat = 10
    private let tabBarLeftMargin: CGFloat = 42  // align with editor content past line number gutter
    private let closeButtonSize: CGFloat = 14
    private let closeButtonPadding: CGFloat = 6
    private let separatorWidth: CGFloat = 1.0

    // MARK: - Tracking state

    private var hoveredTabIndex: Int = -1
    private var trackingArea: NSTrackingArea?

    // MARK: - Drag state

    private var dragSourceIndex: Int = -1
    private var dragStartPoint: NSPoint = .zero
    private var isDragging: Bool = false
    private let dragThreshold: CGFloat = 5

    // MARK: - Colors

    private let selectedTabBg = NSColor.controlBackgroundColor
    private let unselectedTabBg = NSColor(white: 0.88, alpha: 1.0)
    private let tabBarBg = NSColor(white: 0.82, alpha: 1.0)
    private let selectedTabText = NSColor.labelColor
    private let unselectedTabText = NSColor.secondaryLabelColor
    private let closeButtonColor = NSColor.secondaryLabelColor
    private let closeButtonHoverBg = NSColor(white: 0.0, alpha: 0.1)
    private let separatorColor = NSColor(white: 0.75, alpha: 1.0)
    private let dirtyDotColor = NSColor.systemOrange

    // MARK: - Intrinsic size

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: tabHeight)
    }

    override var isFlipped: Bool { true }

    // MARK: - Public API

    func addTab(_ tab: Tab) {
        tabs.append(tab)
        selectedIndex = tabs.count - 1
        needsDisplay = true
        invalidateIntrinsicContentSize()
    }

    func removeTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        tabs.remove(at: index)

        if tabs.isEmpty {
            selectedIndex = -1
        } else if selectedIndex >= tabs.count {
            selectedIndex = tabs.count - 1
        } else if selectedIndex > index {
            selectedIndex -= 1
        } else if selectedIndex == index {
            selectedIndex = min(index, tabs.count - 1)
        }

        hoveredTabIndex = -1
        needsDisplay = true
    }

    func updateTab(at index: Int, tab: Tab) {
        guard tabs.indices.contains(index) else { return }
        tabs[index] = tab
        needsDisplay = true
    }

    func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        selectedIndex = index
        needsDisplay = true
    }

    // MARK: - Geometry helpers

    /// Returns the width allocated for each tab, clamped to [tabMinWidth, tabMaxWidth].
    private func tabWidth() -> CGFloat {
        guard !tabs.isEmpty else { return tabMinWidth }
        let available = (bounds.width - tabBarLeftMargin) / CGFloat(tabs.count)
        return min(max(available, tabMinWidth), tabMaxWidth)
    }

    /// Returns the frame rect for the tab at the given index.
    private func tabRect(at index: Int) -> NSRect {
        let w = tabWidth()
        return NSRect(x: tabBarLeftMargin + CGFloat(index) * w, y: 0, width: w, height: tabHeight)
    }

    /// Returns the rect for the close button within a tab rect.
    private func closeButtonRect(in tabRect: NSRect) -> NSRect {
        let x = tabRect.maxX - closeButtonSize - closeButtonPadding
        let y = (tabRect.height - closeButtonSize) / 2.0
        return NSRect(x: x, y: y, width: closeButtonSize, height: closeButtonSize)
    }

    /// Returns the index of the tab under the given point, or -1 if none.
    private func tabIndex(at point: NSPoint) -> Int {
        for i in tabs.indices {
            if tabRect(at: i).contains(point) { return i }
        }
        return -1
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Background
        tabBarBg.setFill()
        bounds.fill()

        let font = AppTheme.tabBarFont
        let w = tabWidth()

        for i in tabs.indices {
            let rect = tabRect(at: i)
            let isSelected = (i == selectedIndex)
            let isHovered = (i == hoveredTabIndex)

            // Tab background
            let bg = isSelected ? selectedTabBg : (isHovered ? NSColor(white: 0.92, alpha: 1.0) : unselectedTabBg)
            bg.setFill()

            if isSelected {
                rect.fill()
            } else {
                rect.fill()
            }

            // Right-side separator between unselected tabs
            if !isSelected && i < tabs.count - 1 && (i + 1) != selectedIndex {
                separatorColor.setFill()
                NSRect(x: rect.maxX - separatorWidth, y: 4, width: separatorWidth, height: tabHeight - 8).fill()
            }

            // Build display title
            let tab = tabs[i]
            var displayTitle = tab.title
            if displayTitle.count > 20 {
                displayTitle = String(displayTitle.prefix(18)) + "\u{2026}"
            }

            // Dirty dot prefix
            let prefix = tab.isDirty ? "\u{2022} " : ""

            // Text attributes
            let textColor = isSelected ? selectedTabText : unselectedTabText
            let attrs: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: textColor
            ]

            let fullTitle = prefix + displayTitle
            let titleSize = fullTitle.size(withAttributes: attrs)

            // Text position: left-padded, vertically centered
            let textX = rect.minX + tabHorizontalPadding
            let textY = (tabHeight - titleSize.height) / 2.0
            let maxTextWidth = w - tabHorizontalPadding * 2 - closeButtonSize - closeButtonPadding
            let textRect = NSRect(x: textX, y: textY, width: maxTextWidth, height: titleSize.height)

            // Draw dirty indicator + title
            if tab.isDirty {
                // Draw a 7pt filled circle as dirty indicator
                let dotDiameter: CGFloat = 7
                let dotSpacing: CGFloat = 5
                let dotY = (tabHeight - dotDiameter) / 2.0
                let dotRect = NSRect(x: textX, y: dotY, width: dotDiameter, height: dotDiameter)
                dirtyDotColor.setFill()
                NSBezierPath(ovalIn: dotRect).fill()

                // Draw title after the dot
                let restX = textX + dotDiameter + dotSpacing
                let restRect = NSRect(x: restX, y: textY,
                                      width: maxTextWidth - dotDiameter - dotSpacing, height: titleSize.height)
                displayTitle.draw(with: restRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                  attributes: attrs)
            } else {
                displayTitle.draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
                                  attributes: attrs)
            }

            // Close button: show on selected tab or on hover
            if isSelected || isHovered {
                drawCloseButton(in: closeButtonRect(in: rect), hovered: isHovered && !isSelected)
            }
        }

        // Bottom border line for the tab bar
        NSColor(white: 0.70, alpha: 1.0).setFill()
        NSRect(x: 0, y: tabHeight - 1, width: bounds.width, height: 1).fill()
    }

    private func drawCloseButton(in rect: NSRect, hovered: Bool) {
        // Draw a subtle circular background on hover
        if hovered {
            closeButtonHoverBg.setFill()
            let bgPath = NSBezierPath(ovalIn: rect.insetBy(dx: -1, dy: -1))
            bgPath.fill()
        }

        // Draw the x glyph
        closeButtonColor.setStroke()
        let inset: CGFloat = 3.5
        let path = NSBezierPath()
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        path.move(to: NSPoint(x: rect.minX + inset, y: rect.minY + inset))
        path.line(to: NSPoint(x: rect.maxX - inset, y: rect.maxY - inset))
        path.move(to: NSPoint(x: rect.maxX - inset, y: rect.minY + inset))
        path.line(to: NSPoint(x: rect.minX + inset, y: rect.maxY - inset))
        path.stroke()
    }

    // MARK: - Mouse handling

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = tabIndex(at: point)
        guard index >= 0 else { return }

        // Check if close button was clicked
        let closeBtnRect = closeButtonRect(in: tabRect(at: index))
        if closeBtnRect.contains(point) {
            delegate?.tabBar(self, didCloseTabAt: index)
            return
        }

        // Select tab
        if index != selectedIndex {
            selectedIndex = index
            needsDisplay = true
            delegate?.tabBar(self, didSelectTabAt: index)
        }

        // Prepare for potential drag
        dragSourceIndex = index
        dragStartPoint = point
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard dragSourceIndex >= 0 else { return }
        let point = convert(event.locationInWindow, from: nil)

        if !isDragging {
            let dx = abs(point.x - dragStartPoint.x)
            if dx < dragThreshold { return }
            isDragging = true
        }

        // Calculate target index from mouse X position. Tabs start at
        // tabBarLeftMargin, so subtract it or every boundary lands early.
        let targetIndex = max(0, min(tabs.count - 1, Int((point.x - tabBarLeftMargin) / tabWidth())))
        if targetIndex != dragSourceIndex {
            // Reorder locally
            let tab = tabs.remove(at: dragSourceIndex)
            tabs.insert(tab, at: targetIndex)

            // Update selectedIndex to follow the dragged tab
            selectedIndex = targetIndex

            delegate?.tabBar(self, didMoveTabFrom: dragSourceIndex, to: targetIndex)
            dragSourceIndex = targetIndex
            needsDisplay = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        dragSourceIndex = -1
        isDragging = false
    }

    // Middle-click to close tab
    override func otherMouseDown(with event: NSEvent) {
        guard event.buttonNumber == 2 else {
            super.otherMouseDown(with: event)
            return
        }
        let point = convert(event.locationInWindow, from: nil)
        let index = tabIndex(at: point)
        guard index >= 0 else { return }
        delegate?.tabBar(self, didCloseTabAt: index)
    }

    override func rightMouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = tabIndex(at: point)
        guard index >= 0 else { return }

        if let contextMenu = delegate?.tabBar(self, contextMenuForTabAt: index) {
            NSMenu.popUpContextMenu(contextMenu, with: event, for: self)
        }
    }

    // MARK: - Mouse tracking for hover effects

    override func updateTrackingAreas() {
        super.updateTrackingAreas()

        if let existing = trackingArea {
            removeTrackingArea(existing)
        }

        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea!)
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let index = tabIndex(at: point)
        if index != hoveredTabIndex {
            hoveredTabIndex = index
            // Update tooltip to show full path of hovered tab
            toolTip = tabs.indices.contains(index) ? tabs[index].tooltip : nil
            needsDisplay = true
        }
    }

    override func mouseExited(with event: NSEvent) {
        if hoveredTabIndex != -1 {
            hoveredTabIndex = -1
            toolTip = nil
            needsDisplay = true
        }
    }
}
