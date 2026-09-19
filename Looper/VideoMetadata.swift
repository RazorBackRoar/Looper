import AVFoundation
import CoreMedia
import Foundation

// MARK: - Snapshot model (Sendable value types only — no AVFoundation objects cross actors)

struct VideoLocation: Sendable, Equatable {
    let latitude: Double
    let longitude: Double
    let altitudeMeters: Double?
}

struct VideoMetadataField: Sendable, Equatable {
    let key: String
    let label: String
    let value: String
    let source: String
}

struct VideoMetadataSection: Sendable, Equatable {
    let title: String
    let fields: [VideoMetadataField]
}

struct VideoMetadataSnapshot: Sendable, Equatable {
    let sourceURL: URL
    let sections: [VideoMetadataSection]
    let additionalFields: [VideoMetadataField]
    let location: VideoLocation?
    let unavailableSections: [String]
}

enum VideoMetadataError: Error {
    case unsupportedURL
}

// MARK: - ISO 6709 parsing (pure)

enum ISO6709LocationParser {
    /// Apple writes "+37.3348-122.0090+063.130/". Also accepts the standard
    /// fixed-width degree/minute (DDMM.MM / DDDMM.MM) and degree/minute/second
    /// (DDMMSS.SS / DDDMMSS.SS) forms when digit counts make them unambiguous.
    static func parse(_ raw: String) -> VideoLocation? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty, s.first == "+" || s.first == "-" else { return nil }
        if s.hasSuffix("/") { s.removeLast() }
        guard !s.contains("/") else { return nil } // CRS tail or other extras are unsupported

        let chars = Array(s)
        var signs: [Int] = []
        for (i, c) in chars.enumerated() where c == "+" || c == "-" { signs.append(i) }
        guard signs.count == 2 || signs.count == 3, signs[0] == 0 else { return nil }

        let latText = String(chars[0..<signs[1]])
        let lonEnd = signs.count == 3 ? signs[2] : chars.count
        let lonText = String(chars[signs[1]..<lonEnd])
        let altText = signs.count == 3 ? String(chars[signs[2]..<chars.count]) : nil

        guard let lat = parseCoordinate(latText, digitsForDegree: 2),
              let lon = parseCoordinate(lonText, digitsForDegree: 3),
              lat >= -90, lat <= 90, lon >= -180, lon <= 180 else { return nil }

        var altitude: Double? = nil
        if let altText {
            guard let alt = Double(altText), alt.isFinite else { return nil }
            altitude = alt
        }
        return VideoLocation(latitude: lat, longitude: lon, altitudeMeters: altitude)
    }

    /// Sign + digit groups. Integer-digit counts: latitude 4→DDMM, 6→DDMMSS;
    /// longitude 5→DDDMM, 7→DDDMMSS. Anything else is treated as decimal degrees.
    private static func parseCoordinate(_ text: String, digitsForDegree: Int) -> Double? {
        guard let first = text.first, first == "+" || first == "-" else { return nil }
        let sign: Double = first == "-" ? -1 : 1
        let body = text.dropFirst()
        guard !body.isEmpty, body.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
        let intDigits = body.prefix(while: { $0.isNumber }).count

        let minuteGroups = intDigits - digitsForDegree
        if minuteGroups == 2 || minuteGroups == 4 {
            // Fixed-width degrees + minutes (+ optional seconds), then decimal fraction.
            let degText = body.prefix(digitsForDegree)
            var rest = body.dropFirst(digitsForDegree)
            guard rest.count >= 2 else { return nil }
            let minText = rest.prefix(2)
            rest = rest.dropFirst(2)
            var secText: Substring = ""
            if minuteGroups == 4 {
                guard rest.count >= 2 else { return nil }
                secText = rest.prefix(2)
                rest = rest.dropFirst(2)
            }
            guard rest.isEmpty || (rest.hasPrefix(".") && rest.count > 1) else { return nil }
            let fracText = rest

            guard let deg = Double(degText), let minutes = Double(minText) else { return nil }
            var seconds = secText.isEmpty ? 0.0 : Double(secText)
            var minutesFrac = 0.0
            if !fracText.isEmpty {
                guard let frac = Double("0" + String(fracText)) else { return nil }
                if minuteGroups == 4 {
                    // Seconds carry the fraction: "DDMMSS.SS"
                    seconds = (seconds ?? 0) + frac
                } else {
                    // Minutes carry the fraction: "DDMM.MMMM"
                    minutesFrac = frac
                }
            }
            let totalMinutes = minutes + minutesFrac
            let totalSeconds = seconds ?? 0
            guard totalMinutes < 60, totalSeconds < 60 else { return nil }
            let value = deg + totalMinutes / 60 + totalSeconds / 3600
            guard value.isFinite else { return nil }
            return sign * value
        }

        guard let value = Double(body), value.isFinite else { return nil }
        return sign * value
    }
}

