// Reminder — a tiny LSUIElement app that posts a desktop notification via
// UserNotifications so the banner carries this bundle's own icon.
//
// Launched per notification by hook.sh via `open`, detached:
//   open -n Reminder.app --args \
//     --title "Claude Hooks" --body "✅ Task Finished" --sound Glass
//
// The process exits shortly after the notification is delivered — it does no
// click handling, so there's nothing to stay alive for.

import AppKit
import UserNotifications

// MARK: - Arguments

struct Args {
  var title = "Claude Code"
  var body = ""
  var sound: String?
}

func parseArgs(_ argv: [String]) -> Args {
  var a = Args()
  var i = 0
  while i < argv.count {
    switch argv[i] {
    case "--title":
      i += 1
      if i < argv.count { a.title = argv[i] }
    case "--body":
      i += 1
      if i < argv.count { a.body = argv[i] }
    case "--sound":
      i += 1
      if i < argv.count { a.sound = argv[i] }
    default: break
    }
    i += 1
  }
  return a
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
  private let args: Args

  init(args: Args) { self.args = args }

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Relaunched without args (e.g. opened from a stale banner after exit):
    // nothing to post, so just leave.
    guard !args.body.isEmpty else {
      quit()
      return
    }
    let center = UNUserNotificationCenter.current()
    center.delegate = self
    center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
      guard granted else {
        self.quit()
        return
      }
      self.post(via: center)
    }
  }

  private func post(via center: UNUserNotificationCenter) {
    let content = UNMutableNotificationContent()
    content.title = args.title
    content.body = args.body
    if let name = args.sound {
      content.sound = UNNotificationSound(named: UNNotificationSoundName("\(name).aiff"))
    } else {
      content.sound = .default
    }
    let request = UNNotificationRequest(
      identifier: UUID().uuidString, content: content, trigger: nil)
    // Hand the notification to the system, then exit once it's delivered — with no
    // click handling there's nothing to stay alive for. A short grace lets the
    // banner and sound fire first.
    center.add(request) { _ in
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.quit() }
    }
  }

  // Present the banner even though we're the frontmost (agent) app at post time.
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound])
  }

  private func quit() {
    DispatchQueue.main.async { NSApp.terminate(nil) }
  }
}

// MARK: - Entry

let delegate = AppDelegate(args: parseArgs(Array(CommandLine.arguments.dropFirst())))
let app = NSApplication.shared
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
