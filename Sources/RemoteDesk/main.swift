import AppKit
import Foundation

let options = Options.parse(Array(CommandLine.arguments.dropFirst()))
Log.verbose = options.verbose

switch options.mode {
case .selfTest:
    SelfTest.run()

case .gestureProbe:
    GestureProbe.run(seconds: options.probeSeconds)

case .host:
    if options.noUI {
        let host = HostController(options: options)
        host.start()
        dispatchMain()
    } else {
        runApp(options: options)
    }

case .client:
    if options.noUI {
        let client = ClientController(options: options)
        client.start()
        dispatchMain()
    } else {
        runApp(options: options)
    }

case .launch:
    runApp(options: options)
}

func runApp(options: Options) {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = AppDelegate(options: options)
    app.delegate = delegate
    app.run()
}
