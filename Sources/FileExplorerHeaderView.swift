import AppKit
import CmuxAppKitSupportUI
import CmuxFoundation

/// Pure AppKit header bar with folder icon, path label, and hidden files toggle.
final class FileExplorerHeaderView: NSView {
    private let iconView = CmuxResolvedIconImageView()
    private let retryButton = NSButton()
    private var retry: (() -> Void)?
    /// Shown while the Files root is pinned; clicking it unpins.
    private let unpinButton = NSButton()
    private var unpin: (() -> Void)?
    private let trailingButtons = NSStackView()
    private let pathLabel = NSTextField(labelWithString: "")
    private var pathTrailingToRetryConstraint: NSLayoutConstraint?
    private var pathTrailingToEdgeConstraint: NSLayoutConstraint?
    private var heightConstraint: NSLayoutConstraint?
    private var displayPath = ""
    private var quickSearchQuery: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        setupViews()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupViews() {
        iconView.translatesAutoresizingMaskIntoConstraints = false

        pathLabel.translatesAutoresizingMaskIntoConstraints = false
        applyFonts()
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.maximumNumberOfLines = 1
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        addSubview(iconView)
        addSubview(pathLabel)
        retryButton.translatesAutoresizingMaskIntoConstraints = false
        retryButton.image = NSImage(systemSymbolName: "arrow.clockwise", accessibilityDescription: nil)
        retryButton.bezelStyle = .inline
        retryButton.isBordered = false
        retryButton.target = self
        retryButton.action = #selector(retryFiles)
        retryButton.toolTip = String(localized: "common.retry", defaultValue: "Retry")
        retryButton.setAccessibilityLabel(retryButton.toolTip)
        unpinButton.translatesAutoresizingMaskIntoConstraints = false
        unpinButton.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil)
        unpinButton.contentTintColor = .secondaryLabelColor
        unpinButton.bezelStyle = .inline
        unpinButton.isBordered = false
        unpinButton.target = self
        unpinButton.action = #selector(unpinFilesRoot)
        unpinButton.toolTip = String(
            localized: "fileExplorer.header.unpinFilesRoot",
            defaultValue: "Files root is pinned. Click to follow the terminal directory."
        )
        unpinButton.setAccessibilityLabel(
            String(localized: "fileExplorer.contextMenu.followTerminalDirectory", defaultValue: "Follow Terminal Directory")
        )
        trailingButtons.translatesAutoresizingMaskIntoConstraints = false
        trailingButtons.orientation = .horizontal
        trailingButtons.spacing = 4
        trailingButtons.addArrangedSubview(unpinButton)
        trailingButtons.addArrangedSubview(retryButton)
        addSubview(trailingButtons)

        let heightConstraint = heightAnchor.constraint(equalToConstant: RightSidebarChromeMetrics.secondaryBarHeight)
        self.heightConstraint = heightConstraint

        let pathTrailingToRetryConstraint = pathLabel.trailingAnchor.constraint(equalTo: trailingButtons.leadingAnchor, constant: -8)
        let pathTrailingToEdgeConstraint = pathLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8)
        self.pathTrailingToRetryConstraint = pathTrailingToRetryConstraint
        self.pathTrailingToEdgeConstraint = pathTrailingToEdgeConstraint

        NSLayoutConstraint.activate([
            heightConstraint,

            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: RightSidebarChromeMetrics.contentIconLeadingPadding),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: RightSidebarChromeMetrics.contentIconFrameSize),
            iconView.heightAnchor.constraint(equalToConstant: RightSidebarChromeMetrics.contentIconFrameSize),

            pathLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: RightSidebarChromeMetrics.contentIconTextSpacing),
            pathLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            trailingButtons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            trailingButtons.centerYAnchor.constraint(equalTo: centerYAnchor),
            retryButton.widthAnchor.constraint(equalToConstant: 18),
            unpinButton.widthAnchor.constraint(equalToConstant: 18),
        ])
        pathTrailingToRetryConstraint.isActive = false
        pathTrailingToEdgeConstraint.isActive = true
        retryButton.isHidden = true
        unpinButton.isHidden = true
        applyHeaderState()
    }

    func applyFonts() {
        pathLabel.font = GlobalFontMagnification.systemFont(ofSize: 11, weight: .medium)
        heightConstraint?.constant = RightSidebarChromeMetrics.secondaryBarHeight
    }

    @objc private func retryFiles() { retry?() }

    @objc private func unpinFilesRoot() { unpin?() }

    func update(displayPath: String, retry: (() -> Void)? = nil, unpin: (() -> Void)? = nil) {
        self.retry = retry
        self.unpin = unpin
        retryButton.isHidden = retry == nil
        unpinButton.isHidden = unpin == nil
        // Deactivate first so the two required trailing constraints are never active together.
        let showsRetry = retry != nil || unpin != nil
        let inactive = showsRetry ? pathTrailingToEdgeConstraint : pathTrailingToRetryConstraint
        let active = showsRetry ? pathTrailingToRetryConstraint : pathTrailingToEdgeConstraint
        inactive?.isActive = false
        active?.isActive = true
        guard self.displayPath != displayPath else { return }
        self.displayPath = displayPath
        applyHeaderState()
    }

    func updateQuickSearch(query: String?) {
        guard quickSearchQuery != query else { return }
        quickSearchQuery = query
        applyHeaderState()
    }

    private func applyHeaderState() {
        assert(Thread.isMainThread, "AppKit image updates must run on the main thread")
        if let quickSearchQuery {
            iconView.apply(CmuxResolvedIconRequest(
                source: .systemSymbol(name: "magnifyingglass", accessibilityDescription: nil),
                size: NSSize(width: 14, height: 14),
                tintColor: .secondaryLabelColor,
                symbolWeight: .regular
            ))
            pathLabel.stringValue = "/" + quickSearchQuery
            pathLabel.toolTip = pathLabel.stringValue
        } else {
            iconView.apply(CmuxResolvedIconRequest(
                source: .systemSymbol(name: "folder.fill", accessibilityDescription: nil),
                size: NSSize(width: 14, height: 14),
                tintColor: .secondaryLabelColor,
                symbolWeight: .regular
            ))
            pathLabel.stringValue = displayPath
            pathLabel.toolTip = displayPath
        }
    }
}
