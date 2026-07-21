import AppKit
import Carbon.HIToolbox
import Combine

/// A user-rebindable action.
enum ShortcutAction: String, CaseIterable, Identifiable {
    case allow
    case deny
    case togglePanel
    case sessionSwitcher
    case collapsePanel

    var id: String { rawValue }

    var title: String {
        switch self {
        case .allow: return "Allow pending request"
        case .deny: return "Deny pending request"
        case .togglePanel: return "Show / hide panel"
        case .sessionSwitcher: return "Summon session switcher"
        case .collapsePanel: return "Collapse panel"
        }
    }

    var subtitle: String? {
        switch self {
        case .allow, .deny:
            return "Only active while a request is waiting, so it never shadows this key elsewhere."
        default:
            return nil
        }
    }

    /// Only bound while something is waiting on the user.
    var isContextual: Bool {
        self == .allow || self == .deny
    }

    var defaultBinding: KeyBinding {
        switch self {
        case .allow: return KeyBinding(keyCode: UInt32(kVK_ANSI_Y), modifiers: cmdKey)
        case .deny: return KeyBinding(keyCode: UInt32(kVK_ANSI_N), modifiers: cmdKey)
        case .togglePanel: return KeyBinding(keyCode: UInt32(kVK_ANSI_J), modifiers: optionKey)
        case .sessionSwitcher: return KeyBinding(keyCode: UInt32(kVK_ANSI_G), modifiers: optionKey)
        case .collapsePanel: return KeyBinding(keyCode: UInt32(kVK_Escape), modifiers: 0)
        }
    }
}

struct KeyBinding: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: Int

    /// Human-readable form, e.g. "⌘Y".
    var display: String {
        var text = ""
        if modifiers & controlKey != 0 { text += "⌃" }
        if modifiers & optionKey != 0 { text += "⌥" }
        if modifiers & shiftKey != 0 { text += "⇧" }
        if modifiers & cmdKey != 0 { text += "⌘" }
        text += KeyBinding.name(for: keyCode)
        return text
    }

    /// Human-readable key name.
    ///
    /// Special keys are named explicitly; everything else is resolved through the *current* keyboard
    /// layout, so a recorded key shows the character actually printed on it rather than a raw code.
    static func name(for keyCode: UInt32) -> String {
        let special: [UInt32: String] = [
            UInt32(kVK_Escape): "esc",
            UInt32(kVK_Return): "return",
            UInt32(kVK_Tab): "tab",
            UInt32(kVK_Space): "space",
            UInt32(kVK_Delete): "delete",
            UInt32(kVK_LeftArrow): "←",
            UInt32(kVK_RightArrow): "→",
            UInt32(kVK_UpArrow): "↑",
            UInt32(kVK_DownArrow): "↓",
        ]
        if let name = special[keyCode] { return name }
        return layoutCharacter(for: keyCode)?.uppercased() ?? "key\(keyCode)"
    }

    private static func layoutCharacter(for keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
        else { return nil }

        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        var deadKeyState: UInt32 = 0
        var length = 0
        var characters = [UniChar](repeating: 0, count: 4)

        let status = data.withUnsafeBytes { buffer -> OSStatus in
            guard let layout = buffer.bindMemory(to: UCKeyboardLayout.self).baseAddress else {
                return OSStatus(-1)
            }
            return UCKeyTranslate(
                layout,
                UInt16(keyCode),
                UInt16(kUCKeyActionDisplay),
                0,
                UInt32(LMGetKbdType()),
                UInt32(kUCKeyTranslateNoDeadKeysBit),
                &deadKeyState,
                characters.count,
                &length,
                &characters
            )
        }

        guard status == noErr, length > 0 else { return nil }
        return String(utf16CodeUnits: characters, count: length)
    }
}

/// Registers global hot keys through Carbon, the only API that still delivers system-wide hot keys
/// to a non-activating accessory app.
///
/// Allow/Deny are registered only while a request is pending, so the app never swallows ⌘Y or ⌘N
/// from the app you're actually using.
@MainActor
final class GlobalHotKeys: ObservableObject {
    static let shared = GlobalHotKeys()

    @Published var bindings: [String: KeyBinding] = [:]
    @Published var masterEnabled = true

