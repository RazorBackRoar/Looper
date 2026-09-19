import AppKit

// MARK: - Right-hand metadata inspector (read-only)

final class VideoInfoView: NSVisualEffectView {
    private let fileNameLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let stackView = NSStackView()

    private var renderedState: VideoMetadataSession.State?
    private var detailsExpanded = false

    static let columnWidth: CGFloat = 300

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .sidebar
        state = .active
        blendingMode = .behindWindow

        let titleLabel = NSTextField(labelWithString: "Info")
        titleLabel.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        fileNameLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        fileNameLabel.textColor = .secondaryLabelColor
        fileNameLabel.lineBreakMode = .byTruncatingMiddle
        fileNameLabel.maximumNumberOfLines = 2
        fileNameLabel.translatesAutoresizingMaskIntoConstraints = false

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.horizontalScrollElasticity = .none
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.contentInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)

        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 14
        stackView.edgeInsets = NSEdgeInsets(top: 4, left: 16, bottom: 20, right: 16)
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.setHuggingPriority(.defaultHigh, for: .vertical)

        scrollView.documentView = stackView

        addSubview(titleLabel)
        addSubview(fileNameLabel)
        addSubview(scrollView)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),

            fileNameLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            fileNameLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            fileNameLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: fileNameLabel.bottomAnchor, constant: 10),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),

            stackView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            stackView.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Presentation

    /// File name shown immediately in the header, before metadata arrives.
    func setFileName(_ name: String) {
        fileNameLabel.stringValue = name
    }

    func present(_ state: VideoMetadataSession.State) {
        if let renderedState, renderedState == state { return }
        renderedState = state
        rebuildBody(for: state)
    }

    /// New clip or close: drop rendered content.
    func reset() {
        renderedState = nil
        detailsExpanded = false
        stackView.arrangedSubviews.forEach { stackView.removeArrangedSubview($0); $0.removeFromSuperview() }
    }

    private func rebuildBody(for state: VideoMetadataSession.State) {
        stackView.arrangedSubviews.forEach { stackView.removeArrangedSubview($0); $0.removeFromSuperview() }

        switch state {
        case .idle:
            break
        case .loading:
            let spinner = NSProgressIndicator()
            spinner.style = .spinning
            spinner.controlSize = .small
            spinner.translatesAutoresizingMaskIntoConstraints = false
            spinner.startAnimation(nil)
            stackView.addArrangedSubview(spinner)
            stackView.addArrangedSubview(secondaryText("Loading metadata…"))
        case .unavailable(let message):
            stackView.addArrangedSubview(secondaryText(message))
        case .ready(let snapshot), .partial(let snapshot, _):
            render(snapshot)
        }
    }

    /// Fixed display schema — every expected row is always rendered, "N/A" when
    /// the file doesn't carry that tag. (Section, label) pairs match the labels
    /// `VideoMetadataReader` emits; multi-track prefixes ("Video 1 Resolution")
    /// are matched by suffix.
    private static let schema: [(section: String, labels: [String])] = [
        ("File", ["Name", "Format", "Size", "File created", "File modified", "Path"]),
        ("Recorded", ["Recorded"]),
        ("Video", ["Duration", "Resolution", "Encoded", "Frame rate", "Codec", "Bit rate", "Color"]),
        ("Audio", ["Codec", "Sample rate", "Channels", "Language", "Bit rate"]),
        ("Camera", ["Make", "Model", "Lens", "Focal length", "Aperture", "ISO", "Software"]),
        ("Location", ["GPS", "Place"]),
    ]

    private func render(_ snapshot: VideoMetadataSnapshot) {
        let lookup = makeLookup(snapshot)
        for entry in Self.schema {
            let fields = entry.labels.map { label in
                VideoMetadataField(key: label, label: label,
                                   value: lookup(entry.section, label) ?? "N/A", source: "")
            }
            addSection(title: entry.section, fields: fields)
        }
        if !snapshot.unavailableSections.isEmpty {
            stackView.addArrangedSubview(
                secondaryText("Unavailable: " + snapshot.unavailableSections.joined(separator: ", ")))
        }
        if !snapshot.additionalFields.isEmpty {
            addDetailsDisclosure(fields: snapshot.additionalFields)
        }
    }

    private func makeLookup(
        _ snapshot: VideoMetadataSnapshot
    ) -> (_ section: String, _ label: String) -> String? {
        var table: [String: [String: String]] = [:]
        for section in snapshot.sections {
            var map = table[section.title] ?? [:]
            for field in section.fields where map[field.label] == nil {
                map[field.label] = field.value
            }
            table[section.title] = map
        }
        return { section, label in
            guard let map = table[section] else { return nil }
            if let exact = map[label] { return exact }
            for (key, value) in map where key.hasSuffix(" " + label) { return value }
            return nil
        }
    }

    // MARK: - Sections

    private func addSection(title: String, fields: [VideoMetadataField]) {
        let sectionStack = NSStackView()
        sectionStack.orientation = .vertical
        sectionStack.alignment = .leading
        sectionStack.spacing = 6
        sectionStack.translatesAutoresizingMaskIntoConstraints = false

        let header = NSTextField(labelWithString: title)
        header.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        header.textColor = .secondaryLabelColor
        sectionStack.addArrangedSubview(header)

        for field in fields {
            sectionStack.addArrangedSubview(makeRow(label: field.label, value: field.value))
        }

        stackView.addArrangedSubview(sectionStack)
        sectionStack.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -32).isActive = true

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(divider)
        divider.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -32).isActive = true
    }

    private func makeRow(label: String, value: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false

        let labelView = NSTextField(labelWithString: label)
        labelView.font = NSFont.systemFont(ofSize: 11)
        labelView.textColor = .secondaryLabelColor
        labelView.translatesAutoresizingMaskIntoConstraints = false
        labelView.widthAnchor.constraint(equalToConstant: 84).isActive = true

        let valueView = NSTextField(labelWithString: value)
        valueView.font = NSFont.systemFont(ofSize: 12)
        valueView.textColor = .labelColor
        valueView.isSelectable = true
        valueView.lineBreakMode = .byWordWrapping
        valueView.maximumNumberOfLines = 0
        valueView.translatesAutoresizingMaskIntoConstraints = false
        valueView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        row.addArrangedSubview(labelView)
        row.addArrangedSubview(valueView)
        return row
    }

    private func secondaryText(_ string: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: string)
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.translatesAutoresizingMaskIntoConstraints = false
        return label
    }

    // MARK: - More Details

    private func addDetailsDisclosure(fields: [VideoMetadataField]) {
        let button = NSButton(title: "", target: self, action: #selector(toggleDetails(_:)))
        button.bezelStyle = .inline
        button.isBordered = false
        button.setButtonType(.pushOnPushOff)
        let chevron = NSImage(systemSymbolName: detailsExpanded ? "chevron.down" : "chevron.right",
                              accessibilityDescription: nil)
        let title = NSMutableAttributedString()
        if let chevron {
            let attach = NSTextAttachment()
            attach.image = chevron
            title.append(NSAttributedString(attachment: attach))
            title.append(NSAttributedString(string: " "))
        }
        title.append(NSAttributedString(string: "More Details"))
        button.attributedTitle = title
        button.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        button.contentTintColor = .secondaryLabelColor
        button.translatesAutoresizingMaskIntoConstraints = false
        stackView.addArrangedSubview(button)

        guard detailsExpanded else { return }
        let detailsStack = NSStackView()
        detailsStack.orientation = .vertical
        detailsStack.alignment = .leading
        detailsStack.spacing = 5
        detailsStack.translatesAutoresizingMaskIntoConstraints = false
        for field in fields {
            detailsStack.addArrangedSubview(makeRow(label: field.label, value: field.value))
            let source = secondaryText(field.source + " · " + field.key)
            source.font = NSFont.systemFont(ofSize: 9)
            detailsStack.addArrangedSubview(source)
        }
        stackView.addArrangedSubview(detailsStack)
        detailsStack.widthAnchor.constraint(equalTo: stackView.widthAnchor, constant: -32).isActive = true
    }

    @objc private func toggleDetails(_ sender: NSButton) {
        detailsExpanded.toggle()
        if let renderedState { rebuildBody(for: renderedState) }
    }
}
