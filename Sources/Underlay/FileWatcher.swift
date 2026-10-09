import Foundation

/// Watches a file and its parent directory and calls `onChange` (debounced) when either changes.
///
/// The directory source catches atomic saves (write temp file + rename) and newly created files;
/// the file source catches in-place writes. The file source is re-armed after every change
/// because an atomic save replaces the inode it was watching.
@MainActor
final class FileWatcher {
    private let fileURL: URL
    private let debounce: TimeInterval
    private let onChange: () -> Void
    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var pending: DispatchWorkItem?

    init(fileURL: URL, debounce: TimeInterval = 0.3, onChange: @escaping () -> Void) {
        self.fileURL = fileURL
        self.debounce = debounce
        self.onChange = onChange
        directorySource = makeSource(for: fileURL.deletingLastPathComponent())
        fileSource = makeSource(for: fileURL)
    }

    func stop() {
        pending?.cancel()
        directorySource?.cancel()
        fileSource?.cancel()
        directorySource = nil
        fileSource = nil
    }

    private func makeSource(for url: URL) -> DispatchSourceFileSystemObject? {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .delete, .rename, .attrib],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.scheduleChange() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        return source
    }

    private func scheduleChange() {
        pending?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.fire() }
        }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + debounce, execute: item)
    }

    private func fire() {
        fileSource?.cancel()
        fileSource = makeSource(for: fileURL)
        onChange()
    }
}
