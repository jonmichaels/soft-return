import XCTest

/// What every UI test's launch of the app adds to its own arguments (planning #581, #582):
/// - `-ApplePersistenceIgnoreState YES`: AppKit restores no window from the saved state the real app (same bundle id) or
///   an earlier test left, and saves none;
/// - `-SoftReturnUnderTest YES`: the app reopens nothing from its own list, writes none, and asks Spotlight for nothing.
/// Every flag has a value. A bare flag before another key-value pair left that pair's value over, and AppKit opened it as
/// a document ("The document "YES" could not be opened", 2026-10-26).
enum UITestLaunch {
    static let arguments = ["-ApplePersistenceIgnoreState", "YES", "-SoftReturnUnderTest", "YES"]
}
