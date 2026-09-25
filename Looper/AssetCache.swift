import AppKit
import AVFoundation
import CoreMedia
import Foundation

/// Aggressive warm cache tuned for high-RAM Apple Silicon (keep assets hot across opens).
enum AssetCache {
    nonisolated(unsafe) static var defaults = UserDefaults.standard
    static let sizeDefaultsKey = "Looper.nativeSizes"

    private static let loadLock = NSLock()
    private nonisolated(unsafe) static var loadTasks: [String: [UUID: Task<Void, Never>]] = [:]

    private nonisolated(unsafe) static let cache: NSCache<NSString, AVURLAsset> = {
        let c = NSCache<NSString, AVURLAsset>()
        c.countLimit = 128
        c.totalCostLimit = 1_024 * 1_024 * 1_024 // ~1GB soft budget across entries
        return c
    }()

    private nonisolated(unsafe) static let sizeCache = NSCache<NSString, NSValue>()
    private nonisolated(unsafe) static let fpsCache = NSCache<NSString, NSNumber>()
    private nonisolated(unsafe) static let hdrCache = NSCache<NSString, NSNumber>()

    static func cacheKey(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    static func cancelLoads(for url: URL) {
        cancelLoads(forKey: cacheKey(for: url))
    }

    static func cancelAllLoads() {
        loadLock.lock()
        let all = loadTasks
        loadTasks.removeAll()
        loadLock.unlock()
        for tasks in all.values {
            for task in tasks.values {
                task.cancel()
            }
        }
    }

    private static func cancelLoads(forKey key: String) {
        loadLock.lock()
        let tasks = loadTasks.removeValue(forKey: key) ?? [:]
        loadLock.unlock()
        for task in tasks.values {
            task.cancel()
        }
    }

    @discardableResult
    private static func runLoad(
        for url: URL,
        priority: TaskPriority,
        operation: @escaping @Sendable () async -> Void
    ) -> UUID {
        let key = cacheKey(for: url)
        let id = UUID()
        let task = Task.detached(priority: priority) {
            await operation()
            AssetCache.finishLoad(key: key, id: id)
        }
        loadLock.lock()
        loadTasks[key, default: [:]][id] = task
        loadLock.unlock()
        return id
    }

    private static func finishLoad(key: String, id: UUID) {
        loadLock.lock()
        loadTasks[key]?[id] = nil
        if loadTasks[key]?.isEmpty == true {
            loadTasks.removeValue(forKey: key)
        }
        loadLock.unlock()
    }

    static func asset(for url: URL) -> AVURLAsset {
        precondition(url.isFileURL, "Looper only opens local files")
        let key = url.standardizedFileURL.path as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let asset = AVURLAsset(
            url: url,
            options: [AVURLAssetPreferPreciseDurationAndTimingKey: true]
        )
        cache.setObject(asset, forKey: key, cost: 8 * 1_024 * 1_024)
        return asset
    }

    static func cachedNativeSize(for url: URL) -> CGSize? {
        let key = url.standardizedFileURL.path as NSString
        if let value = sizeCache.object(forKey: key) {
            return value.sizeValue
        }
        guard
            let dict = defaults.dictionary(forKey: sizeDefaultsKey) as? [String: String],
            let raw = dict[url.standardizedFileURL.path]
        else { return nil }
        let parts = raw.split(separator: "x")
        guard parts.count == 2,
              let w = Double(parts[0]),
              let h = Double(parts[1]),
              w > 1, h > 1
        else { return nil }
        let size = CGSize(width: w, height: h)
        sizeCache.setObject(NSValue(size: size), forKey: key)
        return size
    }

    static func storeNativeSize(_ size: CGSize, for url: URL) {
        guard size.width > 1, size.height > 1 else { return }
        let key = url.standardizedFileURL.path as NSString
        sizeCache.setObject(NSValue(size: size), forKey: key)
        var dict = (defaults.dictionary(forKey: sizeDefaultsKey) as? [String: String]) ?? [:]
        dict[url.standardizedFileURL.path] = "\(Int(size.width))x\(Int(size.height))"
        // Cap persisted map so it doesn't grow forever.
        if dict.count > 400 {
            dict = Dictionary(uniqueKeysWithValues: dict.suffix(300))
        }
        defaults.set(dict, forKey: sizeDefaultsKey)
    }

    /// Fire-and-forget warm of playable + tracks + duration + size.
    static func preload(_ url: URL) {
        guard url.isFileURL else { return }
        let asset = asset(for: url)
        runLoad(for: url, priority: .userInitiated) {
            if Task.isCancelled { return }
            _ = try? await asset.load(.isPlayable, .tracks, .duration)
            if Task.isCancelled { return }
            if cachedNativeSize(for: url) == nil {
                loadNativeSize(url) { _ in }
            }
        }
    }

    /// Fast path: return as soon as the file is playable (don't wait on duration).
    static func loadPlayable(_ url: URL, completion: @escaping @MainActor @Sendable (AVURLAsset, Error?) -> Void) {
        guard url.isFileURL else {
            let error = NSError(
                domain: "Looper",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Only local video files can be opened"]
            )
            DispatchQueue.main.async {
                completion(AVURLAsset(url: URL(fileURLWithPath: "/dev/null")), error)
            }
            return
        }
        let asset = asset(for: url)
        runLoad(for: url, priority: .userInitiated) {
            do {
                if Task.isCancelled { return }
                let playable = try await asset.load(.isPlayable)
                if Task.isCancelled { return }
                _ = try await asset.load(.tracks)
                if Task.isCancelled { return }
                let error: Error? = playable ? nil : NSError(
                    domain: "Looper",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Asset not playable"]
                )
                await MainActor.run { completion(asset, error) }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run { completion(asset, error) }
            }
        }
    }

    static func loadDuration(_ url: URL, completion: @escaping @MainActor @Sendable (Double) -> Void) {
        guard url.isFileURL else {
            DispatchQueue.main.async { completion(0) }
            return
        }
        let asset = asset(for: url)
        runLoad(for: url, priority: .utility) {
            if Task.isCancelled { return }
            let duration = (try? await asset.load(.duration)) ?? .zero
            if Task.isCancelled { return }
            let seconds = duration.seconds.isFinite ? duration.seconds : 0
            await MainActor.run { completion(seconds) }
        }
    }

    /// Native pixel size after preferredTransform (rotation-aware).
    static func loadNativeSize(_ url: URL, completion: @escaping @MainActor @Sendable (CGSize?) -> Void) {
        guard url.isFileURL else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        if let cached = cachedNativeSize(for: url) {
            DispatchQueue.main.async { completion(cached) }
            return
        }

        let asset = asset(for: url)
        runLoad(for: url, priority: .userInitiated) {
            do {
                if Task.isCancelled { return }
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard let track = tracks.first else {
                    if Task.isCancelled { return }
                    await MainActor.run { completion(nil) }
                    return
                }
                let nat = try await track.load(.naturalSize)
                let transform = try await track.load(.preferredTransform)
                if Task.isCancelled { return }
                let rect = CGRect(origin: .zero, size: nat).applying(transform)
                let size = CGSize(width: abs(rect.width), height: abs(rect.height))
                let valid = size.width > 1 && size.height > 1 ? size : nil
                if let valid {
                    storeNativeSize(valid, for: url)
                }
                if Task.isCancelled { return }
                await MainActor.run { completion(valid) }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run { completion(nil) }
            }
        }
    }

    /// Video track nominal frame rate (e.g. 24, 29.97, 30, 60).
    static func loadFrameRate(_ url: URL, completion: @escaping @MainActor @Sendable (Float?) -> Void) {
        guard url.isFileURL else {
            DispatchQueue.main.async { completion(nil) }
            return
        }
        if let cached = fpsCache.object(forKey: url.standardizedFileURL.path as NSString) {
            DispatchQueue.main.async { completion(cached.floatValue) }
            return
        }

        let asset = asset(for: url)
        runLoad(for: url, priority: .userInitiated) {
            do {
                if Task.isCancelled { return }
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard let track = tracks.first else {
                    if Task.isCancelled { return }
                    await MainActor.run { completion(nil) }
                    return
                }
                let rate = try await track.load(.nominalFrameRate)
                let valid = rate > 1 ? rate : nil
                if let valid {
                    fpsCache.setObject(NSNumber(value: valid), forKey: url.standardizedFileURL.path as NSString)
                }
                if Task.isCancelled { return }
                await MainActor.run { completion(valid) }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run { completion(nil) }
            }
        }
    }

    /// True when the video track is HDR (PQ / HLG / Dolby Vision). Unknown → false (SDR).
    static func loadContainsHDR(_ url: URL, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        guard url.isFileURL else {
            DispatchQueue.main.async { completion(false) }
            return
        }
        if let cached = hdrCache.object(forKey: url.standardizedFileURL.path as NSString) {
            DispatchQueue.main.async { completion(cached.boolValue) }
            return
        }

        let asset = asset(for: url)
        runLoad(for: url, priority: .userInitiated) {
            if Task.isCancelled { return }
            let hdr = await isHDR(asset)
            if Task.isCancelled { return }
            hdrCache.setObject(NSNumber(value: hdr), forKey: url.standardizedFileURL.path as NSString)
            await MainActor.run { completion(hdr) }
        }
    }

    private static func isHDR(_ asset: AVURLAsset) async -> Bool {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            return false
        }
        let characteristics = (try? await track.load(.mediaCharacteristics)) ?? []
        if characteristics.contains(.containsHDRVideo) {
            return true
        }
        let formats = (try? await track.load(.formatDescriptions)) ?? []
        return formats.contains { formatIsHDR($0) }
    }

    private static func formatIsHDR(_ desc: CMFormatDescription) -> Bool {
        guard let raw = CMFormatDescriptionGetExtension(
            desc,
            extensionKey: kCMFormatDescriptionExtension_TransferFunction
        ) as? String else {
            return false
        }
        return raw == (kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ as String)
            || raw == (kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG as String)
    }
}
