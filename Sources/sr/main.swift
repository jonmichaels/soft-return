import Foundation
import SoftReturnCLI

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#elseif canImport(ucrt)
import ucrt
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
        {
#if canImport(ucrt)
            // Windows CRT prefixes these with underscores (research-windows-sr, 2026-08-28).
            return _isatty(_fileno(stdin)) != 0
#else
            return isatty(fileno(stdin)) != 0
#endif
        }()
    },
    readLine: {
        Swift.readLine()
    },
    // b24 round 19 (RULINGS-LEDGER PIX row): PIX resolution's own case-insensitive
    // directory walk (SoftReturnCLI/PixResolve.swift) needs real entry listing and a
    // real is-this-a-file test — `fileExists` alone doesn't distinguish a file from a
    // directory. `contentsOfDirectory` throws for a non-directory or unreadable path;
    // that failure IS "no candidate here", matching Python's own `except OSError:
    // return None`.
    listDirectory: { path in
        try? FileManager.default.contentsOfDirectory(atPath: path)
    },
    isFile: { path in
        var isDir: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDir)
        return exists && !isDir.boolValue
    }
)

exit(run(Array(CommandLine.arguments.dropFirst()), environment: environment))
