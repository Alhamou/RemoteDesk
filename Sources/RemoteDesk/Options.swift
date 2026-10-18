import Foundation

enum RunMode {
    case launch
    case host
    case client
    case selfTest
    case gestureProbe
}

struct Options {
    var mode: RunMode = .launch
    var port: UInt16 = 8790
    var useTestPattern = false
    var noUI = false
    var expectFrames = 0
    var connectHost: String?
    var connectPort: UInt16 = 8790
    var browse = false
    var timeoutSeconds: Double = 30
    var maxDimension = 2560
    var fps = 60
    var bitrate = 8_000_000
        var name = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    var testPatternSize: (width: Int, height: Int)?
    var verbose = false
    var probeSeconds: Double = 20

    static let usage = """
    Usage: RemoteDesk [options]

    Modes:
      --host                  Share this Mac's screen
      --client                Connect to another Mac
      --self-test             Run offline self-tests and exit
      --gesture-probe SECONDS Log raw gesture events (type 29) for debugging

    Options:
      --port N                TCP port to listen on (default 8790)
      --connect HOST[:PORT]   Connect directly instead of browsing (client)
      --browse                Browse Bonjour for hosts (client)
      --test-pattern          Use a synthetic pattern instead of screen capture (host)
      --size WxH              Test pattern size (default 1280x720)
      --no-ui, --headless     Run without UI
      --expect-frames N       Headless: exit OK after N decoded frames (client)
      --timeout SECONDS       Headless client timeout (default 30)
      --fps N                 Capture frame rate, 1-120 (default 60)
      --bitrate N             Average bitrate in bits/s (default 8000000)
      --max-dim N             Cap capture dimension (default 2560)
      --name NAME             Display name for this host
      --verbose               Verbose logging to stderr
      --help                  Show this help
    """

    static func parse(_ arguments: [String]) -> Options {
        var options = Options()
        let args = Array(arguments)
        var i = 0

        func fail(_ message: String) -> Never {
            FileHandle.standardError.write(Data("error: \(message)\n\n\(usage)\n".utf8))
            exit(2)
        }

        func nextValue(_ flag: String) -> String {
            i += 1
            guard i < args.count else { fail("\(flag) requires a value") }
            return args[i]
        }

        while i < args.count {
            let arg = args[i]
            switch arg {
            case "--host":
                options.mode = .host
            case "--client":
                options.mode = .client
            case "--self-test":
                options.mode = .selfTest
            case "--gesture-probe":
                let value = nextValue("--gesture-probe")
                guard let parsed = Double(value), parsed > 0, parsed <= 300 else {
                    fail("invalid --gesture-probe value '\(value)' (seconds, 1-300)")
                }
                options.probeSeconds = parsed
                options.mode = .gestureProbe
            case "--port":
                let value = nextValue("--port")
                guard let parsed = UInt16(value), parsed > 0 else {
                    fail("invalid --port value '\(value)'")
                }
                options.port = parsed
            case "--test-pattern":
                options.useTestPattern = true
            case "--no-ui", "--headless":
                options.noUI = true
            case "--expect-frames":
                let value = nextValue("--expect-frames")
                guard let parsed = Int(value), parsed > 0 else {
                    fail("invalid --expect-frames value '\(value)'")
                }
                options.expectFrames = parsed
            case "--connect":
                let value = nextValue("--connect")
                if let colon = value.lastIndex(of: ":") {
                    let host = String(value[..<colon])
                    let portString = String(value[value.index(after: colon)...])
                    guard !host.isEmpty, let parsed = UInt16(portString), parsed > 0 else {
                        fail("invalid --connect value '\(value)'")
                    }
                    options.connectHost = host
                    options.connectPort = parsed
                } else {
                    guard !value.isEmpty else { fail("invalid --connect value '\(value)'") }
                    options.connectHost = value
                }
            case "--browse":
                options.browse = true
            case "--timeout":
                let value = nextValue("--timeout")
                guard let parsed = Double(value), parsed > 0 else {
                    fail("invalid --timeout value '\(value)'")
                }
                options.timeoutSeconds = parsed
            case "--max-dim":
                let value = nextValue("--max-dim")
                guard let parsed = Int(value), parsed >= 2 else {
                    fail("invalid --max-dim value '\(value)'")
                }
                options.maxDimension = parsed
            case "--fps":
                let value = nextValue("--fps")
                guard let parsed = Int(value), parsed >= 1, parsed <= 120 else {
                    fail("invalid --fps value '\(value)'")
                }
                options.fps = parsed
            case "--bitrate":
                let value = nextValue("--bitrate")
                guard let parsed = Int(value), parsed >= 100_000 else {
                    fail("invalid --bitrate value '\(value)'")
                }
                options.bitrate = parsed
            case "--name":
                let value = nextValue("--name")
                guard !value.isEmpty else { fail("invalid --name value '\(value)'") }
                options.name = value
            case "--size":
                let value = nextValue("--size")
                let parts = value.lowercased().split(separator: "x")
                guard parts.count == 2,
                      let width = Int(parts[0]), let height = Int(parts[1]),
                      width >= 2, height >= 2 else {
                    fail("invalid --size value '\(value)' (expected WxH)")
                }
                options.testPatternSize = (width, height)
            case "--verbose":
                options.verbose = true
            case "--help", "-h":
                print(usage)
                exit(0)
            default:
                fail("unknown argument '\(arg)'")
            }
            i += 1
        }

        if options.noUI && options.mode == .launch {
            fail("--no-ui requires --host, --client, or --self-test")
        }
        if options.browse && options.connectHost != nil {
            fail("--browse and --connect are mutually exclusive")
        }
        return options
    }
}
