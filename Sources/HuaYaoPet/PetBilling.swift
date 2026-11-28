import AppKit
import CryptoKit
import Security

private struct BalanceDay: Codable {
    let opening: Decimal
    let first: Date
    var closing: Decimal
    var last: Date
    var decrease: Decimal = 0
    var increase: Decimal = 0
    var postedCredits: Decimal?
    var otherDebits: Decimal?
    var correctedAmount: Decimal?
    var decreaseAtCorrection: Decimal?

    var observed: Decimal {
        if let correctedAmount, let decreaseAtCorrection { return correctedAmount + decrease - decreaseAtCorrection }
        return decrease
    }

    var needsReview: Bool { increase > (postedCredits ?? 0) }
    var startedLate: Bool { first.timeIntervalSince(HarnessPricing.calendar.startOfDay(for: first)) > 600 }
}

private struct DeepSeekBalance: Decodable {
    struct Wallet: Decodable {
        let currency: String
        let total_balance: String
    }
    let balance_infos: [Wallet]
}

private enum BillingCredential {
    static let service = "local.huayao.desktoppet.DeepSeekBalance"
    static let account = "DeepSeek API"
    static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    static func read() -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String?) -> Bool {
        guard let value else {
            let status = SecItemDelete(query as CFDictionary)
            return status == errSecSuccess || status == errSecItemNotFound
        }
        let data = Data(value.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status != errSecItemNotFound { return status == errSecSuccess }
        var request = query
        request[kSecValueData as String] = data
        request[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(request as CFDictionary, nil) == errSecSuccess
    }
}

private final class BillingNoRedirect: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

final class PetBilling {
    var roundCompleted: ((String, String) -> Void)?
    var balanceWarning: ((Bool, String) -> Void)?
    var budgetWarning: ((String) -> Void)?

    private let defaults = UserDefaults.standard
    private let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.urlCredentialStorage = nil
        configuration.httpCookieStorage = nil
        return URLSession(configuration: configuration, delegate: BillingNoRedirect(), delegateQueue: nil)
    }()
    private static let dayFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
    private var books: [String: [String: BalanceDay]] = [:]
    private var account: String?
    private var wallet: String?
    private var credential: String?
    private var usage: HarnessUsageSummary?
    private var announcedRounds: Set<String> = []
    private var warnedDay: String?
    private var startedAt = Date()
    private var lastAttempt = Date.distantPast
    private var timer: Timer?
    private var request: Task<Void, Never>?
    private var requestID: UUID?
    private var panel: NSWindow?
    private var overview: NSTextField?
    private var history: NSTextView?
    private var status = ""

    private var lowLimit: Decimal {
        get { limit("balanceLowLimit", fallback: 5) }
        set { defaults.set(NSDecimalNumber(decimal: newValue).stringValue, forKey: "balanceLowLimit") }
    }
    private var budget: Decimal {
        get { limit("balanceDailyBudget", fallback: 10) }
        set { defaults.set(NSDecimalNumber(decimal: newValue).stringValue, forKey: "balanceDailyBudget") }
    }

    func start() {
        credential = BillingCredential.read()
        if let data = defaults.data(forKey: "balanceHistory"),
           let saved = try? JSONDecoder().decode([String: [String: BalanceDay]].self, from: data) {
            books = saved
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.refresh() }
        refresh()
    }

    func stop() {
        timer?.invalidate()
        request?.cancel()
        session.invalidateAndCancel()
    }

    func observe(_ summary: HarnessUsageSummary?) {
        guard let summary else { return }
        usage = summary
        if let round = summary.latestRound, round.completedAt >= startedAt, announcedRounds.insert(round.id).inserted {
            let cost = round.estimatedCost.map { "约 ¥\(format($0))" } ?? "缺少适用单价"
            roundCompleted?(cost, round.models.joined(separator: "、"))
        }
        checkBudget()
        render()
    }

    func refreshFromPet() {
        guard Date().timeIntervalSince(lastAttempt) >= 5 else { return }
        refresh()
    }

    func refresh() {
        guard let credential, request == nil else { render(); return }
        lastAttempt = Date()
        status = "正在查询 DeepSeek 余额…"
        render()
        var query = URLRequest(url: URL(string: "https://api.deepseek.com/user/balance")!)
        query.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        let requestID = UUID()
        self.requestID = requestID
        request = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { if self.requestID == requestID { request = nil; render() } }
            do {
                let (data, response) = try await session.data(for: query)
                guard !Task.isCancelled, self.requestID == requestID else { return }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    status = "余额查询失败，请检查 API 密钥与账户状态。"
                    return
                }
                let items = try JSONDecoder().decode(DeepSeekBalance.self, from: data).balance_infos
                let valid = items.filter { ["CNY", "USD"].contains($0.currency) }
                guard let item = valid.first(where: { $0.currency == "CNY" }) ?? valid.first,
                      let amount = Decimal(string: item.total_balance, locale: Locale(identifier: "en_US_POSIX")),
                      amount >= 0 else {
                    status = "DeepSeek 暂未返回可用余额。"
                    return
                }
                let hash = SHA256.hash(data: Data(credential.utf8)).map { String(format: "%02x", $0) }.joined()
                wallet = item.currency
                account = "\(hash)-\(item.currency)"
                record(amount, at: Date())
                balanceWarning?(lowLimit > 0 && amount < lowLimit, money(amount, item.currency))
                checkBudget()
                status = "余额已更新 · \(Date().formatted(date: .omitted, time: .shortened))"
            } catch {
                if !Task.isCancelled, self.requestID == requestID {
                    status = "余额查询失败，请稍后重试。"
                }
            }
        }
    }

    private func record(_ amount: Decimal, at date: Date) {
        guard let account else { return }
        let day = Self.dayFormat.string(from: date)
        var book = books[account, default: [:]]
        var row = book[day] ?? BalanceDay(opening: amount, first: date, closing: amount, last: date)
        guard date >= row.last else { return }
        let delta = row.closing - amount
        if delta > 0 { row.decrease += delta }
        if delta < 0 { row.increase -= delta }
        row.closing = amount
        row.last = date
        book[day] = row
        books[account] = book
        saveHistory()
    }

    private func saveHistory() {
        if let data = try? JSONEncoder().encode(books) { defaults.set(data, forKey: "balanceHistory") }
    }

    private func checkBudget() {
        guard budget > 0 else { return }
        let day = Self.dayFormat.string(from: Date())
        let observed = wallet == "CNY" ? account.flatMap { books[$0]?[day]?.observed } : nil
        let estimate = usage.flatMap { $0.day == day ? $0.todayKnownCost : nil }
        guard warnedDay != day, let spend = observed ?? estimate, spend >= budget else { return }
        warnedDay = day
        budgetWarning?(money(spend, "CNY"))
    }

    @objc private func updateNow() { refreshFromPet() }

    @objc private func configureCredential() {
        let alert = NSAlert()
        alert.messageText = "DeepSeek 余额查询"
        alert.informativeText = "API 密钥存入本机钥匙串，查询时仅发往 api.deepseek.com。照常使用 Harness 不需要填写密钥。"
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 330, height: 25))
        field.placeholderString = "输入 DeepSeek API 密钥"
        alert.accessoryView = field
        alert.addButton(withTitle: "保存并查询")
        alert.addButton(withTitle: "取消")
        alert.addButton(withTitle: "移除密钥")
        alert.window.initialFirstResponder = field
        let result = alert.runModal()
        let key = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result == .alertThirdButtonReturn || result == .alertFirstButtonReturn else { return }
        if result == .alertFirstButtonReturn,
           key.range(of: #"^[A-Za-z0-9._-]{1,256}$"#, options: .regularExpression) == nil {
            status = "请输入有效的 DeepSeek API 密钥。"; render(); return
        }
        let replacement = result == .alertThirdButtonReturn ? nil : key
        guard BillingCredential.write(replacement) else {
            status = "无法更新钥匙串，请检查系统授权。"
            render()
            return
        }
        request?.cancel()
        request = nil
        requestID = nil
        credential = replacement
        account = nil
        wallet = nil
        status = ""
        balanceWarning?(false, "")
        refresh()
    }

    @objc private func configureLimits() {
        let alert = NSAlert()
        alert.messageText = "余额预警与每日预算"
        alert.informativeText = "余额预警使用账户币种；每日预算使用 CNY。填 0 可关闭相应提醒。"
        let low = NSTextField(string: format(lowLimit))
        let daily = NSTextField(string: format(budget))
        let fields = NSStackView(views: [NSTextField(labelWithString: "低余额预警"), low,
                                        NSTextField(labelWithString: "每日预算（CNY）"), daily])
        fields.orientation = .vertical
        fields.alignment = .leading
        fields.frame.size = NSSize(width: 270, height: 94)
        alert.accessoryView = fields
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let lowValue = parse(low.stringValue), let dailyValue = parse(daily.stringValue) else {
            status = "请输入有效的非负金额。"; render(); return
        }
        lowLimit = lowValue
        budget = dailyValue
        warnedDay = nil
        checkBudget()
        refresh()
    }

    @objc private func reconcile() {
        guard let account, let wallet else { status = "连接账户后可校正观测账本。"; render(); return }
        let alert = NSAlert()
        alert.messageText = "校正观测账本"
        alert.informativeText = "按北京时间选择观测日期，填入该观测区间内到账金额和其他非消费扣减。校正后消费＝期初余额－当前余额＋到账－其他扣减。"
        let day = NSTextField(string: Self.dayFormat.string(from: Date()))
        let credits = NSTextField(string: "0")
        let debits = NSTextField(string: "0")
        let stack = NSStackView(views: [NSTextField(labelWithString: "日期"), day, NSTextField(labelWithString: "到账金额"),
                                       credits, NSTextField(labelWithString: "其他扣减"), debits])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.frame.size = NSSize(width: 280, height: 142)
        alert.accessoryView = stack
        alert.addButton(withTitle: "保存校正")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard var row = books[account]?[day.stringValue],
              let credit = parse(credits.stringValue), let debit = parse(debits.stringValue),
              row.opening - row.closing + credit - debit >= 0 else {
            status = "该日没有余额观测，或金额无法对账。"; render(); return
        }
        row.postedCredits = credit
        row.otherDebits = debit
        row.correctedAmount = row.opening - row.closing + credit - debit
        row.decreaseAtCorrection = row.decrease
        books[account]?[day.stringValue] = row
        saveHistory()
        status = "\(day.stringValue) 已校正为 \(money(row.observed, wallet))。"
        checkBudget()
        render()
    }

    @objc private func openConsole() {
        NSWorkspace.shared.open(URL(string: "https://platform.deepseek.com/usage")!)
    }

    @objc private func copyLedger() {
        guard let content = history?.string else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(content, forType: .string)
        status = "已复制账本。"
        render()
    }

    func open() {
        if panel == nil {
            let info = NSTextField(wrappingLabelWithString: "")
            info.font = .systemFont(ofSize: 13)
            let log = NSTextView()
            log.isEditable = false
            log.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            log.isVerticallyResizable = true
            log.autoresizingMask = [.width]
            log.textContainer?.widthTracksTextView = true
            let scroll = NSScrollView()
            scroll.hasVerticalScroller = true
            scroll.borderType = .bezelBorder
            scroll.documentView = log
            scroll.translatesAutoresizingMaskIntoConstraints = false
            let buttons = NSStackView(views: [
                NSButton(title: "刷新", target: self, action: #selector(updateNow)),
                NSButton(title: "API 密钥…", target: self, action: #selector(configureCredential)),
                NSButton(title: "提醒设置…", target: self, action: #selector(configureLimits)),
                NSButton(title: "余额校正…", target: self, action: #selector(reconcile)),
                NSButton(title: "DeepSeek 用量", target: self, action: #selector(openConsole)),
                NSButton(title: "复制账本", target: self, action: #selector(copyLedger)),
            ])
            let stack = NSStackView(views: [info, buttons, scroll])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 12
            stack.translatesAutoresizingMaskIntoConstraints = false
            let content = NSView()
            content.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 18),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -18),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
                scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
                info.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            ])
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 570, height: 410),
                                  styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
            window.title = "花妖 · 用量与余额"
            window.minSize = NSSize(width: 565, height: 330)
            window.contentView = content
            window.isReleasedWhenClosed = false
            window.center()
            panel = window
            overview = info
            history = log
        }
        render()
        NSApp.activate(ignoringOtherApps: true)
        panel?.makeKeyAndOrderFront(nil)
        refreshFromPet()
    }

    private func render() {
        guard let overview else { return }
        let day = Self.dayFormat.string(from: Date())
        let row = account.flatMap { books[$0]?[day] }
        let currency = wallet ?? "CNY"
        let balance = row.map { money($0.closing, currency) } ?? "—"
        let observed = row.map {
            money($0.observed, currency) + ($0.needsReview ? "（待核对）" : $0.startedLate ? "（部分时段）" : "")
        } ?? "—"
        var lines = ["DeepSeek 余额  \(balance)　今日已观测消费  \(observed)"]
        if let usage {
            lines.append("今日 Harness 已观测 \(usage.todayRoundCount) 轮 · \(usage.todayTokens) tokens · 已有单价约 ¥\(format(usage.todayKnownCost))")
            if usage.todayUnpricedRoundCount > 0 { lines.append("\(usage.todayUnpricedRoundCount) 轮包含尚无适用单价的用量。") }
            if let round = usage.latestRound {
                let cost = round.estimatedCost.map { "约 ¥\(format($0))" } ?? "缺少适用单价"
                lines.append("最近一轮  \(cost) · \(round.tokens) tokens · \(round.models.joined(separator: "、"))")
            }
            let countdown = usage.nextPricingChange.map { " · 约 \(max(0, Int($0.timeIntervalSinceNow / 60))) 分钟后切换" } ?? ""
            lines.append("DeepSeek \(usage.pricingPeriod.label)\(countdown)（北京时间）")
            if usage.scanPending { lines.append("尚有会话待汇总。") }
        } else {
            lines.append("今日 Harness 用量  —")
        }
        lines.append(status.isEmpty ? (credential == nil ? "添加密钥后每 60 秒刷新；点击立绘可手动查询。" : "等待余额查询。") : status)
        overview.stringValue = lines.joined(separator: "\n")
        let time = DateFormatter()
        time.timeZone = HarnessPricing.beijing
        time.dateFormat = "HH:mm"
        var rows = ["DeepSeek 余额观测（北京时间）"]
        for entry in books.sorted(by: { ($0.key == account ? "" : $0.key) < ($1.key == account ? "" : $1.key) }) {
            let currency = String(entry.key.suffix(3))
            rows.append(entry.key == account ? "当前账户 · \(currency)" : "历史账户 · \(entry.key.prefix(8)) · \(currency)")
            rows += entry.value.sorted { $0.key > $1.key }.map { day, item in
                let tag = item.needsReview ? "待核对" : item.postedCredits != nil ? "已校正" : "余额观测"
                let range = "\(time.string(from: item.first))–\(time.string(from: item.last))"
                return "\(day)  \(money(item.observed, currency))  \(tag)  \(range)"
            }
        }
        if rows.count == 1 { rows.append("连接 DeepSeek 后显示余额观测账本。") }
        if let usage, !usage.history.isEmpty {
            rows += ["", "Harness 本地用量估算"]
            rows += usage.history.map {
                "\($0.day)  \($0.roundCount) 轮  \($0.tokens) tokens  约 ¥\(format($0.knownCost))" +
                    ($0.unpricedRoundCount == 0 ? "" : "  · \($0.unpricedRoundCount) 轮单价未知")
            }
            rows += ["", "最近各轮"]
            rows += usage.recentRounds.map {
                let cost = $0.estimatedCost.map { "约 ¥\(format($0))" } ?? "单价未知"
                let stamp = HarnessPricing.day($0.completedAt) + " " + time.string(from: $0.completedAt)
                return "\(stamp)  \($0.tokens) tokens  \(cost)  \($0.models.joined(separator: "、"))"
            }
        }
        history?.string = rows.joined(separator: "\n")
    }

    private func parse(_ text: String) -> Decimal? {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard input.range(of: #"^\d+(?:\.\d{1,8})?$"#, options: .regularExpression) != nil,
              let value = Decimal(string: input, locale: Locale(identifier: "en_US_POSIX")), value <= 1_000_000_000 else { return nil }
        return value
    }

    private func limit(_ key: String, fallback: Decimal) -> Decimal { defaults.string(forKey: key).flatMap(parse) ?? fallback }
    private func format(_ amount: Decimal) -> String {
        var rounded = Decimal()
        var input = amount
        NSDecimalRound(&rounded, &input, 8, .plain)
        return NSDecimalNumber(decimal: rounded).stringValue
    }
    private func money(_ amount: Decimal, _ currency: String) -> String { "\(currency == "CNY" ? "¥" : "USD ")\(format(amount))" }
}
