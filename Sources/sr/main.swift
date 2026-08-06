import Foundation
import SoftReturnCLI

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

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
    },
    fileExists: { path in
        FileManager.default.fileExists(atPath: path)
    },
    // D4's TTY test (ruling 2026-08-05): `isatty` on stdin's own file descriptor is the
    // real answer to "can a y/n prompt actually reach a human" — a redirected/piped stdin
    // (every script and CI run) answers false, which is what routes those to the refuse
    // branch instead of hanging on a prompt nobody can see.
    stdinIsTTY: {
        isatty(fileno(stdin)) != 0
    },
    readLine: {
        Swift.readLine()
    }
)

exit(run(Array(CommandLine.arguments.dropFirst()), environment: environment))