// MARK: - Reader

/// Reads one local file's static metadata. Task-local asset; never touches
/// shared playback state. Everything leaves this file as Sendable values.
enum VideoMetadataReader {
    private static let maxAdditionalFields = 256
    private static let maxValueLength = 2048

    static func read(_ url: URL) async throws -> VideoMetadataSnapshot {
        guard LocalVideoURL.isPlayableFile(url) else { throw VideoMetadataError.unsupportedURL }

        let asset = AVURLAsset(url: url)
        var sections: [VideoMetadataSection] = []
        var additional: [VideoMetadataField] = []
        var unavailable: [String] = []
        var location: VideoLocation?
        var consumedKeys = Set<String>()

        // File section — always attempted first; does not need AVFoundation.
        sections.append(fileSection(for: url))

        try Task.checkCancellation()

        // Collect asset + track metadata items with source labels.
        var items: [(item: AVMetadataItem, source: String)] = []
        if let common = try? await asset.load(.commonMetadata) {
            items += common.map { ($0, "Common") }
        }
        if let formats = try? await asset.load(.availableMetadataFormats) {
            for format in formats {
                try Task.checkCancellation()
                guard let list = try? await asset.loadMetadata(for: format) else { continue }
                items += list.map { ($0, formatSourceLabel(format)) }
            }
        }
        if let meta = try? await asset.load(.metadata) {
            items += meta.map { ($0, "Metadata") }
        }

        var videoTracks: [AVAssetTrack] = []
        do {
            videoTracks = try await asset.loadTracks(withMediaType: .video)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            unavailable.append("Video track")
        }

        for (index, track) in videoTracks.enumerated() {
            try Task.checkCancellation()
            let label = "Video Track \(index + 1)"
            if let meta = try? await track.load(.metadata) {
                items += meta.map { ($0, label) }
            }
            if let formats = try? await track.load(.availableMetadataFormats) {
                for format in formats {
                    guard let list = try? await track.loadMetadata(for: format) else { continue }
                    items += list.map { ($0, label) }
                }
            }
        }

        try Task.checkCancellation()

        // Load each item's readable value once; keep (label, value, source).
        var values: [(key: String, item: AVMetadataItem, source: String, text: String)] = []
        for (item, source) in items {
            guard values.count < 600 else { break }
            if values.count % 16 == 0 { try Task.checkCancellation() }
            let key = item.identifier?.rawValue ?? (item.key as? String) ?? "unknown"
            guard let text = await readableValue(for: item) else { continue }
            values.append((key, item, source, text))
        }

        // Recorded date — embedded capture date, kept separate from filesystem dates.
        if let dateText = firstValue(in: values, matching: { $0.contains("creationdate") || $0.contains("creation_date") || $0.contains("creation date") }) {
            sections.append(VideoMetadataSection(title: "Recorded", fields: [
                VideoMetadataField(key: "creationdate", label: "Recorded", value: dateText, source: "metadata"),
            ]))
            markConsumed(&consumedKeys, values: values) { $0.contains("creationdate") }
        }

        // Camera.
        let cameraSpecs: [(match: String, label: String)] = [
            ("lensmodel", "Lens"), ("lens model", "Lens"),
            ("focallength", "Focal length"), ("focal length", "Focal length"),
            ("aperture", "Aperture"), ("fnumber", "Aperture"), ("f-number", "Aperture"),
            ("iso", "ISO"),
            ("exposurebias", "Exposure bias"), ("exposure", "Exposure"),
            ("cameraidentifier", "Camera ID"), ("camera identifier", "Camera ID"),
            ("software", "Software"), ("encoder", "Software"),
            ("model", "Model"),
            ("make", "Make"),
        ]
        var cameraFields: [VideoMetadataField] = []
        for spec in cameraSpecs {
            for entry in values where entry.key.lowercased().contains(spec.match) {
                let tag = "\(entry.source)|\(entry.key)"
                guard !consumedKeys.contains(tag) else { continue }
                guard !cameraFields.contains(where: { $0.value == entry.text }) else { continue }
                cameraFields.append(VideoMetadataField(key: entry.key, label: spec.label, value: entry.text, source: entry.source))
                consumedKeys.insert(tag)
                break
            }
        }
        if !cameraFields.isEmpty {
            sections.append(VideoMetadataSection(title: "Camera", fields: cameraFields))
        } else {
            sections.append(VideoMetadataSection(title: "Camera", fields: [
                VideoMetadataField(key: "camera", label: "Camera", value: "Not recorded", source: "metadata"),
            ]))
        }

        try Task.checkCancellation()

        // Location.
        var locationFields: [VideoMetadataField] = []
        for entry in values {
            let lower = entry.key.lowercased()
            if lower.contains("iso6709") || lower.hasSuffix("location") {
                if location == nil, let parsed = ISO6709LocationParser.parse(entry.text) {
                    location = parsed
                    locationFields.append(VideoMetadataField(
                        key: entry.key, label: "Coordinates",
                        value: formatCoordinates(parsed), source: entry.source))
                    if let alt = parsed.altitudeMeters {
                        locationFields.append(VideoMetadataField(
                            key: entry.key, label: "Altitude",
                            value: String(format: "%.1f m", alt), source: entry.source))
                    }
                    consumedKeys.insert("\(entry.source)|\(entry.key)")
                }
            } else if lower.contains("location.name") || lower.contains("locationname") {
                locationFields.append(VideoMetadataField(key: entry.key, label: "Place", value: entry.text, source: entry.source))
                consumedKeys.insert("\(entry.source)|\(entry.key)")
            } else if lower.contains("location.body") || lower.contains("locationbody") {
                locationFields.append(VideoMetadataField(key: entry.key, label: "Body", value: entry.text, source: entry.source))
                consumedKeys.insert("\(entry.source)|\(entry.key)")
            } else if lower.contains("location.note") || lower.contains("locationnote") {
                locationFields.append(VideoMetadataField(key: entry.key, label: "Note", value: entry.text, source: entry.source))
                consumedKeys.insert("\(entry.source)|\(entry.key)")
            }
        }
        if !locationFields.isEmpty || location != nil {
            sections.append(VideoMetadataSection(title: "Location", fields: locationFields))
        }

        try Task.checkCancellation()

        // Video section.
        var videoFields: [VideoMetadataField] = []
        var durationSeconds = 0.0
        if let duration = try? await asset.load(.duration) {
            durationSeconds = duration.seconds
            if durationSeconds.isFinite, durationSeconds > 0 {
                videoFields.append(VideoMetadataField(
                    key: "duration", label: "Duration",
                    value: PlaybackFormatting.formatTime(durationSeconds), source: "asset"))
            }
        } else {
            unavailable.append("Duration")
        }
        for (index, track) in videoTracks.enumerated() {
            try Task.checkCancellation()
            let prefix = videoTracks.count > 1 ? "Video \(index + 1) " : ""
            do {
                let natural = try await track.load(.naturalSize)
                let transform = try await track.load(.preferredTransform)
                let display = CGSize(
                    width: abs(natural.width * transform.a + natural.height * transform.c),
                    height: abs(natural.width * transform.b + natural.height * transform.d))
                if display.width > 0, display.height > 0 {
                    videoFields.append(VideoMetadataField(
                        key: "resolution", label: "\(prefix)Resolution",
                        value: "\(Int(display.width)) × \(Int(display.height))", source: "track"))
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {}
            if let fps = try? await track.load(.nominalFrameRate), fps > 0, fps.isFinite {
                videoFields.append(VideoMetadataField(
                    key: "fps", label: "\(prefix)Frame rate", value: formatFrameRate(fps), source: "track"))
            }
            if let rate = try? await track.load(.estimatedDataRate), rate > 0 {
                videoFields.append(VideoMetadataField(
                    key: "bitrate", label: "\(prefix)Bit rate", value: formatBitRate(Double(rate)), source: "track"))
            }
            if let descriptions = try? await track.load(.formatDescriptions) {
                if let fd = descriptions.first {
                    videoFields.append(VideoMetadataField(
                        key: "codec", label: "\(prefix)Codec",
                        value: codecLabel(CMFormatDescriptionGetMediaSubType(fd)), source: "track"))
                    if let encoded = encodedDimensions(fd), videoTracks.count == 1 {
                        let encodedLabel = "\(encoded.width) × \(encoded.height)"
                        if !videoFields.contains(where: { $0.value == encodedLabel }) {
                            videoFields.append(VideoMetadataField(
                                key: "encoded", label: "\(prefix)Encoded",
                                value: encodedLabel, source: "track"))
                        }
                    }
                    if let color = colorDescription(fd) {
                        videoFields.append(VideoMetadataField(
                            key: "color", label: "\(prefix)Color",
                            value: color, source: "track"))
                    }
                }
            }
        }
        sections.append(VideoMetadataSection(title: "Video", fields: videoFields))

        try Task.checkCancellation()

        // Audio section.
        do {
            let audioTracks = try await asset.loadTracks(withMediaType: .audio)
            var audioFields: [VideoMetadataField] = []
            if audioTracks.isEmpty {
                audioFields.append(VideoMetadataField(
                    key: "audio", label: "Audio", value: "No audio track", source: "tracks"))
            }
            for (index, track) in audioTracks.enumerated() {
                try Task.checkCancellation()
                let prefix = audioTracks.count > 1 ? "Audio \(index + 1) " : ""
                var codec = "Unknown"
                var sampleRate: Double?
                var channels: Double?
                if let descriptions = try? await track.load(.formatDescriptions), let fd = descriptions.first {
                    codec = codecLabel(CMFormatDescriptionGetMediaSubType(fd))
                    if let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fd) {
                        sampleRate = asbd.pointee.mSampleRate
                        channels = asbd.pointee.mChannelsPerFrame
                    }
                }
                audioFields.append(VideoMetadataField(
                    key: "acodec", label: "\(prefix)Codec", value: codec, source: "track"))
                if let sampleRate, sampleRate > 0 {
                    audioFields.append(VideoMetadataField(
                        key: "arate", label: "\(prefix)Sample rate",
                        value: formatSampleRate(sampleRate), source: "track"))
                }
                if let channels, channels > 0 {
                    audioFields.append(VideoMetadataField(
                        key: "ach", label: "\(prefix)Channels",
                        value: channelLayout(Int(channels)), source: "track"))
                }
                if let lang = try? await track.load(.languageCode), let code = lang {
                    let name = Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
                    audioFields.append(VideoMetadataField(
                        key: "alang", label: "\(prefix)Language", value: name, source: "track"))
                }
                if let rate = try? await track.load(.estimatedDataRate), rate > 0 {
                    audioFields.append(VideoMetadataField(
                        key: "abitrate", label: "\(prefix)Bit rate",
                        value: formatBitRate(Double(rate)), source: "track"))
                }
            }
            sections.append(VideoMetadataSection(title: "Audio", fields: audioFields))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            unavailable.append("Audio")
        }

        try Task.checkCancellation()

        // More Details — remaining readable tags, deduplicated and bounded.
        var seen = Set<String>()
        for entry in values {
            let tag = "\(entry.source)|\(entry.key)"
            guard !consumedKeys.contains(tag) else { continue }
            let dedupe = "\(entry.key)|\(entry.text)"
            guard seen.insert(dedupe).inserted else { continue }
            guard additional.count < maxAdditionalFields else { break }
            var text = entry.text
            if text.count > maxValueLength {
                text = String(text.prefix(maxValueLength)) + "…"
            }
            additional.append(VideoMetadataField(
                key: entry.key,
                label: prettyKeyLabel(entry.key),
                value: text,
                source: entry.source))
        }

        return VideoMetadataSnapshot(
            sourceURL: url,
            sections: sections.filter { !$0.fields.isEmpty },
            additionalFields: additional,
            location: location,
            unavailableSections: unavailable)
    }

    // MARK: File section

    private static func fileSection(for url: URL) -> VideoMetadataSection {
        var fields: [VideoMetadataField] = [
            VideoMetadataField(key: "name", label: "Name", value: url.lastPathComponent, source: "file"),
            VideoMetadataField(key: "container", label: "Format",
                               value: containerLabel(url.pathExtension), source: "file"),
        ]
        let keys: Set<URLResourceKey> = [.fileSizeKey, .creationDateKey, .contentModificationDateKey]
        if let res = try? url.resourceValues(forKeys: keys) {
            if let size = res.fileSize {
                fields.append(VideoMetadataField(
                    key: "size", label: "Size",
                    value: ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file),
                    source: "file"))
            }
            if let created = res.creationDate {
                fields.append(VideoMetadataField(
                    key: "fcreated", label: "File created", value: formatDate(created), source: "file"))
            }
            if let modified = res.contentModificationDate {
                fields.append(VideoMetadataField(
                    key: "fmodified", label: "File modified", value: formatDate(modified), source: "file"))
            }
        }
        // Full path is More-Details-level info; keep it at the end of the File card.
        fields.append(VideoMetadataField(key: "path", label: "Path", value: url.path, source: "file"))
        return VideoMetadataSection(title: "File", fields: fields)
    }

