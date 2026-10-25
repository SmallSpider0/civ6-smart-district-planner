// sdp-click: one real left click into the Civilization VI window, for
// tools/realclick.py (which builds it into ~/Applications/SDPClick.app). The
// game window does not expose accessibility elements and the computer-use
// tool refuses to click it, so the click is posted as system mouse events
// (CGEvent). That needs SDPClick.app to be allowed under System Settings >
// Privacy & Security > Accessibility.
//
//   sdp-click window             the game window's bounds (points): x y w h
//   sdp-click trusted            whether input may be posted
//   sdp-click X Y                click at window-relative point (X, Y)
//   sdp-click capturable         whether screen capture is allowed (asks once)
//   sdp-click capture X Y W H FILE   PNG of a window-relative rectangle (points)
//   (each with --out FILE when started through open)
//
// Capturing needs SDPClick.app allowed under System Settings > Privacy &
// Security > Screen & System Audio Recording. It only takes rectangles inside
// the game window, with the game in front and nothing covering the rectangle.
//
// Before clicking it checks that the game is the frontmost app (it activates
// it first and gives the previous app the front back afterwards), that the
// point lies inside the game window and that no other window covers it.
// Otherwise it clicks nothing and exits with 2.
import AppKit
import ApplicationServices
import CoreGraphics

let bundleID = "com.aspyr.civ6.steam"

// The game's largest on-screen window. Found by its owner's name (which
// starts with an invisible U+0092 on this machine, hence "contains"): the game
// runs as a child process (Civ6_Exe_Child) that LaunchServices lists with
// pid -1, so NSRunningApplication cannot give its pid.
func gameWindow() -> (pid: pid_t, bounds: CGRect)? {
  let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
  var best: (pid: pid_t, bounds: CGRect)? = nil
  for info in list {
    guard let name = info[kCGWindowOwnerName as String] as? String, name.contains("Civilization VI"),
          let owner = info[kCGWindowOwnerPID as String] as? pid_t,
          let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
          let dict = info[kCGWindowBounds as String] as? NSDictionary,
          let rect = CGRect(dictionaryRepresentation: dict) else { continue }
    if best == nil || rect.width * rect.height > best!.bounds.width * best!.bounds.height { best = (owner, rect) }
  }
  return best
}

func gameInFront() -> Bool {
  return NSWorkspace.shared.frontmostApplication?.bundleIdentifier == bundleID
}

// The owner of the frontmost normal window at a screen point.
func ownerAt(_ point: CGPoint) -> pid_t? {
  let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
  for info in list {  // front to back
    guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
          let dict = info[kCGWindowBounds as String] as? NSDictionary,
          let rect = CGRect(dictionaryRepresentation: dict), rect.contains(point) else { continue }
    return info[kCGWindowOwnerPID as String] as? pid_t
  }
  return nil
}

// Launched as SDPClick.app (open --args ... --out FILE) the output goes to
// FILE: macOS judges Accessibility by the app that starts a command-line
// tool (Claude here), so the tool runs as an app of its own.
var args = CommandLine.arguments
var outPath: String? = nil
if let i = args.firstIndex(of: "--out"), i + 1 < args.count {
  outPath = args[i + 1]
  args.removeSubrange(i...(i + 1))
}
func say(_ text: String) {
  if let path = outPath { try? (text + "\n").write(toFile: path, atomically: true, encoding: .utf8) } else { print(text) }
}
func fail(_ message: String) -> Never {
  if let path = outPath { try? ("ERROR " + message + "\n").write(toFile: path, atomically: true, encoding: .utf8) }
  FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
  exit(2)
}
guard let window = gameWindow() else { fail("no Civilization VI window on screen") }
if args.count == 2 && args[1] == "trusted" {
  say(AXIsProcessTrusted() ? "trusted" : "not trusted")
  exit(0)
}
if args.count == 2 && args[1] == "window" {
  say("\(Int(window.bounds.minX)) \(Int(window.bounds.minY)) \(Int(window.bounds.width)) \(Int(window.bounds.height))")
  exit(0)
}
if args.count == 2 && args[1] == "capturable" {
  say(CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() ? "capturable" : "not capturable")
  exit(0)
}

