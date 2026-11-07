import Foundation

/// A folder or file the OS won't let us read, explained in terms the model
/// (and the person reading the transcript) can act on.
public struct FileAccessError: Error, LocalizedError {
    public var url: URL
    public var underlying: Error

    public init(url: URL, underlying: Error) {
        self.url = url
        self.underlying = underlying
    }

    public var isPermissionDenied: Bool {
        FileAccess.isPermissionError(underlying)
    }

    public var errorDescription: String? {
        if isPermissionDenied {
            return FileAccess.permissionAdvice(for: url)
        }
        let nsError = underlying as NSError
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoSuchFileError
            || nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOENT) {
            return "\(url.path) doesn't exist."
        }
        return "Couldn't read \(url.path): \(underlying.localizedDescription)"
    }
}

public enum FileAccess {
    /// True when running inside the macOS App Sandbox.
    public static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil
    }

    static func isPermissionError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileReadNoPermissionError { return true }
        if nsError.domain == NSPOSIXErrorDomain && (nsError.code == Int(EPERM) || nsError.code == Int(EACCES)) { return true }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? Error { return isPermissionError(underlying) }
        return false
    }

    public static func permissionAdvice(for url: URL) -> String {
        if isSandboxed {
            return "macOS blocked access to \(url.path): Apeiron is running in the App Sandbox, which hides folders outside its container. Turn off App Sandbox for the Apeiron target (Signing & Capabilities in Xcode) and rebuild."
        }
        return "macOS blocked access to \(url.path) (privacy protection for Desktop, Documents, Downloads and external drives). Allow Apeiron in System Settings → Privacy & Security → Files and Folders (or Full Disk Access), then try again."
    }

    /// macOS can show a privacy-protected or cloud-synced folder as empty
    /// instead of refusing outright. Returns advice when that's likely.
    public static func emptyListingHint(for url: URL) -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let protected = ["Desktop", "Documents", "Downloads", "Library/Mobile Documents", "Library/CloudStorage"]
            .map { home + "/" + $0 }
        guard protected.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) || path.hasPrefix("/Volumes/") else {
            return nil
        }
        return "  Note: this folder is protected by macOS privacy settings or synced from the cloud, so an empty listing may mean access is blocked. " + permissionAdvice(for: url)
    }

    /// Checks a workspace is readable. Returns advice when it isn't.
    /// Reading it is also what makes macOS show its permission prompt.
    public static func checkReadable(_ url: URL) -> String? {
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: url.resolvingSymlinksInPath().path)
            return nil
        } catch {
            return FileAccessError(url: url, underlying: error).errorDescription
        }
    }
}
