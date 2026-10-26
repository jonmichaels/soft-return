extension Array {
    /// The element at `index`, or nil past either end: a menu's or a row's index read without a bounds check of its own.
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
