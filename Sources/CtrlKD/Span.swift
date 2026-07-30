/// A run of text sharing one set of styles. The IR's smallest unit.
public struct Span: Hashable, Sendable {
    public var text: String
    public var styles: Style

    public init(text: String, styles: Style = []) {
        self.text = text
        self.styles = styles
    }
}
