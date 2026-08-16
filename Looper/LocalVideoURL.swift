import Foundation

enum LocalVideoURL {
    /// Looper only plays files on disk. Network and custom-scheme URLs must not
    /// reach AVURLAsset (CWE-918).
    static func isPlayableFile(_ url: URL) -> Bool {
        url.isFileURL
    }

    static func onlyPlayableFiles(_ urls: [URL]) -> [URL] {
        urls.filter(isPlayableFile)
    }
}