    private static func containerLabel(_ ext: String) -> String {
        switch ext.lowercased() {
        case "mp4": return "MPEG-4"
        case "mov": return "QuickTime"
        case "m4v": return "MPEG-4 Video"
        case "mkv": return "Matroska"
        default: return ext.isEmpty ? "Unknown" : ext.uppercased()
        }
    }

    // MARK: Value extraction

    private static func readableValue(for item: AVMetadataItem) async -> String? {
        if let s = try? await item.load(.stringValue) {
            let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let d = try? await item.load(.dateValue) {
            return formatDate(d)
        }
        if let n = try? await item.load(.numberValue) {
            return n.stringValue
        }
        return nil // binary payloads/artwork are intentionally skipped
    }

    private static func firstValue(
        in values: [(key: String, item: AVMetadataItem, source: String, text: String)],
        matching predicate: (String) -> Bool
    ) -> String? {
        values.first(where: { predicate($0.key.lowercased()) })?.text
    }

    private static func markConsumed(
        _ consumed: inout Set<String>,
        values: [(key: String, item: AVMetadataItem, source: String, text: String)],
        matching predicate: (String) -> Bool
    ) {
        for entry in values where predicate(entry.key.lowercased()) {
            consumed.insert("\(entry.source)|\(entry.key)")
        }
    }

    private static func formatSourceLabel(_ format: AVMetadataFormat) -> String {
        switch format {
        case .quickTimeMetadata: return "QuickTime"
        case .quickTimeUserData: return "QuickTime User Data"
        case .isoUserData: return "ISO"
        case .iTunes: return "iTunes"
        case .id3: return "ID3"
        case .hlsMetadata: return "HLS"
        default: return "Metadata"
        }
    }

    // MARK: Formatting helpers

    static func formatCoordinates(_ location: VideoLocation) -> String {
        String(format: "%.6f, %.6f", location.latitude, location.longitude)
    }

    static func formatFrameRate(_ fps: Float) -> String {
        var s = String(format: "%.2f", Double(fps))
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return "\(s) fps"
    }

    static func formatBitRate(_ bitsPerSecond: Double) -> String {
        if bitsPerSecond >= 1_000_000 {
            return String(format: "%.1f Mbps", bitsPerSecond / 1_000_000)
        }
        return String(format: "%.0f kbps", bitsPerSecond / 1_000)
    }

    private static func formatSampleRate(_ hz: Double) -> String {
        var s = String(format: "%.1f", hz / 1000)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return "\(s) kHz"
    }

    private static func channelLayout(_ channels: Int) -> String {
        switch channels {
        case 1: return "Mono"
        case 2: return "Stereo"
        case 6: return "5.1"
        case 8: return "7.1"
        default: return "\(channels) ch"
        }
    }

    static func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    static func codecLabel(_ subtype: FourCharCode) -> String {
        let raw = fourCCString(subtype)
        switch raw {
        case "avc1", "avc2", "avc3", "avc4": return "H.264"
        case "hvc1", "hev1": return "HEVC"
        case "av01": return "AV1"
        case "vp09", "vp08": return "VP9"
        case "mp4v": return "MPEG-4 Visual"
        case "mp4a": return "AAC"
        case "ac-3": return "AC-3"
        case "ec-3": return "E-AC-3"
        case "alac": return "ALAC"
        case "lpcm": return "LPCM"
        case "flac": return "FLAC"
        case "opus": return "Opus"
        case "jpeg", "mjpa", "mjpb": return "MJPEG"
        case "apch", "apcn", "apcs", "apco", "ap4h", "ap4x": return "ProRes"
        case "dvh1", "dvhe", "dvav": return "Dolby Vision"
        case "h263", "s263": return "H.263"
        case "twos", "sowt", "raw ", "NONE": return "PCM"
        default: return raw.isEmpty ? "Unknown" : raw
        }
    }

    static func fourCCString(_ code: FourCharCode) -> String {
        var result = ""
        for shift in stride(from: 24, through: 0, by: -8) {
            let byte = UInt8((code >> UInt32(shift)) & 0xFF)
            if byte >= 0x20, byte <= 0x7E {
                result.append(Character(UnicodeScalar(byte)))
            } else {
                result.append("?")
            }
        }
        return result
    }

    private static func encodedDimensions(_ fd: CMFormatDescription) -> (width: Int, height: Int)? {
        let dims = CMVideoFormatDescriptionGetDimensions(fd)
        guard dims.width > 0, dims.height > 0 else { return nil }
        return (Int(dims.width), Int(dims.height))
    }

    /// HDR color info from format-description extensions; nil when nothing is signaled.
    private static func colorDescription(_ fd: CMFormatDescription) -> String? {
        guard let extensions = CMFormatDescriptionGetExtensions(fd) as? [String: Any] else { return nil }
        let transfer = (extensions["TransferFunction"] as? String ?? "")
            .replacingOccurrences(of: " ", with: "_")
        let primaries = (extensions["ColorPrimaries"] as? String ?? "")
            .replacingOccurrences(of: " ", with: "_")
        if transfer.contains("2084") || transfer.contains("PQ") {
            return "HDR (PQ)"
        }
        if transfer.contains("HLG") || transfer.contains("2100") {
            return "HDR (HLG)"
        }
        if primaries.contains("2020") || primaries.contains("P3") {
            return "Wide color"
        }
        return nil
    }

    /// "com.apple.quicktime.camera.identifier" → "camera identifier" style labels.
    private static func prettyKeyLabel(_ rawKey: String) -> String {
        var tail = rawKey
        if let lastDot = rawKey.lastIndex(of: ".") {
            tail = String(rawKey[rawKey.index(after: lastDot)...])
        }
        tail = tail.replacingOccurrences(of: "_", with: " ")
        if tail.isEmpty { return rawKey }
        return tail.prefix(1).uppercased() + tail.dropFirst()
    }
}

// MARK: - Session (main-actor lifecycle + cancellation)

@MainActor
final class VideoMetadataSession {
    typealias Loader = @Sendable (URL) async throws -> VideoMetadataSnapshot

