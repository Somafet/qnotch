import Foundation

/// Windows "HTML Format" clipboard payload. Offsets in the header are UTF-8 byte positions of the document and the fragment,
/// as the format requires. The Mac pasteboard takes plain HTML (public.html), so a Mac host uses the fragment directly; the
/// wrapper is kept for hosts and tests that need the Windows form.
enum ClipboardHtml {
    private static let before = "<html><head><meta charset=\"utf-8\"></head><body><!--StartFragment-->"
    private static let after = "<!--EndFragment--></body></html>"
    private static func header(_ a: Int, _ b: Int, _ c: Int, _ d: Int) -> String {
        "Version:0.9\r\nStartHTML:\(pad(a, 10))\r\nEndHTML:\(pad(b, 10))\r\nStartFragment:\(pad(c, 10))\r\nEndFragment:\(pad(d, 10))\r\n"
    }

    static func wrap(_ fragment: String) -> String {
        let headerLength = header(0, 0, 0, 0).utf8.count
        let startFragment = headerLength + before.utf8.count
        let endFragment = startFragment + fragment.utf8.count
        let endHtml = endFragment + after.utf8.count
        return header(headerLength, endHtml, startFragment, endFragment) + before + fragment + after
    }
}