// Bring the game forward for a click or a capture; returns the app to give the front back to.
func bringGameForward() -> NSRunningApplication? {
  let previous = NSWorkspace.shared.frontmostApplication
  if !gameInFront() {
    NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.activate(options: [])
    var waited = 0.0
    while !gameInFront() && waited < 3 {
      Thread.sleep(forTimeInterval: 0.1)
      waited += 0.1
    }
  }
  guard gameInFront() else { fail("could not bring the game to the front") }
  Thread.sleep(forTimeInterval: 0.3)
  return previous
}
func giveFrontBack(_ previous: NSRunningApplication?) {
  if let previous = previous, previous.bundleIdentifier != bundleID,
     previous.bundleIdentifier != "com.apple.finder" {
    previous.activate(options: [])
  }
}

if args.count == 7 && args[1] == "capture" {
  guard let x = Double(args[2]), let y = Double(args[3]), let w = Double(args[4]), let h = Double(args[5]) else {
    fail("usage: sdp-click capture X Y W H FILE")
  }
  guard CGPreflightScreenCaptureAccess() else {
    _ = CGRequestScreenCaptureAccess()
    fail("not allowed to capture: allow SDPClick under System Settings > Privacy & Security > Screen & System Audio Recording")
  }
  let rect = CGRect(x: window.bounds.minX + x, y: window.bounds.minY + y, width: w, height: h)
  guard window.bounds.contains(rect) else { fail("rectangle outside the game window") }
  let previous = bringGameForward()
  for p in [CGPoint(x: rect.minX + 1, y: rect.minY + 1), CGPoint(x: rect.maxX - 1, y: rect.minY + 1),
            CGPoint(x: rect.minX + 1, y: rect.maxY - 1), CGPoint(x: rect.maxX - 1, y: rect.maxY - 1),
            CGPoint(x: rect.midX, y: rect.midY)] {
    guard ownerAt(p) == window.pid else { fail("another window covers the rectangle") }
  }
  let task = Process()
  task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
  task.arguments = ["-x", "-t", "png", "-R", "\(Int(rect.minX)),\(Int(rect.minY)),\(Int(rect.width)),\(Int(rect.height))", args[6]]
  try? task.run()
  task.waitUntilExit()
  giveFrontBack(previous)
  guard task.terminationStatus == 0, FileManager.default.fileExists(atPath: args[6]) else { fail("screencapture failed") }
  say("captured \(Int(rect.minX)) \(Int(rect.minY)) \(Int(rect.width)) \(Int(rect.height))")
  exit(0)
}

guard args.count == 3, let x = Double(args[1]), let y = Double(args[2]) else {
  fail("usage: sdp-click window | trusted | capturable | X Y | capture X Y W H FILE")
}
guard AXIsProcessTrusted() else {
  fail("not allowed to post input: add this binary under System Settings > Privacy & Security > Accessibility")
}
let point = CGPoint(x: window.bounds.minX + x, y: window.bounds.minY + y)
guard window.bounds.insetBy(dx: 2, dy: 2).contains(point) else { fail("point outside the game window") }

let previous = bringGameForward()
guard ownerAt(point) == window.pid else { fail("another window covers the point") }

let source = CGEventSource(stateID: .hidSystemState)
func post(_ type: CGEventType) {
  CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
}
post(.mouseMoved)
Thread.sleep(forTimeInterval: 0.15)
post(.leftMouseDown)
Thread.sleep(forTimeInterval: 0.08)
post(.leftMouseUp)
Thread.sleep(forTimeInterval: 0.3)
giveFrontBack(previous)
say("clicked \(Int(point.x)) \(Int(point.y))")
