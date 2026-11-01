import Foundation
import CoreGraphics

// Pure, dependency-free planning and validation for native desktop input. Nothing here posts an event or reads
// the screen: every type either accepts a request exactly as written or says why it cannot, so no argument is
// silently ignored on the way to an input device.

private func isBoolean(_ value: Any) -> Bool {
    if let n = value as? NSNumber { return CFGetTypeID(n) == CFBooleanGetTypeID() }
    return false
}

private func finiteNumber(_ value: Any?) -> Double? {
    guard let value, !isBoolean(value), let n = value as? NSNumber else { return nil }
    let d = n.doubleValue
    return d.isFinite ? d : nil
}

// MARK: - Key chords

/// A parsed shortcut such as "cmd+shift+t". Every token must be understood and there must be exactly one
/// non-modifier key, otherwise nothing at all is pressed (a typo must not turn "nonsense+return" into Return).
struct KeyChord: Equatable {
    struct Modifiers: OptionSet, Equatable {
        let rawValue: Int
        static let command = Modifiers(rawValue: 1), shift = Modifiers(rawValue: 2), option = Modifiers(rawValue: 4)
        static let control = Modifiers(rawValue: 8), function = Modifiers(rawValue: 16)
    }
    enum Key: Equatable { case named(UInt16), character(Character) }

    let modifiers: Modifiers
    let key: Key

    /// Keys with a name, which sit in the same place on every layout.
    static let namedKeys: [String: UInt16] = [
        "return": 0x24, "enter": 0x24, "tab": 0x30, "space": 0x31, "delete": 0x33, "backspace": 0x33,
        "esc": 0x35, "escape": 0x35, "forwarddelete": 0x75, "home": 0x73, "end": 0x77, "pageup": 0x74, "pagedown": 0x79,
        "left": 0x7B, "right": 0x7C, "down": 0x7D, "up": 0x7E,
        "f1": 0x7A, "f2": 0x78, "f3": 0x63, "f4": 0x76, "f5": 0x60, "f6": 0x61, "f7": 0x62, "f8": 0x64,
        "f9": 0x65, "f10": 0x6D, "f11": 0x67, "f12": 0x6F, "spacebar": 0x31, "del": 0x33,
    ]
    /// Names the model spells out for punctuation ("cmd+minus", "cmd+plus" for zoom).
    static let namedChars: [String: Character] = [
        "minus": "-", "hyphen": "-", "dash": "-", "plus": "=", "equal": "=", "equals": "=", "comma": ",",
        "period": ".", "dot": ".", "slash": "/", "backslash": "\\", "semicolon": ";", "quote": "'",
        "backtick": "`", "grave": "`", "leftbracket": "[", "rightbracket": "]",
    ]

    static func modifier(named part: String) -> Modifiers? {
        switch part {
        case "cmd", "command", "⌘": return .command
        case "shift", "⇧": return .shift
        case "opt", "option", "alt", "⌥": return .option
        case "ctrl", "control", "⌃": return .control
        case "fn": return .function
        default: return nil
        }
    }

    static func parse(_ combo: String) -> Result<KeyChord, KeyChordError> {
        var modifiers: Modifiers = []
        var key: Key?
        var keyToken = ""
        let tokens = combo.lowercased().replacingOccurrences(of: " ", with: "").split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard !combo.trimmingCharacters(in: .whitespaces).isEmpty else { return .failure(.init(message: "empty shortcut")) }
        for raw in tokens {
            guard !raw.isEmpty else { return .failure(.init(message: "empty key name in \(combo.debugDescription)")) }
            // "Page_Down", "page-up": the same keys as "pagedown", "pageup".
            let part = raw.count > 1 ? raw.replacingOccurrences(of: "_", with: "").replacingOccurrences(of: "-", with: "") : raw
            if let mod = modifier(named: part) {
                guard !modifiers.contains(mod) else { return .failure(.init(message: "modifier \(part.debugDescription) repeated in \(combo.debugDescription)")) }
                modifiers.insert(mod)
                continue
            }
            let candidate: Key
            if let code = namedKeys[part] { candidate = .named(code) }
            else if let ch = namedChars[part] ?? (part.count == 1 ? part.first : nil) { candidate = .character(ch) }
            else { return .failure(.init(message: "unknown key \(raw.debugDescription) in \(combo.debugDescription)")) }
            if key != nil {
                return .failure(.init(message: "\(combo.debugDescription) has more than one non-modifier key (\(keyToken), \(raw))"))
            }
            key = candidate
            keyToken = raw
        }
        guard let key else { return .failure(.init(message: "\(combo.debugDescription) has no key to press, only modifiers")) }
        return .success(KeyChord(modifiers: modifiers, key: key))
    }
}

struct KeyChordError: Error, Equatable { let message: String }

// MARK: - Click options

