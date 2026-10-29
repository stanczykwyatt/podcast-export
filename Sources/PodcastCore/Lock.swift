import Foundation

/// An exclusive lock on a file, held while some work runs, so two exports into one folder, or
/// two reads of one scratch copy, never overlap. The lock file is left in place, empty, so there's
/// nothing to clean up afterward.
enum FileLock {
    /// Runs `body` holding the lock. With `wait` false, returns nil straight away if someone else
    /// holds it. Throws if the lock can't be taken for any other reason.
    static func run<T>(at url: URL, wait: Bool, _ body: () throws -> T) throws -> T? {
        let descriptor = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission, userInfo: [NSFilePathErrorKey: url.path]) }
        defer { close(descriptor) }
        guard flock(descriptor, LOCK_EX | (wait ? 0 : LOCK_NB)) == 0 else {
            // Someone else holding it is the one answer that means try later; anything else, like a
            // disk that can't lock files, is a failure of its own.
            let code = errno
            if !wait && code == EWOULDBLOCK { return nil }
            throw CocoaError(.fileLocking, userInfo: [NSFilePathErrorKey: url.path, NSUnderlyingErrorKey: POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)])
        }
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }
}
