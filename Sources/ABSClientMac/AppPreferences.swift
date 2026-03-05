import Foundation
import AppKit

enum SettingsTab: String, CaseIterable, Identifiable {
    case playback
    case shortcuts
    case maintenance

    var id: String { rawValue }
}

enum ShortcutAction: String, CaseIterable, Identifiable {
    case skipBackwardConfiguredInterval
    case skipForwardConfiguredInterval
    case skipBackwardOneSecond
    case skipForwardOneSecond
    case playPauseToggle
    case previousChapter
    case nextChapter

    var id: String { rawValue }

    var title: String {
        switch self {
        case .skipBackwardConfiguredInterval: return "Skip Backward by configured interval"
        case .skipForwardConfiguredInterval: return "Skip Forward by configured interval"
        case .skipBackwardOneSecond: return "Skip Backward by 1 second"
        case .skipForwardOneSecond: return "Skip Forward by 1 second"
        case .playPauseToggle: return "Play / Pause"
        case .previousChapter: return "Previous Chapter"
        case .nextChapter: return "Next Chapter"
        }
    }
}

enum ShortcutKey: String, CaseIterable, Identifiable, Codable {
    case space = "Space"
    case j = "J"
    case l = "L"
    case leftArrow = "Left Arrow"
    case rightArrow = "Right Arrow"
    case comma = ","
    case period = "."
    case openBracket = "["
    case closeBracket = "]"

    var id: String { rawValue }

    var displayName: String { rawValue }

    static func from(event: NSEvent) -> ShortcutKey? {
        switch event.keyCode {
        case 123: return .leftArrow
        case 124: return .rightArrow
        default:
            guard let character = event.charactersIgnoringModifiers?.lowercased(), !character.isEmpty else {
                return nil
            }
            switch character {
            case " ": return .space
            case "j": return .j
            case "l": return .l
            case ",": return .comma
            case ".": return .period
            case "[": return .openBracket
            case "]": return .closeBracket
            default: return nil
            }
        }
    }
}

enum ShortcutModifierSet: Int, CaseIterable, Codable, Identifiable {
    case none = 0
    case command = 1
    case option = 2
    case control = 3
    case shift = 4
    case commandOption = 5
    case commandShift = 6
    case optionShift = 7
    case controlOption = 8
    case controlShift = 9

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .none: return "None"
        case .command: return "Command"
        case .option: return "Option"
        case .control: return "Control"
        case .shift: return "Shift"
        case .commandOption: return "Command + Option"
        case .commandShift: return "Command + Shift"
        case .optionShift: return "Option + Shift"
        case .controlOption: return "Control + Option"
        case .controlShift: return "Control + Shift"
        }
    }

    var eventFlags: NSEvent.ModifierFlags {
        switch self {
        case .none: return []
        case .command: return [.command]
        case .option: return [.option]
        case .control: return [.control]
        case .shift: return [.shift]
        case .commandOption: return [.command, .option]
        case .commandShift: return [.command, .shift]
        case .optionShift: return [.option, .shift]
        case .controlOption: return [.control, .option]
        case .controlShift: return [.control, .shift]
        }
    }

    static func from(eventFlags: NSEvent.ModifierFlags) -> ShortcutModifierSet? {
        let flags = eventFlags.intersection([.command, .option, .shift, .control])
        switch flags {
        case []: return ShortcutModifierSet.none
        case [.command]: return .command
        case [.option]: return .option
        case [.control]: return .control
        case [.shift]: return .shift
        case [.command, .option]: return .commandOption
        case [.command, .shift]: return .commandShift
        case [.option, .shift]: return .optionShift
        case [.control, .option]: return .controlOption
        case [.control, .shift]: return .controlShift
        default: return nil
        }
    }
}

struct ShortcutBinding: Codable, Equatable {
    var key: ShortcutKey
    var modifiers: ShortcutModifierSet
}

struct ShortcutActionBindings: Codable, Equatable {
    var primary: ShortcutBinding
    var alternate: ShortcutBinding?
}

@MainActor
final class AppPreferences: ObservableObject {
    @Published var selectedSettingsTab: SettingsTab = .playback

    @Published var skipBackwardSeconds: Double {
        didSet { defaults.set(skipBackwardSeconds, forKey: Keys.skipBackward) }
    }

    @Published var skipForwardSeconds: Double {
        didSet { defaults.set(skipForwardSeconds, forKey: Keys.skipForward) }
    }

    @Published var shortcutBindings: [ShortcutAction: ShortcutActionBindings] {
        didSet { persistShortcutBindings() }
    }

    @Published var isCapturingShortcut = false

