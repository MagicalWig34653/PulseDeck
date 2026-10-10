import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// A small immutable XML tree, enough to read the configuration files of Parallels
/// (`config.pvs`) and VirtualBox (`VirtualBox.xml`, `*.vbox`). `XMLParser` is the only
/// parser involved, so the same code runs on macOS and in the Linux test environment.
public struct VMProviderXMLElement: Hashable, Sendable {
    public var name: String
    public var attributes: [String: String]
    /// Concatenated character data directly inside this element, trimmed.
    public var text: String
    public var children: [VMProviderXMLElement]

    public init(name: String, attributes: [String: String] = [:], text: String = "", children: [VMProviderXMLElement] = []) {
        self.name = name
        self.attributes = attributes
        self.text = text
        self.children = children
    }

    /// First direct child with this name.
    public func child(_ name: String) -> VMProviderXMLElement? {
        children.first { $0.name == name }
    }

    /// All direct children with this name.
    public func children(named name: String) -> [VMProviderXMLElement] {
        children.filter { $0.name == name }
    }

    /// Follows a `/`-separated path of direct children, e.g. `Hardware/Cpu/Number`.
    public func descendant(_ path: String) -> VMProviderXMLElement? {
        var element: VMProviderXMLElement? = self
        for component in path.split(separator: "/") {
            element = element?.child(String(component))
            if element == nil { return nil }
        }
        return element
    }

    /// Text of the element at `path` (empty text counts as missing).
    public func text(at path: String) -> String? {
        guard let value = descendant(path)?.text, !value.isEmpty else { return nil }
        return value
    }

    /// Every element in the subtree (including `self`) with this name, depth first.
    public func allDescendants(named name: String) -> [VMProviderXMLElement] {
        var result: [VMProviderXMLElement] = []
        if self.name == name { result.append(self) }
        for child in children { result += child.allDescendants(named: name) }
        return result
    }

    /// Parses a document and returns its root element, or `nil` for malformed XML.
    /// Namespaces are not processed: element names are the literal tag names, which is what both
    /// vendors' files need (VirtualBox declares a default namespace only, no prefixes).
    public static func parse(_ data: Data) -> VMProviderXMLElement? {
        let builder = Builder()
        let parser = XMLParser(data: data)
        parser.delegate = builder
        // The files are local configuration; never fetch external entities.
        parser.shouldResolveExternalEntities = false
        guard parser.parse(), let root = builder.root else { return nil }
        return root
    }

    public static func parse(_ text: String) -> VMProviderXMLElement? {
        parse(Data(text.utf8))
    }

    /// Mutable builder driven by `XMLParser` callbacks.
    private final class Builder: NSObject, XMLParserDelegate {
        private struct Frame {
            var name: String
            var attributes: [String: String]
            var text: String = ""
            var children: [VMProviderXMLElement] = []
        }

        private var stack: [Frame] = []
        private(set) var root: VMProviderXMLElement?

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
            stack.append(Frame(name: elementName, attributes: attributeDict))
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard !stack.isEmpty else { return }
            stack[stack.count - 1].text += string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
            guard let frame = stack.popLast() else { return }
            let element = VMProviderXMLElement(
                name: frame.name,
                attributes: frame.attributes,
                text: frame.text.trimmingCharacters(in: .whitespacesAndNewlines),
                children: frame.children
            )
            if stack.isEmpty {
                root = element
            } else {
                stack[stack.count - 1].children.append(element)
            }
        }
    }
}
