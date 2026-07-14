import Foundation

enum LaunchTargetAvailability: Sendable, Equatable {
    case exists
    case missing
    case inaccessible
}

struct LaunchTargetInspector: Sendable {
    static func availability(
        at path: String,
        fileManager: FileManager
    ) -> LaunchTargetAvailability {
        guard (path as NSString).isAbsolutePath else { return .inaccessible }

        do {
            _ = try fileManager.attributesOfItem(atPath: path)
            return .exists
        } catch {
            let nsError = error as NSError
            if isDefinitiveMissingError(nsError) {
                return .missing
            }
            return .inaccessible
        }
    }

    private static func isDefinitiveMissingError(_ error: NSError) -> Bool {
        if error.domain == NSCocoaErrorDomain,
           error.code == CocoaError.fileNoSuchFile.rawValue {
            return true
        }

        if error.domain == NSPOSIXErrorDomain,
           error.code == Int(ENOENT) || error.code == Int(ENOTDIR) {
            return true
        }

        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError {
            return isDefinitiveMissingError(underlying)
        }
        return false
    }
}
