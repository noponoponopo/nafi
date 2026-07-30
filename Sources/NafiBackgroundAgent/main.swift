import AppKit
import Foundation

let helperBundle = Bundle.main.bundleURL
let loginItems = helperBundle.deletingLastPathComponent()
let library = loginItems.deletingLastPathComponent()
let contents = library.deletingLastPathComponent()
let containingApp = contents.deletingLastPathComponent()

let configuration = NSWorkspace.OpenConfiguration()
configuration.activates = false
configuration.addsToRecentItems = false
configuration.arguments = ["--background"]
NSWorkspace.shared.openApplication(at: containingApp, configuration: configuration) { _, error in
  if let error { fputs("nafi background launch failed: \(error.localizedDescription)\n", stderr) }
  exit(error == nil ? EXIT_SUCCESS : EXIT_FAILURE)
}
RunLoop.main.run()