    private enum Keys {
        static let legacySkipInterval = "abs.skip.seconds"
        static let skipBackward = "abs.skip.backward.seconds"
        static let skipForward = "abs.skip.forward.seconds"
        static let shortcutBindings = "abs.shortcut.bindings.v2"
        static let legacyShortcutBindings = "abs.shortcut.bindings.v1"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let legacySkip = defaults.double(forKey: Keys.legacySkipInterval)
        let storedBackward = defaults.double(forKey: Keys.skipBackward)
        let storedForward = defaults.double(forKey: Keys.skipForward)

        let fallback = legacySkip == 0 ? 15.0 : legacySkip
        self.skipBackwardSeconds = storedBackward == 0 ? fallback : storedBackward
        self.skipForwardSeconds = storedForward == 0 ? fallback : storedForward

        if let data = defaults.data(forKey: Keys.shortcutBindings),
           let decoded = try? JSONDecoder().decode([String: ShortcutActionBindings].self, from: data) {
            var bindings: [ShortcutAction: ShortcutActionBindings] = [:]
            for action in ShortcutAction.allCases {
                if let value = decoded[action.rawValue] {
                    bindings[action] = value
                }
            }
            self.shortcutBindings = bindings.merging(Self.defaultShortcutBindings) { current, _ in current }
        } else if let legacyData = defaults.data(forKey: Keys.legacyShortcutBindings),
                  let legacyDecoded = try? JSONDecoder().decode([String: ShortcutBinding].self, from: legacyData) {
            var migrated = Self.defaultShortcutBindings

            if let legacyBackward = legacyDecoded["skipBackward"] {
                migrated[.skipBackwardConfiguredInterval]?.primary = legacyBackward
            }
            if let legacyForward = legacyDecoded["skipForward"] {
                migrated[.skipForwardConfiguredInterval]?.primary = legacyForward
            }

            self.shortcutBindings = migrated
        } else {
            self.shortcutBindings = Self.defaultShortcutBindings
        }
    }

    static let defaultShortcutBindings: [ShortcutAction: ShortcutActionBindings] = [
        .skipBackwardConfiguredInterval: ShortcutActionBindings(
            primary: ShortcutBinding(key: .leftArrow, modifiers: .none),
            alternate: nil
        ),
        .skipForwardConfiguredInterval: ShortcutActionBindings(
            primary: ShortcutBinding(key: .rightArrow, modifiers: .none),
            alternate: nil
        ),
        .skipBackwardOneSecond: ShortcutActionBindings(
            primary: ShortcutBinding(key: .leftArrow, modifiers: .shift),
            alternate: nil
        ),
        .skipForwardOneSecond: ShortcutActionBindings(
            primary: ShortcutBinding(key: .rightArrow, modifiers: .shift),
            alternate: nil
        ),
        .playPauseToggle: ShortcutActionBindings(
            primary: ShortcutBinding(key: .space, modifiers: .none),
            alternate: nil
        ),
        .previousChapter: ShortcutActionBindings(
            primary: ShortcutBinding(key: .openBracket, modifiers: .none),
            alternate: nil
        ),
        .nextChapter: ShortcutActionBindings(
            primary: ShortcutBinding(key: .closeBracket, modifiers: .none),
            alternate: nil
        )
    ]

    func bindings(for action: ShortcutAction) -> ShortcutActionBindings {
        shortcutBindings[action] ?? Self.defaultShortcutBindings[action]!
    }

    func primaryBinding(for action: ShortcutAction) -> ShortcutBinding {
        bindings(for: action).primary
    }

    func alternateBinding(for action: ShortcutAction) -> ShortcutBinding? {
        bindings(for: action).alternate
    }

    func setPrimaryBinding(_ binding: ShortcutBinding, for action: ShortcutAction) {
        var updated = bindings(for: action)
        updated.primary = binding
        shortcutBindings[action] = updated
    }

    func setAlternateBinding(_ binding: ShortcutBinding?, for action: ShortcutAction) {
        var updated = bindings(for: action)
        updated.alternate = binding
        shortcutBindings[action] = updated
    }

    func shouldTrigger(action: ShortcutAction, for event: NSEvent) -> Bool {
        guard let key = ShortcutKey.from(event: event) else { return false }
        let eventFlags = event.modifierFlags.intersection([.command, .option, .shift, .control])
        let actionBindings = bindings(for: action)

        let primaryMatches = actionBindings.primary.key == key &&
            eventFlags == actionBindings.primary.modifiers.eventFlags
        if primaryMatches { return true }

        if let alternate = actionBindings.alternate {
            return alternate.key == key && eventFlags == alternate.modifiers.eventFlags
        }
        return false
    }

    private func persistShortcutBindings() {
        let encodedMap = Dictionary(uniqueKeysWithValues: shortcutBindings.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(encodedMap) {
            defaults.set(data, forKey: Keys.shortcutBindings)
        }
    }

    func revertToDefaultShortcuts() {
        shortcutBindings = Self.defaultShortcutBindings
    }
}
