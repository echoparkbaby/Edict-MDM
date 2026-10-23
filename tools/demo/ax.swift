import Cocoa
// ax PID dump [filter]           -> path role "title" "desc" "value"
// ax PID act PATH ACTION          (AXPress, AXShowMenu, ...)
// ax PID sel PATH                 set AXSelected = true
// ax PID find TEXT [ACTION]       act on first element whose label contains TEXT (default AXPress)
let a = CommandLine.arguments
let app = AXUIElementCreateApplication(Int32(a[1])!)
func attr(_ e: AXUIElement, _ n: String) -> AnyObject? { var v: AnyObject?; AXUIElementCopyAttributeValue(e, n as CFString, &v); return v }
func kids(_ e: AXUIElement) -> [AXUIElement] { (attr(e, "AXChildren") as? [AXUIElement]) ?? [] }
func s(_ e: AXUIElement, _ n: String) -> String { if let x = attr(e, n) { return "\(x)".replacingOccurrences(of: "\n", with: " ").prefix(60).description }; return "" }
func label(_ e: AXUIElement) -> String { [s(e, "AXTitle"), s(e, "AXDescription"), s(e, "AXValue"), s(e, "AXIdentifier")].filter { !$0.isEmpty }.joined(separator: " | ") }
func walk(_ e: AXUIElement, _ p: [Int], _ f: (AXUIElement, [Int]) -> Bool) -> Bool {
    if f(e, p) { return true }
    for (i, k) in kids(e).enumerated() { if walk(k, p + [i], f) { return true } }
    return false
}
func at(_ path: String) -> AXUIElement {
    var e = app
    for i in path.split(separator: ".").map({ Int($0)! }) { e = kids(e)[i] }
    return e
}
switch a[2] {
case "dump":
    let flt = a.count > 3 ? a[3].lowercased() : ""
    _ = walk(app, []) { e, p in
        let l = label(e)
        if flt.isEmpty || l.lowercased().contains(flt) { print(p.map(String.init).joined(separator: "."), s(e, "AXRole"), l) }
        return false
    }
case "act": print(AXUIElementPerformAction(at(a[3]), a[4] as CFString).rawValue)
case "sel": print(AXUIElementSetAttributeValue(at(a[3]), "AXSelected" as CFString, kCFBooleanTrue).rawValue)
case "find":
    let t = a[3].lowercased(); let act = a.count > 4 ? a[4] : "AXPress"
    var hit = false
    _ = walk(app, []) { e, p in
        if label(e).lowercased().contains(t) {
            let r = AXUIElementPerformAction(e, act as CFString)
            if r == .success { print("ok", p.map(String.init).joined(separator: "."), s(e, "AXRole"), label(e)); hit = true; return true }
        }
        return false
    }
    if !hit { print("not found / no action"); exit(1) }
default: break
}
