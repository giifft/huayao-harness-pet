import AppKit
import ApplicationServices

/// Observes the visible chat through macOS Accessibility. Chat text is only
/// used to compute an in-memory fingerprint and is never shown or written.
final class DoubaoReader {
    struct ChatSample: Equatable {
        let conversation: URL
        let fingerprint: Int
    }

    enum Observation {
        case closed, permissionNeeded, chatUnavailable
        case chat(ChatSample)
    }

    private var lastSample: ChatSample?
    private var lastChange: Date?
    private var streaming = false
    private let quietInterval: TimeInterval = 7

    func refresh(now: Date = Date()) -> AgentStatus {
        update(observe(), now: now)
    }

    func update(_ observation: Observation, now: Date) -> AgentStatus {
        guard case let .chat(sample) = observation else {
            lastSample = nil
            lastChange = nil
            streaming = false
            switch observation {
            case .closed:
                return AgentStatus(connectionMessage: "请打开豆包客户端")
            case .permissionNeeded:
                return AgentStatus(connectionMessage: "请在系统设置中授权辅助功能")
            default:
                return AgentStatus(connectionMessage: "请打开豆包普通对话")
            }
        }

        defer { lastSample = sample }
        guard let previous = lastSample, previous.conversation == sample.conversation else {
            lastChange = nil
            streaming = false
            return AgentStatus(state: .idle)
        }
        if let lastChange, now.timeIntervalSince(lastChange) >= quietInterval {
            self.lastChange = nil
            streaming = false
        }
        if sample != previous {
            // A single change can come from sending a message or reloading
            // the page. Require continued updates before reporting activity.
            streaming = lastChange != nil
            lastChange = now
        }
        if streaming, let lastChange {
            return AgentStatus(state: .working, toolDetail: "正在回话", lastActivity: lastChange)
        }
        return AgentStatus(state: .idle)
    }

    private func observe() -> Observation {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.bot.pc.doubao")
            .first(where: { !$0.isTerminated }) else { return .closed }
        guard app.isActive else { return .chatUnavailable }
        guard AXIsProcessTrusted() else { return .permissionNeeded }

        let application = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(application, 0.25)
        guard let window: AXUIElement = attribute(application, kAXMainWindowAttribute),
              attribute(window, kAXMinimizedAttribute) != true else { return .chatUnavailable }

        guard let page = find(in: window, limit: 40, where: { role($0) == "AXWebArea" }),
              let url: URL = attribute(page, kAXURLAttribute),
              url.scheme == "chrome", url.host == "doubao-chat",
              url.pathComponents.count == 3, url.pathComponents[1] == "chat",
              let editor = find(in: page, limit: 180, where: isChatEditor),
              let fingerprint = transcriptFingerprint(editor) else { return .chatUnavailable }
        guard app.isActive else { return .chatUnavailable }
        return .chat(ChatSample(conversation: url, fingerprint: fingerprint))
    }

    private func isChatEditor(_ element: AXUIElement) -> Bool {
        guard role(element) == kAXGroupRole else { return false }
        let description: String? = attribute(element, kAXDescriptionAttribute)
        let title: String? = attribute(element, kAXTitleAttribute)
        return description == "doc_editor" || title == "doc_editor"
            || attribute(element, kAXIdentifierAttribute) == "doc_editor"
    }

    private func transcriptFingerprint(_ editor: AXUIElement) -> Int? {
        var pending = [editor]
        var remaining = 300
        var count = 0
        var hash = Hasher()
        while remaining > 0, count < 40, let element = pending.popLast() {
            remaining -= 1
            switch role(element) {
            case kAXStaticTextRole:
                if let text: String = attribute(element, kAXValueAttribute) {
                    hash.combine(text)
                    count += 1
                }
            case kAXGroupRole, kAXHeadingRole, kAXListRole, "AXListItem", kAXScrollAreaRole:
                pending.append(contentsOf: children(element).suffix(40))
            default:
                break
            }
        }
        return count == 0 ? nil : hash.finalize()
    }

    private func find(in root: AXUIElement, limit: Int, where matches: (AXUIElement) -> Bool) -> AXUIElement? {
        var pending = [root]
        var index = 0
        while index < pending.count, index < limit {
            let element = pending[index]
            index += 1
            if matches(element) { return element }
            let available = limit - pending.count
            if available > 0 { pending.append(contentsOf: children(element).prefix(available)) }
        }
        return nil
    }

    private func role(_ element: AXUIElement) -> String? { attribute(element, kAXRoleAttribute) }

    private func children(_ element: AXUIElement) -> [AXUIElement] {
        attribute(element, kAXChildrenAttribute) ?? []
    }

    private func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value as? T
    }
}
