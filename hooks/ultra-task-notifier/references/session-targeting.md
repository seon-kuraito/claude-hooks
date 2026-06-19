# Session targeting and return

Whether to send a notification — and where clicking it jumps back to — both hinge on the same thing: **which session Claude Code is currently in**. The hook passes this to `Notifier.app` when it fires, so a click can return to the right place. This file records each terminal's locating capability, the notify / return implementation boundary, and the trade-offs deliberately taken or rejected; the README keeps only a high-level summary.

## Locating precision

Different terminals expose different ways to locate the session:

| Terminal | Locator | Precision | Permission |
| --- | --- | --- | --- |
| iTerm | `ITERM_SESSION_ID` | session (window / tab / split) | notify decision needs none; first click-return needs a one-time "allow controlling iTerm" |
| VS Code | project folder path | window (relies on the "one folder, one window" convention) | none |
| Other | App bundle | App level | none |

## Notify decision and return

- **Notify decision.** First use `lsappinfo` to check whether the frontmost app is the terminal running Claude Code; iTerm then uses `osascript` to compare the "frontmost session id" against the "notifying session id" — staying silent when the user is looking at the same session, still notifying when it is only another window or tab of the same app. Other terminals have no session probing and fall back to App-level judgement.
- **Click to return.** iTerm uses the session id with AppleScript `select` to jump back to the source session; VS Code locates the source window by project folder; other terminals fall back to App-level activation. Cross-desktop and cross-screen switching is left to macOS system behavior.

## Key trade-offs

- **iTerm uses AppleScript `select`, not the URL scheme.** `iterm2:///reveal?sessionid=` does not work on current iTerm (3.6.x) in practice: the scheme is registered and `open` succeeds, but focus does not move. Selecting a session by id via AppleScript is the only precise option.
- **The decision needs no permission; the return does.** The notify decision runs inside the hook (a descendant process of iTerm), so it needs no authorization. The click-return's Apple Events are sent by `Notifier.app` (outside iTerm's process tree), so the first return needs Automation authorization.
- **Cross-desktop / screen is left to the system.** This relies on the macOS "switch to a Space with a window when activating an app" setting (`AppleSpacesSwitchOnActivate`, on by default); turning it off confines the jump to the current desktop. The hook does not change it — changing it requires restarting the Dock.

## Accepted limitations

- **VS Code can only tell the app, not the window.** VS Code cannot report its frontmost window from the outside; while looking at window A, completion in window B is still silenced. Pinpointing "a specific terminal tab inside VS Code" requires running tmux in that terminal.
- **Multiple windows across desktops cannot pinpoint one.** Hitting "that one" window across desktops for an arbitrary terminal is only possible with the private SkyLight API (no SIP needed, ad-hoc signing works), but private APIs break easily across macOS versions and so are not used — it falls back to App level.
