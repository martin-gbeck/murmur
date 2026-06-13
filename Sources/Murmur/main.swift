import AppKit
import Foundation

// Murmur entry point.
//   (no args)            → menu-bar app
//   --cli [--file f.wav] → record (or use f.wav), transcribe, format, print to stdout
//   --cli-paste          → same, then 3-second countdown and paste at the cursor

let arguments = CommandLine.arguments

let cliFileArg: URL? = {
    guard let idx = arguments.firstIndex(of: "--file"), arguments.indices.contains(idx + 1) else { return nil }
    return URL(fileURLWithPath: arguments[idx + 1])
}()

if arguments.contains("--cli-chunked") {
    guard let file = cliFileArg else {
        fputs("--cli-chunked requires --file <16kHz-mono.wav>\n", stderr)
        exit(1)
    }
    runChunkedCLI(file: file)
    exit(0)
}

if arguments.contains("--cli") || arguments.contains("--cli-paste") {
    runCLI(paste: arguments.contains("--cli-paste"), audioFile: cliFileArg)
    exit(0)
}

// Dev harness: cycle the on-screen pills for a few seconds, then exit.
if arguments.contains("--overlay-test") {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let indicator = OverlayPanel()
        let hint = OverlayPanel()
        indicator.show(text: "Recording 0:00", dotColor: .systemRed, pulse: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            indicator.update(text: "Recording 0:02")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            indicator.show(text: "Transcribing…", dotColor: .systemOrange)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            indicator.hide()
            hint.showTransient(text: "⌘V to insert text — transcript is on your clipboard", seconds: 3)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            app.terminate(nil)
        }
        app.run()
    }
    exit(0)
}

// The process entry point runs on the main thread; assumeIsolated makes that
// visible to the compiler (top-level code in main.swift is not @MainActor).
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // .accessory covers `swift run` during dev; LSUIElement covers the packaged app.
    app.setActivationPolicy(.accessory)
    app.run()
}
