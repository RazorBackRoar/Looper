import AppKit
import AVFoundation
import CoreMedia
import Foundation

/// Aggressive warm cache tuned for high-RAM Apple Silicon (keep assets hot across opens).
enum AssetCache {
    private static let cache: NSCache<NSString, AVURLAsset> = {
        let c = NSCache<NSString, AVURLAsset>()
        c.countLimit = 128
        c.totalCostLimit = 1_024 * 1_024 * 1_024 // ~1GB soft budget across entries
        return c
    }()

    private static let posterCache: NSCache<NSString, NSImage> = {
        let c = NSCache<NSString, NSImage>()
        c.countLimit = 64
        return c
    }()

    private static let sizeCache = NSCache<NSString, NSValue>()
    private static let fpsCache = NSCache<NSString, NSNumber>()
    private static let hdrCache = NSCache<NSString, NSNumber>()
    private static let sizeDefaultsKey = "Looper.nativeSizes"

    static func asset(for url: URL) -> AVURLAsset {
        let key = url.path as NSString
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

    static func cachedPoster(for url: URL) -> NSImage? {
        posterCache.object(forKey: url.path as NSString)
    }

    static func storePoster(_ image: NSImage, for url: URL) {
        posterCache.setObject(image, forKey: url.path as NSString)
    }

    static func cachedNativeSize(for url: URL) -> CGSize? {
        let key = url.path as NSString
        if let value = sizeCache.object(forKey: key) {
            return value.sizeValue
        }
        guard
            let dict = UserDefaults.standard.dictionary(forKey: sizeDefaultsKey) as? [String: String],
            let raw = dict[url.path]
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
        let key = url.path as NSString
        sizeCache.setObject(NSValue(size: size), forKey: key)
        var dict = (UserDefaults.standard.dictionary(forKey: sizeDefaultsKey) as? [String: String]) ?? [:]
        dict[url.path] = "\(Int(size.width))x\(Int(size.height))"
        // Cap persisted map so it doesn't grow forever.
        if dict.count > 400 {
            dict = Dictionary(uniqueKeysWithValues: dict.suffix(300))
        }
        UserDefaults.standard.set(dict, forKey: sizeDefaultsKey)
    }

    /// Fire-and-forget warm of playable + tracks + duration + size.
    static func preload(_ url: URL) {
        let asset = asset(for: url)
        Task.detached(priority: .userInitiated) {
            _ = try? await asset.load(.isPlayable, .tracks, .duration)
            if cachedNativeSize(for: url) == nil {
                loadNativeSize(url) { _ in }
            }
        }
    }

    /// Fast path: return as soon as the file is playable (don't wait on duration).
    static func loadPlayable(_ url: URL, completion: @escaping (AVURLAsset, Error?) -> Void) {
        let asset = asset(for: url)
        Task.detached(priority: .userInitiated) {
            do {
                let playable = try await asset.load(.isPlayable)
                _ = try await asset.load(.tracks)
                let error: Error? = playable ? nil : NSError(
                    domain: "Looper",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Asset not playable"]
                )
                await MainActor.run { completion(asset, error) }
            } catch {
                await MainActor.run { completion(asset, error) }
            }
        }
    }

    static func loadDuration(_ url: URL, completion: @escaping (Double) -> Void) {
        let asset = asset(for: url)
        Task.detached(priority: .utility) {
            let duration = (try? await asset.load(.duration)) ?? .zero
            let seconds = duration.seconds.isFinite ? duration.seconds : 0
            await MainActor.run { completion(seconds) }
        }
    }

    /// Native pixel size after preferredTransform (rotation-aware).
    static func loadNativeSize(_ url: URL, completion: @escaping (CGSize?) -> Void) {
        if let cached = cachedNativeSize(for: url) {
            DispatchQueue.main.async { completion(cached) }
            return
        }

        let asset = asset(for: url)
        Task.detached(priority: .userInitiated) {
            do {
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard let track = tracks.first else {
                    await MainActor.run { completion(nil) }
                    return
                }
                let nat = try await track.load(.naturalSize)
                let transform = try await track.load(.preferredTransform)
                let rect = CGRect(origin: .zero, size: nat).applying(transform)
                let size = CGSize(width: abs(rect.width), height: abs(rect.height))
                let valid = size.width > 1 && size.height > 1 ? size : nil
                if let valid {
                    storeNativeSize(valid, for: url)
                }
                await MainActor.run { completion(valid) }
            } catch {
                await MainActor.run { completion(nil) }
            }
        }
    }

    /// Video track nominal frame rate (e.g. 24, 29.97, 30, 60).
    static func loadFrameRate(_ url: URL, completion: @escaping (Float?) -> Void) {
        if let cached = fpsCache.object(forKey: url.path as NSString) {
            DispatchQueue.main.async { completion(cached.floatValue) }
            return
        }

        let asset = asset(for: url)
        Task.detached(priority: .userInitiated) {
            do {
                let tracks = try await asset.loadTracks(withMediaType: .video)
                guard let track = tracks.first else {
                    await MainActor.run { completion(nil) }
                    return
                }
                let rate = try await track.load(.nominalFrameRate)
                let valid = rate > 1 ? rate : nil
                if let valid {
                    fpsCache.setObject(NSNumber(value: valid), forKey: url.path as NSString)
                }
                await MainActor.run { completion(valid) }
            } catch {
                await MainActor.run { completion(nil) }
            }
        }
    }

    /// True when the video track is HDR (PQ / HLG / Dolby Vision). Unknown → false (SDR).
    static func loadContainsHDR(_ url: URL, completion: @escaping (Bool) -> Void) {
        if let cached = hdrCache.object(forKey: url.path as NSString) {
            DispatchQueue.main.async { completion(cached.boolValue) }
            return
        }

        let asset = asset(for: url)
        Task.detached(priority: .userInitiated) {
            let hdr = await isHDR(asset)
            hdrCache.setObject(NSNumber(value: hdr), forKey: url.path as NSString)
            await MainActor.run { completion(hdr) }
        }
    }

    private static func isHDR(_ asset: AVURLAsset) async -> Bool {
        guard let track = try? await asset.loadTracks(withMediaType: .video).first else {
            return false
        }
        if track.hasMediaCharacteristic(.containsHDRVideo) {
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
