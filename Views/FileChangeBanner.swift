import AppKit

/// A strip above the editor saying the file changed underneath an edited
/// buffer, with the two ways out.
///
/// Deliberately not an `NSAlert`: switching a git branch can change twenty
/// open files at once, and twenty stacked modal sheets are unusable. This sits
/// on the tab it belongs to and waits.
class FileChangeBanner: NSView {

    private let label = NSTextField(labelWithString: "")
    private let primaryButton = NSButton(title: "", target: nil, action: nil)
    private let secondaryButton = NSButton(title: "", target: nil, action: nil)

    private var onPrimary: (() -> Void)?
    private var onSecondary: (() -> Void)?

    /// Driven by the controller so the banner can collapse out of the layout
    /// rather than overlap the editor when there is nothing to say.
    private(set) var heightConstraint: NSLayoutConstraint!

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupUI()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupUI()
    }

    private func setupUI() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.18).cgColor

        label.font = NSFont.systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingMiddle
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        for button in [primaryButton, secondaryButton] {
            button.bezelStyle = .rounded
            button.controlSize = .small
            button.font = NSFont.systemFont(ofSize: 11)
            button.target = self
        }
        primaryButton.action = #selector(primaryTapped)
        secondaryButton.action = #selector(secondaryTapped)

        for subview in [label, primaryButton, secondaryButton] as [NSView] {
            subview.translatesAutoresizingMaskIntoConstraints = false
            addSubview(subview)
        }

        heightConstraint = heightAnchor.constraint(equalToConstant: 0)

        NSLayoutConstraint.activate([
            heightConstraint,
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            primaryButton.leadingAnchor.constraint(greaterThanOrEqualTo: label.trailingAnchor, constant: 12),
            primaryButton.trailingAnchor.constraint(equalTo: secondaryButton.leadingAnchor, constant: -8),
            primaryButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            secondaryButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            secondaryButton.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])

        isHidden = true
    }

    /// Shows the strip. `primary` is the action that resolves the conflict,
    /// `secondary` the one that dismisses it.
    func show(message: String,
              primary: (title: String, action: () -> Void),
              secondary: (title: String, action: () -> Void)) {
        label.stringValue = message
        primaryButton.title = primary.title
        secondaryButton.title = secondary.title
        onPrimary = primary.action
        onSecondary = secondary.action
        isHidden = false
        heightConstraint.constant = 28
    }

    func hide() {
        isHidden = true
        heightConstraint.constant = 0
        onPrimary = nil
        onSecondary = nil
    }

    @objc private func primaryTapped() { onPrimary?() }
    @objc private func secondaryTapped() { onSecondary?() }
}
