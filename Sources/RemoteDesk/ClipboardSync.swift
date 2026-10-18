import AppKit

final class ClipboardSync {
    var onLocalChange: ((String) -> Void)?

    private let pasteboard = NSPasteboard.general
    private var timer: Timer?
    private var lastChangeCount = 0
    private var suppressChangeCount = -1

    func start() {
        guard timer == nil else { return }
        lastChangeCount = pasteboard.changeCount
        let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.poll()
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func applyRemote(_ text: String) {
        _ = pasteboard.clearContents()
        _ = pasteboard.setString(text, forType: .string)
        lastChangeCount = pasteboard.changeCount
        suppressChangeCount = lastChangeCount
    }

    private func poll() {
        let count = pasteboard.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count
        if count == suppressChangeCount {
            suppressChangeCount = -1
            return
        }
        guard let text = pasteboard.string(forType: .string) else { return }
        guard !text.isEmpty else { return }
        let byteCount = text.utf8.count
        guard byteCount <= 1_000_000 else {
            Log.warn("clipboard text too large: \(byteCount) bytes")
            return
        }
        onLocalChange?(text)
    }
}
