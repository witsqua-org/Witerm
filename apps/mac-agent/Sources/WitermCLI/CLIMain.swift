import Darwin
import Foundation

@main
enum WitermCLIMain {
    static func main() async {
        signal(SIGPIPE, SIG_IGN)
        let arguments = Array(CommandLine.arguments.dropFirst())
        var json = arguments.contains("--json")
        do {
            let invocation = try CLIParser.parse(arguments)
            json = invocation.json
            let result = try await CLIRunner(invocation: invocation, environment: ProcessInfo.processInfo.environment).run()
            exit(result.rawValue)
        } catch {
            let failure = CLIRunner.failure(error)
            if json {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.sortedKeys]
                let body = ErrorJSON(error: .init(code: failure.code, message: failure.message, exit: failure.exit.rawValue))
                if let data = try? encoder.encode(body) { CLIOutput.standardError.write(data + Data("\n".utf8)) }
            } else {
                CLIOutput.standardError.write(Data("witerm: \(failure.message)\n".utf8))
            }
            exit(failure.exit.rawValue)
        }
    }
}