    enum State: Equatable {
        case idle
        case loading
        case ready(VideoMetadataSnapshot)
        case partial(VideoMetadataSnapshot, unavailable: [String])
        case unavailable(String)
    }

    var onChange: ((State) -> Void)?

    private let loader: Loader
    private var task: Task<Void, Never>?
    private var generation = 0
    private var source: URL?
    private var snapshot: VideoMetadataSnapshot?
    private var isVisible = false
    private(set) var state: State = .idle {
        didSet { onChange?(state) }
    }

    init(loader: @escaping Loader = { try await VideoMetadataReader.read($0) }) {
        self.loader = loader
    }

    /// New clip for this window. Hidden sessions do no extraction.
    func setSource(_ url: URL) {
        guard url != source else { return }
        source = url
        snapshot = nil
        cancelLoad()
        if isVisible {
            startLoad()
        } else if state != .idle {
            state = .idle
        }
    }

    func show() {
        isVisible = true
        if let snapshot, let source, snapshot.sourceURL == source {
            publish(snapshot)
            return
        }
        if task == nil { startLoad() }
    }

    func hide() {
        isVisible = false
        cancelLoad()
    }

    /// Final teardown — drops everything so the window can die.
    func invalidate() {
        isVisible = false
        cancelLoad()
        source = nil
        snapshot = nil
        if state != .idle { state = .idle }
    }

    private func cancelLoad() {
        generation += 1
        task?.cancel()
        task = nil
    }

    private func publish(_ snapshot: VideoMetadataSnapshot) {
        state = snapshot.unavailableSections.isEmpty
            ? .ready(snapshot)
            : .partial(snapshot, unavailable: snapshot.unavailableSections)
    }

    private func startLoad() {
        cancelLoad()
        guard let url = source else {
            state = .idle
            return
        }
        state = .loading
        let generationAtStart = generation
        let loader = self.loader
        task = Task.detached(priority: .utility) { [weak self] in
            let result: Result<VideoMetadataSnapshot, Error>
            do {
                result = .success(try await loader(url))
            } catch {
                result = .failure(error)
            }
            let cancelled = Task.isCancelled
            await MainActor.run { [weak self] in
                guard let self, self.generation == generationAtStart,
                      self.source == url, self.isVisible else { return }
                switch result {
                case .success(let snapshot):
                    self.snapshot = snapshot
                    self.publish(snapshot)
                case .failure(let error):
                    if cancelled || error is CancellationError { return }
                    self.state = .unavailable("Metadata could not be read for this file.")
                }
            }
        }
    }
}
