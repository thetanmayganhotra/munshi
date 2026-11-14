// Dev-only: renders the main window to PNG for design checks. Built by scripts/snapshot.sh.
import SwiftUI

@main
struct Snapshot {
    @MainActor static func main() {
        let model = AppModel()
        model.mood = Mood(rawValue: CommandLine.arguments.dropFirst().first ?? "happy") ?? .happy
        let view = ContentView().environmentObject(model).frame(width: 460, height: 720)
        let r = ImageRenderer(content: view)
        r.scale = 2
        let rep = NSBitmapImageRep(cgImage: r.cgImage!)
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments.dropFirst(2).first ?? "snap.png"))
    }
}