    private var registered: [ShortcutAction: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    private var cancellables = Set<AnyCancellable>()
    private static let signature: OSType = 0x5156_5300 // 'QVS\0'

    private init() {
        loadBindings()
    }

    func start() {
        installHandler()
        refreshRegistrations(hasPendingRequests: false)

        PendingRequestRegistry.shared.$requests
            .receive(on: RunLoop.main)
            .sink { [weak self] requests in
                self?.refreshRegistrations(hasPendingRequests: !requests.isEmpty)
            }
            .store(in: &cancellables)
    }

    func binding(for action: ShortcutAction) -> KeyBinding {
        bindings[action.rawValue] ?? action.defaultBinding
    }

    func setBinding(_ binding: KeyBinding, for action: ShortcutAction) {
        bindings[action.rawValue] = binding
        persistBindings()
        refreshRegistrations(hasPendingRequests: !PendingRequestRegistry.shared.requests.isEmpty)
    }

    func resetBinding(for action: ShortcutAction) {
        bindings.removeValue(forKey: action.rawValue)
        persistBindings()
        refreshRegistrations(hasPendingRequests: !PendingRequestRegistry.shared.requests.isEmpty)
    }

    // MARK: - Registration

    private func refreshRegistrations(hasPendingRequests: Bool) {
        for (_, ref) in registered {
            UnregisterEventHotKey(ref)
        }
        registered.removeAll()

        guard masterEnabled else { return }

        for action in ShortcutAction.allCases {
            // Escape as a global hot key would break every text field on the system.
            guard action != .collapsePanel else { continue }

            // Approval shortcuts are system-wide hot keys, which means they take ⌘Y and ⌘N away
            // from every other app for as long as a request is pending — and a stray press then
            // approves something you never looked at. Off unless explicitly asked for; the panel's
            // own ⌘Y / ⌘N work regardless.
            if action.isContextual {
                guard Preferences.shared.globalApprovalShortcuts, hasPendingRequests else { continue }
            }

            register(action)
        }
    }

    private func register(_ action: ShortcutAction) {
        let binding = binding(for: action)
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(
            signature: Self.signature,
            id: UInt32(ShortcutAction.allCases.firstIndex(of: action) ?? 0)
        )

        let status = RegisterEventHotKey(
            binding.keyCode,
            UInt32(binding.modifiers),
            id,
            GetApplicationEventTarget(),
            0,
            &ref
        )

        if status == noErr, let ref {
            registered[action] = ref
        }
    }

    private func installHandler() {
        guard handler == nil else { return }

        var spec = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ -> OSStatus in
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                let index = Int(hotKeyID.id)
                guard ShortcutAction.allCases.indices.contains(index) else { return noErr }
                let action = ShortcutAction.allCases[index]
                Task { @MainActor in GlobalHotKeys.shared.perform(action) }
                return noErr
            },
            1,
            &spec,
            nil,
            &handler
        )
    }

    // MARK: - Actions

    func perform(_ action: ShortcutAction) {
        let registry = PendingRequestRegistry.shared

        switch action {
        case .allow:
            guard let request = registry.requests.first else { return }
            switch request.kind {
            case .planReview:
                registry.resolve(request.id, with: .approvePlan(autoMode: false))
            default:
                registry.resolve(request.id, with: .allow)
            }

        case .deny:
            guard let request = registry.requests.first else { return }
            switch request.kind {
            case .planReview:
                registry.resolve(request.id, with: .rejectPlan(feedback: ""))
            default:
                registry.resolve(request.id, with: .deny(reason: nil))
            }

        case .togglePanel, .sessionSwitcher:
            NotchController.shared.togglePinned()

        case .collapsePanel:
            NotchController.shared.collapse()
        }
    }

    // MARK: - Persistence

    private func loadBindings() {
        guard
            let data = UserDefaults.standard.data(forKey: "shortcutBindings"),
            let decoded = try? JSONDecoder().decode([String: KeyBinding].self, from: data)
        else { return }
        bindings = decoded
    }

    private func persistBindings() {
        guard let data = try? JSONEncoder().encode(bindings) else { return }
        UserDefaults.standard.set(data, forKey: "shortcutBindings")
    }
}
