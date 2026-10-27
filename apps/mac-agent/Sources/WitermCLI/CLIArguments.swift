import Foundation

enum CLICommand: Equatable {
    case help
    case version
    case status
    case sessions
    case new(name: String?, share: Bool, detach: Bool)
    case share(session: String?, wait: Double?)
    case unshare(session: String?)
    case rename(session: String, name: String)
    case attach(session: String, view: Bool)
}

struct CLIInvocation: Equatable {
    var command: CLICommand
    var json = false
    var socket: String?
    /// The escape character that starts `~.` and friends; nil disables escapes.
    var escape: UInt8? = UInt8(ascii: "~")
}

/// Stable process exit codes. Scripts may rely on these values.
enum CLIExit: Int32 {
    case success = 0
    case failure = 1
    case usage = 2
    case serviceUnavailable = 3
    case notFound = 4
    case busy = 5
    case tmuxMissing = 6
    case remoteNotReady = 7
}

struct CLIFailure: Error, Equatable {
    let exit: CLIExit
    /// Stable machine-readable code for `--json` output.
    let code: String
    let message: String

    static func usage(_ message: String) -> CLIFailure {
        CLIFailure(exit: .usage, code: "usage", message: message)
    }
}

enum CLIParser {
    static let usage = """
    Usage: witerm <command> [options]

    Commands:
      new [--name <name>] [--share] [--detach]
                        Start a session in the current directory and attach to it
      share [<session>] [--wait <seconds>]
                        Let paired devices reach a session (default: the one you're in)
      unshare [<session>]
                        Stop sharing; paired devices disconnect, the session keeps running
      rename <session> <name>
                        Rename a session; attached viewers and the shell are unaffected
      sessions          List sessions, their sharing state, and who is attached
      attach <session> [--view]
                        Attach to a session (control by default)
      status            Show the background service and remote access state
      version           Show the version

    Options:
      --json            Machine-readable output (never attaches)
      --socket <path>   Use this service socket instead of the installed app's
      --escape <c|none> Escape character while attached (default ~)

    While attached, press Enter then ~. to detach, or ~? for help.
    A session is named by its ID, a unique ID prefix, or its exact name.
    """

    static func parse(_ arguments: [String]) throws -> CLIInvocation {
        var positionals: [String] = []
        var flags: Set<String> = []
        var values: [String: String] = [:]
        var iterator = arguments.makeIterator()
        let valued: Set<String> = ["--name", "--wait", "--socket", "--escape"]
        let known: Set<String> = ["--json", "--share", "--detach", "--view", "--help", "-h", "--version"]
        while let argument = iterator.next() {
            if valued.contains(argument) {
                guard values[argument] == nil, let value = iterator.next() else {
                    throw CLIFailure.usage("\(argument) needs a value.")
                }
                values[argument] = value
            } else if known.contains(argument) {
                flags.insert(argument)
            } else if argument.hasPrefix("-") {
                throw CLIFailure.usage("Unknown option \(argument).")
            } else {
                positionals.append(argument)
            }
        }
        if flags.contains("--help") || flags.contains("-h") { return CLIInvocation(command: .help) }
        if flags.contains("--version") { return CLIInvocation(command: .version) }

        let name = positionals.first ?? "help"
        let rest = Array(positionals.dropFirst())
        let command: CLICommand
        var allowedFlags: Set<String> = ["--json"]
        var allowedValues: Set<String> = ["--socket"]
        switch name {
        case "help":
            command = .help
        case "version":
            command = .version
        case "status":
            command = .status
        case "sessions", "ls", "list":
            command = .sessions
        case "new":
            allowedFlags.formUnion(["--share", "--detach"])
            allowedValues.formUnion(["--name", "--escape"])
            command = .new(name: values["--name"], share: flags.contains("--share"), detach: flags.contains("--detach"))
        case "share":
            allowedValues.insert("--wait")
            var wait: Double?
            if let raw = values["--wait"] {
                guard let seconds = Double(raw), seconds > 0, seconds <= 300 else {
                    throw CLIFailure.usage("--wait takes a number of seconds from 1 to 300.")
                }
                wait = seconds
            }
            command = .share(session: rest.first, wait: wait)
        case "unshare":
            command = .unshare(session: rest.first)
        case "rename":
            guard rest.count == 2 else { throw CLIFailure.usage("Name the session and its new name.") }
            command = .rename(session: rest[0], name: rest[1])
        case "attach":
            allowedFlags.insert("--view")
            allowedValues.insert("--escape")
            guard let session = rest.first else { throw CLIFailure.usage("Name the session to attach to.") }
            command = .attach(session: session, view: flags.contains("--view"))
        default:
            throw CLIFailure.usage("Unknown command \(name). Run witerm help.")
        }
        let maxPositionals = name == "rename" ? 3 : ["share", "unshare", "attach"].contains(name) ? 2 : 1
        guard positionals.count <= maxPositionals else { throw CLIFailure.usage("Too many arguments.") }
        if let extra = flags.subtracting(allowedFlags).sorted().first {
            throw CLIFailure.usage("\(extra) doesn't apply to \(name).")
        }
        if let extra = Set(values.keys).subtracting(allowedValues).sorted().first {
            throw CLIFailure.usage("\(extra) doesn't apply to \(name).")
        }
        var invocation = CLIInvocation(command: command, json: flags.contains("--json"), socket: values["--socket"])
        if let raw = values["--escape"] {
            if raw == "none" {
                invocation.escape = nil
            } else if raw.utf8.count == 1, let byte = raw.utf8.first, byte >= 0x21, byte < 0x7F {
                invocation.escape = byte
            } else {
                throw CLIFailure.usage("--escape takes one printable character or none.")
            }
        }
        return invocation
    }
}
