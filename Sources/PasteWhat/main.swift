import AppKit

let application = NSApplication.shared
let controller = AppController()
application.delegate = controller
withExtendedLifetime(controller) { application.run() }
