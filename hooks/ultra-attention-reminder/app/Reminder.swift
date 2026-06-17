// Reminder — a tiny LSUIElement app that posts a desktop notification via
// UserNotifications so the banner carries this bundle's own icon.
//
// Launched per notification by hook.sh via `open`, detached, e.g.:
//   open -n Reminder.app --args --title "Claude Hooks" --body "✅ Task Finished" \
//     --sound Glass --iterm-session "UUID" --activate com.googlecode.iterm2
//
// Clicking the banner jumps back to where Claude was running, using the most
// precise handle the hook could resolve (the click handler runs here, with none
// of that session's env, so the hook bakes the handle into the launch args):
//   --iterm-session <UUID>  → osascript: select that iTerm session  (exact window/tab)
//   --code-dir <path>       → open -b <vscode> <path>               (the VS Code window for that project)
//   --activate <bundleID>   → open -b <bundleID>                    (app-level floor)
// The process stays alive (~5 min) to catch the click before exiting.

import AppKit
import UserNotifications

// MARK: - Arguments

struct Args {
  var title = "Claude Code"
  var body = ""
  var sound: String?
  var activateBundleID: String?
  var itermSession: String?
  var codeDir: String?
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
    case "--activate":
      i += 1
      if i < argv.count { a.activateBundleID = argv[i] }
    case "--iterm-session":
      i += 1
      if i < argv.count { a.itermSession = argv[i] }
    case "--code-dir":
      i += 1
      if i < argv.count { a.codeDir = argv[i] }
    default: break
    }
    i += 1
  }
  return a
}

// MARK: - App delegate

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
  private let args: Args
  // Stay alive after posting so a click lands on a live instance — we don't
  // rely on macOS relaunching the agent (unreliable under macOS 26 + ad-hoc
  // signing).
  private let timeout: TimeInterval = 300

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
    // Carry the click target(s) through to didReceive(_:). The handler picks the
    // most precise one available (iterm-session > code-dir > activate).
    var info: [String: String] = [:]
    if let s = args.itermSession { info["itermSession"] = s }
    if let d = args.codeDir { info["codeDir"] = d }
    if let b = args.activateBundleID { info["activate"] = b }
    content.userInfo = info

    let request = UNNotificationRequest(
      identifier: UUID().uuidString, content: content, trigger: nil)
    // Hand the notification to the system, then stay alive so a click lands on
    // this live instance. Quit after the timeout if no click arrives.
    center.add(request) { _ in }
    DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { self.quit() }
  }

  // Present the banner even though we're the frontmost (agent) app at post time.
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound])
  }

  // Banner clicked: jump back to where Claude was running, then exit.
  func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    didReceive response: UNNotificationResponse,
    withCompletionHandler completionHandler: @escaping () -> Void
  ) {
    focus(response.notification.request.content.userInfo)
    completionHandler()
    // Don't quit synchronously: tearing the process down mid-handshake makes
    // LaunchServices report -609 ("application isn't open"). Delay the quit so
    // a first-run "control iTerm" consent prompt has time to resolve too.
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { self.quit() }
  }

  // Most precise handle first; --activate is the always-present floor.
  private func focus(_ info: [AnyHashable: Any]) {
    if let session = info["itermSession"] as? String {
      // iTerm: select the exact session by id, then activate. The documented
      // `iterm2:///reveal?sessionid=` URL is a no-op on current iTerm (3.6.x),
      // so we drive it with Apple Events — costs a one-time "control iTerm"
      // consent the first time (the gate's query is exempt; this isn't, since
      // we run outside iTerm's process tree). activate + macOS's
      // AppleSpacesSwitchOnActivate carry the switch across Spaces.
      runOsascript("""
        tell application "iTerm2"
          activate
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if (id of s) is "\(session)" then
                  select w
                  select t
                  select s
                  return
                end if
              end repeat
            end repeat
          end repeat
        end tell
        """)
    } else if let dir = info["codeDir"] as? String, let bundle = info["activate"] as? String {
      // VS Code: open the project folder in its app → focuses the window that
      // already has it (VS Code keeps one window per folder). Via `open` so we
      // don't depend on the `code` CLI being on the app's sanitized PATH.
      run(["-b", bundle, dir])
    } else if let bundle = info["activate"] as? String {
      run(["-b", bundle])
    }
  }

  // Shell out to `open`. A background LSUIElement agent calling NSWorkspace to
  // activate *another* app gets dropped by macOS's focus-stealing guard;
  // `open` (user-click-initiated here) brings the target up reliably.
  private func run(_ openArgs: [String]) {
    launch("/usr/bin/open", openArgs)
  }

  private func runOsascript(_ script: String) {
    launch("/usr/bin/osascript", ["-e", script])
  }

  private func launch(_ tool: String, _ arguments: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool)
    p.arguments = arguments
    try? p.run()
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
