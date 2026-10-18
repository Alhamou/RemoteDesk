import AppKit
import Foundation
import Network

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var options: Options

    private var window: NSWindow!
    private var hostController: HostController?
    private var clientController: ClientController?
    private var remoteView: RemoteView?

    // Launcher UI controls
    private var connectAddressField: NSTextField?
    private var statusLabel: NSTextField?
    private var bonjourPopup: NSPopUpButton?
    private var testPatternCheckbox: NSButton?
    private var discoveredEndpoints: [NWEndpoint] = []
    private var launcherBrowser: NWBrowser?

    init(options: Options) {
        self.options = options
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenu()
        createMainWindow()

        switch options.mode {
        case .host:
            transitionToHost(options: options)
        case .client:
            transitionToClient(options: options)
        case .launch, .selfTest:
            transitionToLauncher()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }

    // MARK: - Menu Setup

    private func setupMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        mainMenu.addItem(appMenuItem)

        let appMenu = NSMenu()
        let appName = ProcessInfo.processInfo.processName
        appMenu.addItem(withTitle: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthers)
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu

        let windowMenuItem = NSMenuItem()
        mainMenu.addItem(windowMenuItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.miniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.zoom(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Window Management

    private func createMainWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 380),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.delegate = self
        window.center()
    }

    private func setWindowSize(width: CGFloat, height: CGFloat, resizable: Bool) {
        if resizable {
            window.styleMask.insert(.resizable)
        } else {
            window.styleMask.remove(.resizable)
        }
        var frame = window.frame
        let originX = frame.origin.x + (frame.width - width) / 2
        let originY = frame.origin.y + (frame.height - height) / 2
        frame = NSRect(x: originX, y: originY, width: width, height: height)
        window.setFrame(frame, display: true, animate: true)
    }

    // MARK: - Launcher State

    private func transitionToLauncher() {
        launcherBrowser?.cancel()
        launcherBrowser = nil

        window.title = "RemoteDesk"
        setWindowSize(width: 500, height: 380, resizable: false)
        window.contentView = makeLauncherView()
        window.makeKeyAndOrderFront(nil)

        startBonjourDiscoveryForLauncher()
    }

    private func makeLauncherView() -> NSView {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 380))

        // Title Header
        let titleLabel = NSTextField(labelWithString: "RemoteDesk")
        titleLabel.font = NSFont.systemFont(ofSize: 24, weight: .bold)
        titleLabel.frame = NSRect(x: 30, y: 320, width: 440, height: 32)
        content.addSubview(titleLabel)

        let subLabel = NSTextField(labelWithString: "Mac-to-Mac High-Performance Remote Desktop")
        subLabel.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        subLabel.textColor = .secondaryLabelColor
        subLabel.frame = NSRect(x: 30, y: 295, width: 440, height: 20)
        content.addSubview(subLabel)

        // Separator
        let sep1 = NSBox(frame: NSRect(x: 30, y: 285, width: 440, height: 1))
        sep1.boxType = .separator
        content.addSubview(sep1)

        // --- Host Section ---
        let hostHeader = NSTextField(labelWithString: "Share This Mac")
        hostHeader.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        hostHeader.frame = NSRect(x: 30, y: 250, width: 200, height: 22)
        content.addSubview(hostHeader)

        let hostDesc = NSTextField(labelWithString: "Allow another Mac on your local network to connect and control this machine.")
        hostDesc.font = NSFont.systemFont(ofSize: 12)
        hostDesc.textColor = .secondaryLabelColor
        hostDesc.frame = NSRect(x: 30, y: 215, width: 440, height: 30)
        content.addSubview(hostDesc)

        let shareButton = NSButton(title: "Share This Mac", target: self, action: #selector(startHostClicked))
        shareButton.bezelStyle = .rounded
        shareButton.frame = NSRect(x: 30, y: 180, width: 140, height: 30)
        content.addSubview(shareButton)

        let testPatternCheck = NSButton(checkboxWithTitle: "Synthetic test pattern", target: nil, action: nil)
        testPatternCheck.frame = NSRect(x: 185, y: 184, width: 180, height: 20)
        content.addSubview(testPatternCheck)
        self.testPatternCheckbox = testPatternCheck

        // Separator
        let sep2 = NSBox(frame: NSRect(x: 30, y: 165, width: 440, height: 1))
        sep2.boxType = .separator
        content.addSubview(sep2)

        // --- Client Section ---
        let clientHeader = NSTextField(labelWithString: "Connect to a Mac")
        clientHeader.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        clientHeader.frame = NSRect(x: 30, y: 130, width: 200, height: 22)
        content.addSubview(clientHeader)

        let addrField = NSTextField(frame: NSRect(x: 30, y: 95, width: 280, height: 24))
        addrField.placeholderString = "Hostname or IP[:port], e.g. mini.local"
        content.addSubview(addrField)
        self.connectAddressField = addrField

        let connectButton = NSButton(title: "Connect", target: self, action: #selector(connectClicked))
        connectButton.bezelStyle = .rounded
        connectButton.frame = NSRect(x: 320, y: 91, width: 110, height: 30)
        content.addSubview(connectButton)

        // Bonjour Popup
        let bonjourLabel = NSTextField(labelWithString: "Discovered on LAN:")
        bonjourLabel.font = NSFont.systemFont(ofSize: 12)
        bonjourLabel.frame = NSRect(x: 30, y: 62, width: 130, height: 20)
        content.addSubview(bonjourLabel)

        let popup = NSPopUpButton(frame: NSRect(x: 160, y: 58, width: 270, height: 26), pullsDown: false)
        popup.addItem(withTitle: "Scanning for hosts...")
        popup.target = self
        popup.action = #selector(bonjourSelected(_:))
        content.addSubview(popup)
        self.bonjourPopup = popup

        // Status Label
        let status = NSTextField(labelWithString: "")
        status.font = NSFont.systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        status.frame = NSRect(x: 30, y: 15, width: 440, height: 20)
        content.addSubview(status)
        self.statusLabel = status

        return content
    }

    private func startBonjourDiscoveryForLauncher() {
        let descriptor = NWBrowser.Descriptor.bonjour(type: "_remotedesk._tcp", domain: nil)
        let browser = NWBrowser(for: descriptor, using: .tcp)
        self.launcherBrowser = browser

        browser.browseResultsChangedHandler = { [weak self] results, _ in
            DispatchQueue.main.async {
                guard let self, let popup = self.bonjourPopup else { return }
                popup.removeAllItems()
                self.discoveredEndpoints = []
                if results.isEmpty {
                    popup.addItem(withTitle: "No hosts found on LAN")
                } else {
                    for result in results {
                        switch result.endpoint {
                        case .service(let name, _, _, _):
                            popup.addItem(withTitle: name)
                        default:
                            popup.addItem(withTitle: "\(result.endpoint)")
                        }
                        self.discoveredEndpoints.append(result.endpoint)
                    }
                }
            }
        }
        browser.start(queue: .main)
    }

    private var selectedBonjourEndpoint: NWEndpoint?

    @objc private func bonjourSelected(_ sender: NSPopUpButton) {
        let index = sender.indexOfSelectedItem
        guard index >= 0, index < discoveredEndpoints.count else {
            selectedBonjourEndpoint = nil
            return
        }
        let endpoint = discoveredEndpoints[index]
        selectedBonjourEndpoint = endpoint
        switch endpoint {
        case .service(let name, _, _, _):
            connectAddressField?.stringValue = name
        default:
            connectAddressField?.stringValue = "\(endpoint)"
        }
    }

    @objc private func startHostClicked() {
        var opts = options
        opts.mode = .host
        if let check = testPatternCheckbox, check.state == .on {
            opts.useTestPattern = true
        }
        transitionToHost(options: opts)
    }

    @objc private func connectClicked() {
        let address = connectAddressField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !address.isEmpty else {
            statusLabel?.stringValue = "Please enter an address or select a discovered host."
            return
        }

        var opts = options
        opts.mode = .client

        if let endpoint = selectedBonjourEndpoint {
            if case .service(let name, _, _, _) = endpoint, name == address {
                transitionToClient(options: opts, targetEndpoint: endpoint)
                return
            }
        }

        if let colon = address.lastIndex(of: ":") {
            opts.connectHost = String(address[..<colon])
            opts.connectPort = UInt16(address[address.index(after: colon)...]) ?? 8790
        } else {
            opts.connectHost = address
            opts.connectPort = 8790
        }

        transitionToClient(options: opts, targetEndpoint: nil)
    }

    // MARK: - Host State

    private func transitionToHost(options: Options) {
        launcherBrowser?.cancel()
        launcherBrowser = nil

        let host = HostController(options: options)
        self.hostController = host

        host.onCaptureError = { [weak self] error in
            DispatchQueue.main.async {
                guard let self else { return }
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "Screen Recording Permission Required"
                alert.informativeText = "RemoteDesk needs Screen Recording permission to stream this Mac. Please enable RemoteDesk under System Settings → Privacy & Security → Screen Recording, then restart sharing."
                alert.addButton(withTitle: "Open System Settings")
                alert.addButton(withTitle: "OK")
                let response = alert.runModal()
                if response == .alertFirstButtonReturn {
                    self.openPermissions()
                }
            }
        }

        host.start()

        window.title = "RemoteDesk — Host"
        setWindowSize(width: 440, height: 260, resizable: false)
        window.contentView = makeHostView(options: options)
        window.makeKeyAndOrderFront(nil)
    }

    private func makeHostView(options: Options) -> NSView {
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 260))

        let iconLabel = NSTextField(labelWithString: "🖥️")
        iconLabel.font = NSFont.systemFont(ofSize: 40)
        iconLabel.frame = NSRect(x: 30, y: 175, width: 50, height: 50)
        content.addSubview(iconLabel)

        let titleLabel = NSTextField(labelWithString: "Screen Sharing Active")
        titleLabel.font = NSFont.systemFont(ofSize: 18, weight: .bold)
        titleLabel.frame = NSRect(x: 90, y: 195, width: 320, height: 24)
        content.addSubview(titleLabel)

        let modeText = options.useTestPattern ? " (Synthetic Pattern)" : ""
        let statusText = NSTextField(labelWithString: "Listening on port \(options.port)\(modeText)\nName: \(options.name)")
        statusText.font = NSFont.systemFont(ofSize: 13)
        statusText.textColor = .secondaryLabelColor
        statusText.frame = NSRect(x: 90, y: 145, width: 320, height: 40)
        content.addSubview(statusText)

        let permBtn = NSButton(title: "Permissions Settings...", target: self, action: #selector(openPermissions))
        permBtn.bezelStyle = .rounded
        permBtn.frame = NSRect(x: 90, y: 95, width: 170, height: 30)
        content.addSubview(permBtn)

        let stopBtn = NSButton(title: "Stop Sharing", target: self, action: #selector(stopHostClicked))
        stopBtn.bezelStyle = .rounded
        stopBtn.frame = NSRect(x: 90, y: 55, width: 130, height: 30)
        content.addSubview(stopBtn)

        return content
    }

    @objc private func openPermissions() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func stopHostClicked() {
        hostController?.stop()
        hostController = nil
        transitionToLauncher()
    }

    // MARK: - Client State

    private func transitionToClient(options: Options, targetEndpoint: NWEndpoint? = nil) {
        launcherBrowser?.cancel()
        launcherBrowser = nil

        let client = ClientController(options: options)
        client.targetEndpoint = targetEndpoint
        self.clientController = client

        window.title = "RemoteDesk — Connecting..."
        setWindowSize(width: 1280, height: 720, resizable: true)

        let view = RemoteView(frame: NSRect(x: 0, y: 0, width: 1280, height: 720))
        view.autoresizingMask = [.width, .height]
        view.controller = client
        view.onDisconnectRequested = { [weak self] in
            self?.disconnectClient()
        }
        window.contentView = view
        self.remoteView = view

        client.onConnected = { [weak self] width, height, hostName in
            DispatchQueue.main.async {
                guard let self else { return }
                self.window.title = "RemoteDesk — \(hostName) (\(width)x\(height)) [Ctrl+Opt+Cmd+Q to disconnect]"
                self.remoteView?.setVideoDimensions(width: Int(width), height: Int(height))
            }
        }

        client.onFrame = { [weak self] imageBuffer in
            self?.remoteView?.display(imageBuffer: imageBuffer)
        }

        client.onDisconnected = { [weak self] reason in
            DispatchQueue.main.async {
                guard let self else { return }
                let alert = NSAlert()
                alert.messageText = "Disconnected"
                alert.informativeText = reason
                alert.runModal()
                self.disconnectClient()
            }
        }

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        client.start()
    }

    private func disconnectClient() {
        clientController?.stop()
        clientController = nil
        remoteView = nil
        transitionToLauncher()
    }

    func windowWillClose(_ notification: Notification) {
        launcherBrowser?.cancel()
        launcherBrowser = nil
        hostController?.stop()
        hostController = nil
        clientController?.stop()
        clientController = nil
        NSApp.terminate(nil)
    }
}
