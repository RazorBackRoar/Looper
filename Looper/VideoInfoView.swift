import AppKit
import MapKit

// MARK: - Right-hand metadata inspector (read-only; map only after explicit consent)

final class VideoInfoView: NSVisualEffectView {
    typealias MapFactory = (VideoLocation) -> NSView?

    /// Injected for tests — production builds a configured MKMapView.
    var mapFactory: MapFactory = VideoInfoView.makeDefaultMapView
    /// Test hook: number of times a map view was actually created.
    private(set) var mapCreationCount = 0

    private let fileNameLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let stackView = NSStackView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")

    private var renderedState: VideoMetadataSession.State?
    private var mapView: NSView?
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

    /// New clip or close: drop rendered content and any map/consent state.
    func reset() {
        renderedState = nil
        detailsExpanded = false
        removeMap()
        stackView.arrangedSubviews.forEach { stackView.removeArrangedSubview($0); $0.removeFromSuperview() }
    }

    private func rebuildBody(for state: VideoMetadataSession.State) {
        removeMap()
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
            let label = secondaryText("Loading metadata…")
            stackView.addArrangedSubview(label)
        case .unavailable(let message):
            stackView.addArrangedSubview(secondaryText(message))
        case .ready(let snapshot), .partial(let snapshot, _):
            render(snapshot)
        }
    }

    private func render(_ snapshot: VideoMetadataSnapshot) {
        for section in snapshot.sections {
            addSection(title: section.title, fields: section.fields, location: snapshot.location)
        }
        if !snapshot.unavailableSections.isEmpty {
            let note = secondaryText("Unavailable: " + snapshot.unavailableSections.joined(separator: ", "))
            stackView.addArrangedSubview(note)
        }
        if !snapshot.additionalFields.isEmpty {
            addDetailsDisclosure(fields: snapshot.additionalFields)
        }
    }

    // MARK: - Sections

    private func addSection(title: String, fields: [VideoMetadataField], location: VideoLocation?) {
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

        if title == "Location", let location {
            sectionStack.addArrangedSubview(makeMapConsentRow(location: location))
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
            let row = makeRow(label: field.label, value: field.value)
            detailsStack.addArrangedSubview(row)
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

    // MARK: - Location map (opt-in only)

    private func makeMapConsentRow(location: VideoLocation) -> NSView {
        let container = NSStackView()
        container.orientation = .vertical
        container.alignment = .leading
        container.spacing = 6
        container.translatesAutoresizingMaskIntoConstraints = false

        if let mapView {
            mapView.translatesAutoresizingMaskIntoConstraints = false
            container.addArrangedSubview(mapView)
            mapView.widthAnchor.constraint(equalToConstant: Self.columnWidth - 64).isActive = true
            mapView.heightAnchor.constraint(equalToConstant: 200).isActive = true

            let hide = NSButton(title: "Hide Map", target: self, action: #selector(hideMap(_:)))
            hide.bezelStyle = .accessoryBarAction
            hide.controlSize = .small
            hide.translatesAutoresizingMaskIntoConstraints = false
            container.addArrangedSubview(hide)
        } else {
            let show = NSButton(title: "Show Map", target: self, action: #selector(showMap(_:)))
            show.bezelStyle = .accessoryBarAction
            show.controlSize = .small
            show.translatesAutoresizingMaskIntoConstraints = false
            container.addArrangedSubview(show)

            container.addArrangedSubview(secondaryText("Loads Apple Maps for this recorded location."))
        }
        return container
    }

    @objc private func showMap(_ sender: NSButton) {
        let location: VideoLocation?
        switch renderedState {
        case .ready(let snap), .partial(let snap, _): location = snap.location
        default: location = nil
        }
        guard let location else { return }
        guard let view = mapFactory(location) else {
            if let renderedState { rebuildBody(for: renderedState) }
            return
        }
        mapCreationCount += 1
        mapView = view
        if let renderedState { rebuildBody(for: renderedState) }
    }

    @objc private func hideMap(_ sender: NSButton) {
        removeMap()
        if let renderedState { rebuildBody(for: renderedState) }
    }

    private func removeMap() {
        mapView?.removeFromSuperview()
        mapView = nil
    }

    private static func makeDefaultMapView(_ location: VideoLocation) -> NSView? {
        let mapView = MKMapView()
        mapView.preferredConfiguration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .default)
        mapView.showsUserLocation = false
        mapView.isZoomEnabled = true
        mapView.isScrollEnabled = true
        mapView.isPitchEnabled = false
        mapView.isRotateEnabled = false
        mapView.showsZoomControls = false
        mapView.showsCompass = false
        mapView.wantsLayer = true
        mapView.layer?.cornerRadius = 8
        mapView.layer?.masksToBounds = true
        let coordinate = CLLocationCoordinate2D(latitude: location.latitude, longitude: location.longitude)
        mapView.setRegion(
            MKCoordinateRegion(center: coordinate, latitudinalMeters: 3000, longitudinalMeters: 3000),
            animated: false)
        let annotation = MKPointAnnotation()
        annotation.coordinate = coordinate
        annotation.title = "Recorded location"
        mapView.addAnnotation(annotation)
        return mapView
    }
}
