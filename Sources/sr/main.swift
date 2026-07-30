import Foundation
import SoftReturnCLI

// The whole executable: bind the real filesystem and the real streams, run, exit. Every
// decision worth testing lives in SoftReturnCLI, where a test can call it without spawning
// a process.

let environment = CLIEnvironment(
    readFile: { path in
        // `Data(contentsOf:)` and not `FileManager.contents(atPath:)`: the latter returns nil
        // for every failure, so the error message could only ever be "failed". This one says
        // which of no-such-file / permission / is-a-directory it was.
        [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
    },
    writeFile: { path, bytes in
        try Data(bytes).write(to: URL(fileURLWithPath: path))
    },
    createDirectory: { path in
        try FileManager.default.createDirectory(
            atPath: path, withIntermediateDirectories: true)
    },
    writeOut: { line in
        print(line)
    },
    writeErr: { line in
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }
)

exit(run(Array(CommandLine.arguments.dropFirst()), environment: environment))
