// Renders an icon HTML file to a transparent PNG.
//   swiftc -o render render.swift && ./render in.html out.png [size] [query]
import AppKit
import WebKit

let args = CommandLine.arguments
let inputFile = URL(fileURLWithPath: args[1]).absoluteURL
// Optional 4th argument: a query string, e.g. "bleed".
let input = args.count > 4 ? URL(string: inputFile.absoluteString + "?" + args[4])! : inputFile
let output = URL(fileURLWithPath: args[2])
let size = args.count > 3 ? Int(args[3])! : 1024

final class Renderer: NSObject, WKNavigationDelegate {
    let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1024, height: 1024))
    let window = NSWindow(contentRect: NSRect(x: -5000, y: -5000, width: 1024, height: 1024), styleMask: .borderless, backing: .buffered, defer: false)

    func start() {
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = self
        window.isOpaque = false
        window.backgroundColor = .clear
        window.contentView = webView
        window.orderFrontRegardless()
        webView.loadFileURL(input, allowingReadAccessTo: inputFile.deletingLastPathComponent())
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.snapshot() }
    }

    func snapshot() {
        webView.takeSnapshot(with: WKSnapshotConfiguration()) { image, error in
            guard let cg = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
                print("snapshot failed: \(String(describing: error))"); exit(1)
            }
            let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.interpolationQuality = .high
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: size, height: size))
            let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
            try! rep.representation(using: .png, properties: [:])!.write(to: output)
            exit(0)
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let renderer = Renderer()
renderer.start()
app.run()
