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

exit(run(Array(CommandLine.arguments.dropFirst()), environment: .live))