/// Button, click count, held modifiers and hold duration for a pixel click. Anything unrecognised is refused so a
/// requested right/double/modified click is never silently performed as a plain left click.
struct ClickOptions: Equatable {
    enum Button: String { case left, right, middle }
    var button: Button = .left
    var count = 1
    var modifiers: KeyChord.Modifiers = []
    var holdMilliseconds = 0

    static let maxHoldMilliseconds = 5000
    private static let keys: Set<String> = ["button", "count", "modifiers", "duration_ms"]
    /// True when AXPress alone is an honest delivery (no button, count, modifier or hold was requested).
    var isPlain: Bool { self == ClickOptions() }

    /// Reads only the option keys of an action; unrelated keys (do, id, x, y…) are the caller's concern.
    static func parse(_ action: [String: Any]) -> Result<ClickOptions, ClickOptionsError> {
        var out = ClickOptions()
        if let raw = action["button"] {
            guard let s = (raw as? String)?.lowercased(), let b = Button(rawValue: s) else {
                return .failure(.init(message: "button must be left, right or middle"))
            }
            out.button = b
        }
        if let raw = action["count"] {
            guard let n = finiteNumber(raw), n == n.rounded(), (1...3).contains(Int(n)) else {
                return .failure(.init(message: "count must be a whole number from 1 to 3"))
            }
            out.count = Int(n)
        }
        if let raw = action["modifiers"] {
            let names: [String]
            if let list = raw as? [String] { names = list }
            else if let text = raw as? String { names = text.split(separator: "+").map(String.init) }
            else { return .failure(.init(message: "modifiers must be a list such as [\"cmd\",\"shift\"]")) }
            for name in names {
                guard let m = KeyChord.modifier(named: name.lowercased().trimmingCharacters(in: .whitespaces)), m != .function,
                      !out.modifiers.contains(m) else {
                    return .failure(.init(message: "modifiers may only be distinct cmd, shift, opt or ctrl; got \(name.debugDescription)"))
                }
                out.modifiers.insert(m)
            }
        }
        if let raw = action["duration_ms"] {
            guard let d = finiteNumber(raw), d >= 0, d <= Double(maxHoldMilliseconds) else {
                return .failure(.init(message: "duration_ms must be between 0 and \(maxHoldMilliseconds)"))
            }
            out.holdMilliseconds = Int(d)
        }
        return .success(out)
    }

    /// The press/release sequence: click state counts up for multi-clicks, modifiers held throughout.
    struct Step: Equatable { let down: Bool; let clickState: Int }
    var steps: [Step] {
        (1...count).flatMap { [Step(down: true, clickState: $0), Step(down: false, clickState: $0)] }
    }
}

struct ClickOptionsError: Error, Equatable { let message: String }

// MARK: - Scroll

/// A scroll request with an explicit direction, unit and amount. With neither amount nor unit given the legacy
/// default (four bursts of three lines) applies; a supplied value is honoured or the request is refused.
struct ScrollPlan: Equatable {
    enum Direction: String { case up, down, left, right }
    enum Unit: String { case lines, pixels, pages }
    let direction: Direction
    let unit: Unit
    /// Requested amount in `unit`.
    let amount: Double
    let isDefault: Bool

    static let limits: [Unit: Double] = [.lines: 200, .pixels: 20_000, .pages: 20]

    static func parse(_ action: [String: Any]) -> Result<ScrollPlan, ScrollPlanError> {
        var direction = Direction.down
        if let raw = action["dir"] ?? action["direction"] {
            guard let s = (raw as? String)?.lowercased(), let d = Direction(rawValue: s) else {
                return .failure(.init(message: "scroll direction must be up, down, left or right"))
            }
            direction = d
        }
        var unit = Unit.lines
        let explicitUnit = action["unit"] != nil
        if let raw = action["unit"] {
            guard let s = (raw as? String)?.lowercased(), let u = Unit(rawValue: s) else {
                return .failure(.init(message: "scroll unit must be lines, pixels or pages"))
            }
            unit = u
        }
        var amount = 12.0
        let explicitAmount = action["amount"] != nil
        if let raw = action["amount"] {
            guard let a = finiteNumber(raw), a > 0, a <= limits[unit]! else {
                return .failure(.init(message: "scroll amount must be a positive number up to \(Int(limits[unit]!)) \(unit.rawValue)"))
            }
            amount = a
        } else if explicitUnit {
            return .failure(.init(message: "a scroll unit needs an amount"))
        }
        return .success(ScrollPlan(direction: direction, unit: unit, amount: amount, isDefault: !explicitAmount && !explicitUnit))
    }

