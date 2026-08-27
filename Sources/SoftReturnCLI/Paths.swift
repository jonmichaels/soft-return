/// The four `os.path` calls the CLI makes, ported rather than approximated.
///
/// Foundation's `URL` and `NSString` path APIs both differ from `os.path` in ways that
/// would show up as wrong output filenames: `URL(fileURLWithPath:)` resolves against the
/// working directory and normalizes, and `NSString.deletingPathExtension` treats a
/// dot-leading name like `.WS` as an extension. Python's rules are small enough to state
/// exactly, and the CLI's job is to name output files the way `ctrl-kd` names them.

/// Everything after the last `/`. `os.path.basename`.
func basename(_ path: String) -> String {
    guard let slash = path.lastIndex(of: "/") else { return path }
    return String(path[path.index(after: slash)...])
}

/// Everything before the last `/`, with the root case kept. `os.path.dirname`:
/// `"a/b.WS"` -> `"a"`, `"b.WS"` -> `""`, `"/b.WS"` -> `"/"`.
func dirname(_ path: String) -> String {
    guard let slash = path.lastIndex(of: "/") else { return "" }
    let head = String(path[..<slash])
    return head.isEmpty ? "/" : head
}

/// The basename without its extension. `os.path.splitext(os.path.basename(p))[0]`.
///
/// A dot only starts an extension if something precedes it in the basename, so `.bashrc`
/// keeps its name whole — the rule that `NSString` gets wrong.
func stem(_ path: String) -> String {
    let name = basename(path)
    guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
    return String(name[..<dot])
}

/// `os.path.join`, for the two-component case the CLI uses.
func joinPath(_ directory: String, _ name: String) -> String {
    if directory.isEmpty { return name }
    if name.hasPrefix("/") { return name }
    return directory.hasSuffix("/") ? directory + name : directory + "/" + name
}