    /// Wheel chunks (vertical, horizontal) to post, in the unit the wheel event uses. Positive vertical scrolls up and
    /// positive horizontal scrolls left. Pages become pixels of the viewport's extent along the scroll axis.
    func chunks(viewport: CGSize) -> (usesPixels: Bool, steps: [(dy: Int32, dx: Int32)]) {
        var total = amount
        var pixels = unit != .lines
        if unit == .pages {
            let extent = (direction == .up || direction == .down) ? viewport.height : viewport.width
            total = amount * max(1, Double(extent) * 0.9)
            pixels = true
        }
        let burst = pixels ? 120.0 : 3.0
        var remaining = total.rounded()
        var steps: [(Int32, Int32)] = []
        while remaining > 0 {
            let size = Int32(min(burst, remaining))
            remaining -= Double(size)
            switch direction {
            case .up: steps.append((size, 0))
            case .down: steps.append((-size, 0))
            case .left: steps.append((0, size))
            case .right: steps.append((0, -size))
            }
        }
        return (pixels, steps.map { (dy: $0.0, dx: $0.1) })
    }
}

struct ScrollPlanError: Error, Equatable { let message: String }

// MARK: - Control state

/// A requested final state for a checkbox, radio button or range control.
enum DesiredState: Equatable {
    case on, off
    case value(Double)

    static func parse(role: String, raw: Any?) -> Result<DesiredState, DesiredStateError> {
        switch role {
        case "AXCheckBox", "AXRadioButton", "AXSwitch":
            if let raw, isBoolean(raw), let n = raw as? NSNumber {
                if role == "AXRadioButton", !n.boolValue { return .failure(.init(message: "a radio button cannot be switched off directly; select another option in its group")) }
                return .success(n.boolValue ? .on : .off)
            }
            if let s = (raw as? String)?.lowercased() {
                if ["on", "true", "checked", "yes", "1"].contains(s) { return .success(.on) }
                if ["off", "false", "unchecked", "no", "0"].contains(s) {
                    if role == "AXRadioButton" { return .failure(.init(message: "a radio button cannot be switched off directly; select another option in its group")) }
                    return .success(.off)
                }
            }
            return .failure(.init(message: "desired state of a \(role.dropFirst(2).lowercased()) must be on or off"))
        case "AXSlider", "AXIncrementor", "AXLevelIndicator", "AXValueIndicator":
            guard let v = finiteNumber(raw) else { return .failure(.init(message: "desired value of a range control must be a finite number")) }
            return .success(.value(v))
        default:
            return .failure(.init(message: "\(role.dropFirst(2)) is not a checkbox, radio button or range control"))
        }
    }

    /// Whether the control's reported AXValue already equals the desired state. Unknown or mixed never matches.
    func matches(_ current: Any?, tolerance: Double = 0) -> Bool {
        guard let current, let n = current as? NSNumber else { return false }
        switch self {
        case .on: return n.doubleValue == 1
        case .off: return n.doubleValue == 0
        case .value(let v): return abs(n.doubleValue - v) <= tolerance
        }
    }
}

struct DesiredStateError: Error, Equatable { let message: String }

// MARK: - Text editing semantics

/// Where typed text goes relative to what a field already holds.
enum TextEditMode: String, CaseIterable {
    /// Replaces the whole value (the long-standing default of the type action).
    case replaceAll = "replace"
    /// Types at the caret, replacing the selection if there is one (what a keyboard does).
    case insertAtCaret = "insert"
    /// Adds after the last character.
    case append

    /// The text and caret after the edit, or nil when the selection does not lie inside the value.
    /// Ranges are UTF-16 offsets, which is what Accessibility reports.
    func apply(to value: String, selection: NSRange?, text: String) -> (value: String, caret: Int)? {
        let ns = value as NSString
        switch self {
        case .replaceAll:
            return (text, (text as NSString).length)
        case .append:
            return (value + text, ns.length + (text as NSString).length)
        case .insertAtCaret:
            guard let selection, selection.location != NSNotFound, selection.location >= 0, selection.length >= 0,
                  selection.location + selection.length <= ns.length else { return nil }
            return (ns.replacingCharacters(in: selection, with: text), selection.location + (text as NSString).length)
        }
    }
}

// MARK: - Selecting among candidates

/// Choosing one window (or menu item) by title: a unique exact match wins, otherwise a unique partial match;
/// several candidates are reported rather than the first one being acted on.
enum TitleChoice: Equatable {
    case one(Int), none, ambiguous([Int])

    static func choose(titles: [String], wanted: String, normalize: (String) -> String = { $0.lowercased() }) -> TitleChoice {
        let want = normalize(wanted)
        guard !want.isEmpty else { return .none }
        let keys = titles.map(normalize)
        for matches in [keys.indices.filter { keys[$0] == want },
                        keys.indices.filter { !keys[$0].isEmpty && keys[$0].hasPrefix(want) },
                        keys.indices.filter { keys[$0].contains(want) }] {
            if matches.count == 1 { return .one(matches[0]) }
            if matches.count > 1 { return .ambiguous(matches) }
        }
        return .none
    }
}
