// Ne demek? — seçili İngilizce ifadenin Türkçe anlamını, seçimin yanında küçük bir popover'da gösterir.
// Tetikleme: macOS Hizmetler menüsü (sağ tık > Hizmetler > "Ne demek?" ya da atanan kısayol).
// Hız için arka planda her zaman hazır bekleyen bir `claude` süreci tutulur ve yanıt akıtılarak gösterilir.
// Derlemek/kurmak için: ./build.sh

import AppKit
import Security

// MARK: - Ayarlar

enum Config {
    static let model = "sonnet"
    static let panelWidth: CGFloat = 320
    static let maxSelection = 1500
    static let spareMaxAge: TimeInterval = 30 * 60
    static let cacheLimit = 3000
    static let systemPrompt = """
    Sen İngilizce metin okuyan bir Türk kullanıcının cep sözlüğüsün. Kullanıcı okurken anlamadığı bir kelime, deyim, kalıp veya cümleyi seçip sana gönderir.

    Yanıtı Türkçe ve DÜZ METİN olarak ver: markdown, yıldız, başlık, madde imi, tırnak süsü veya emoji kullanma.

    Biçim:
    - İlk satır: en uygun Türkçe karşılık (kısa, birkaç kelime). Önüne etiket koyma.
    - Sonra bir boş satır ve 1-2 cümlelik açıklama: tam olarak ne anlatıyor, hangi tonda kullanılır.
    - Belirgin biçimde farklı birden fazla yaygın anlamı varsa açıklamada her birini "1)", "2)" ile ayrı satırda kısaca ver, en yaygın olanı başa koy.
    - Seçim tam bir cümleyse: ilk satır cümlenin doğal Türkçe çevirisi, sonra boş satır ve içindeki deyim ve kalıpların kısa açıklaması.

    Örnek cümle, telaffuz, soru veya ek teklif yazma. Kısa tut.
    """
}

// MARK: - Claude Code oturum anahtarı

enum Credentials {
    /// Claude Code'un keychain kaydının son değişme zamanı. Yalnızca öznitelik okunur, anahtarın kendisi okunmaz.
    /// Başka bir Claude oturumu anahtarı yenilediğinde bu zaman değişir.
    static func lastChanged() -> Date? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Claude Code-credentials",
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess else { return nil }
        return (out as? [String: Any])?[kSecAttrModificationDate as String] as? Date
    }
}

// MARK: - Claude süreci (stream-json ile tek seferlik soru)

final class ClaudeProcess {
    private let process = Process()
    private let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
    let createdAt = Date()
    /// Süreç başlarken keychain'deki anahtarın sürümü; değişmişse bu süreç eski anahtarla kalmıştır.
    let credentialsDate = Credentials.lastChanged()
    private var lineBuffer = Data()
    private var errBuffer = Data()
    private var streamed = ""
    private var done = false
    var onDelta: ((String) -> Void)?
    var onFinish: ((_ text: String?, _ error: String?, _ authFailed: Bool) -> Void)?

    var isAlive: Bool { process.isRunning && !done }

    /// Test için: NE_DEMEK_TEST_BREAK_FIRST ortam değişkeni varsa ilk süreç geçersiz anahtarla başlar.
    private static var breakNext = ProcessInfo.processInfo.environment["NE_DEMEK_TEST_BREAK_FIRST"] != nil

    init?() {
        guard let exe = ClaudeProcess.findClaude() else { return nil }
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("ne-demek", isDirectory: true)
        try? FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)

        process.executableURL = URL(fileURLWithPath: exe)
        process.currentDirectoryURL = workDir
        // Kullanıcı ayarları, hook, plugin ve MCP sunucuları yüklenmez; araç yok: hızlı ve yan etkisiz.
        process.arguments = [
            "-p", "--model", Config.model, "--effort", "low",
            "--setting-sources", "project", "--strict-mcp-config", "--tools", "",
            "--disable-slash-commands", "--no-session-persistence",
            "--input-format", "stream-json", "--output-format", "stream-json",
            "--include-partial-messages", "--verbose",
            "--system-prompt", Config.systemPrompt,
        ]
        let home = NSHomeDirectory()
        process.environment = [
            "HOME": home, "USER": NSUserName(), "LOGNAME": NSUserName(),
            "PATH": "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8", "TMPDIR": NSTemporaryDirectory(),
            "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1", "DISABLE_AUTOUPDATER": "1",
        ]
        if ClaudeProcess.breakNext {
            ClaudeProcess.breakNext = false
            process.environment?["ANTHROPIC_API_KEY"] = "invalid-test-key"
        }
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe

        // Döngüsel referanslar süreç bitince processEnded() içinde kırılır.
        outPipe.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            DispatchQueue.main.async { self.consume(data) }
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let data = h.availableData
            DispatchQueue.main.async {
                if data.isEmpty { self.errPipe.fileHandleForReading.readabilityHandler = nil }
                else if self.errBuffer.count < 4000 { self.errBuffer.append(data) }
            }
        }
        process.terminationHandler = { _ in DispatchQueue.main.async { self.processEnded() } }

        do { try process.run() } catch { return nil }
    }

    static func findClaude() -> String? {
        let home = NSHomeDirectory()
        return ["\(home)/.local/bin/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func send(_ text: String) -> Bool {
        let msg: [String: Any] = ["type": "user", "message": ["role": "user", "content": text]]
        guard var data = try? JSONSerialization.data(withJSONObject: msg) else { return false }
        data.append(0x0A)
        do { try inPipe.fileHandleForWriting.write(contentsOf: data); return true } catch { return false }
    }

    func terminate() {
        onDelta = nil
        onFinish = nil
        done = true
        if process.isRunning { process.terminate() }
    }

    private func consume(_ data: Data) {
        if data.isEmpty { outPipe.fileHandleForReading.readabilityHandler = nil; return }
        lineBuffer.append(data)
        while let nl = lineBuffer.firstIndex(of: 0x0A) {
            let line = lineBuffer.subdata(in: lineBuffer.startIndex..<nl)
            lineBuffer.removeSubrange(lineBuffer.startIndex...nl)
            handleLine(line)
        }
    }

    private func handleLine(_ line: Data) {
        guard !done,
              let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              let type = obj["type"] as? String else { return }
        switch type {
        case "stream_event":
            if let ev = obj["event"] as? [String: Any], ev["type"] as? String == "content_block_delta",
               let delta = ev["delta"] as? [String: Any], delta["type"] as? String == "text_delta",
               let t = delta["text"] as? String {
                streamed += t
                onDelta?(streamed)
            }
        case "result":
            let isError = obj["is_error"] as? Bool ?? false
            let text = (obj["result"] as? String) ?? ""
            if isError {
                let status = obj["api_error_status"] as? Int
                let lower = text.lowercased()
                let auth = status == 401 || status == 403
                    || ["authenticate", "oauth", "api key", "not logged in"].contains { lower.contains($0) }
                finish(nil, text.isEmpty ? "Bilinmeyen bir hata oluştu." : text, authFailed: auth)
            } else {
                finish(text.isEmpty ? streamed : text, nil)
            }
            try? inPipe.fileHandleForWriting.close()
        default:
            break
        }
    }

    private func processEnded() {
        if !done {
            let err = String(data: errBuffer, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            finish(nil, err.isEmpty ? "Claude beklenmedik şekilde kapandı." : err)
        }
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        process.terminationHandler = nil
    }

    private func finish(_ text: String?, _ error: String?, authFailed: Bool = false) {
        guard !done else { return }
        done = true
        let cb = onFinish
        onDelta = nil
        onFinish = nil
        cb?(text, error, authFailed)
    }
}

// MARK: - Açıklayıcı: hazır bekleyen süreç + önbellek

final class Explainer {
    private var spare: ClaudeProcess?
    private var active: ClaudeProcess?
    private var cache: [String: String] = [:]
    private let cacheURL: URL
    private var timer: Timer?

    init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NeDemek", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        cacheURL = dir.appendingPathComponent("cache.json")
        if let data = try? Data(contentsOf: cacheURL),
           let saved = try? JSONDecoder().decode([String: String].self, from: data) {
            cache = saved
        }
        prewarm()
        // Anahtar değişimi ucuz bir öznitelik sorgusuyla kontrol edilir; bekleyen süreç sıcak ve geçerli kalır.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.prewarm() }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                          queue: .main) { [weak self] _ in self?.prewarm() }
    }

    /// Bekleyen süreç hâlâ kullanılabilir mi: çalışıyor, çok eski değil ve başladığından beri anahtar yenilenmemiş.
    private func isFresh(_ p: ClaudeProcess) -> Bool {
        p.isAlive && Date().timeIntervalSince(p.createdAt) < Config.spareMaxAge
            && p.credentialsDate == Credentials.lastChanged()
    }

    /// Bir sonraki soru için hazır `claude` süreci tutar; eskiyen, ölen veya eski anahtarla kalan süreci yeniler.
    func prewarm() {
        if let s = spare, isFresh(s) { return }
        spare?.terminate()
        spare = ClaudeProcess()
    }

    func explain(_ text: String, onUpdate: @escaping (String, Bool) -> Void, onError: @escaping (String) -> Void) {
        cancel()
        let key = text.lowercased()
        if let hit = cache[key] { onUpdate(hit, true); return }
        ask(text, key: key, canRetry: true, onUpdate: onUpdate, onError: onError)
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.prewarm() }
    }

    private func ask(_ text: String, key: String, canRetry: Bool,
                     onUpdate: @escaping (String, Bool) -> Void, onError: @escaping (String) -> Void) {
        let p: ClaudeProcess
        if let s = spare, isFresh(s) {
            p = s
        } else {
            spare?.terminate()
            guard let fresh = ClaudeProcess() else {
                onError("Claude Code bulunamadı. Terminal'de `claude` komutunun çalıştığından emin ol.")
                return
            }
            p = fresh
        }
        spare = nil
        active = p
        p.onDelta = { onUpdate($0, false) }
        p.onFinish = { [weak self] answer, error, authFailed in
            guard let self, self.active === p else { return }
            self.active = nil
            if let answer, !answer.isEmpty {
                self.store(key, answer)
                onUpdate(answer, true)
            } else if authFailed && canRetry {
                // Süreç, başka bir Claude oturumunun yenilediği eski anahtarla kalmış olabilir: taze süreçle bir kez daha dene.
                NSLog("NeDemek: kimlik hatası, taze süreçle yeniden deneniyor: %@", error ?? "")
                self.ask(text, key: key, canRetry: false, onUpdate: onUpdate, onError: onError)
            } else {
                onError(Explainer.friendly(error, authFailed: authFailed))
            }
        }
        if !p.send(text) { p.terminate(); active = nil; onError("Claude'a ulaşılamadı.") }
    }

    func cancel() {
        active?.terminate()
        active = nil
    }

    private func store(_ key: String, _ answer: String) {
        if cache.count >= Config.cacheLimit, let first = cache.keys.first { cache.removeValue(forKey: first) }
        cache[key] = answer
        let snapshot = cache, url = cacheURL
        DispatchQueue.global(qos: .utility).async {
            if let data = try? JSONEncoder().encode(snapshot) { try? data.write(to: url, options: .atomic) }
        }
    }

    private static func friendly(_ error: String?, authFailed: Bool) -> String {
        let e = error ?? ""
        if authFailed || e.localizedCaseInsensitiveContains("not logged in") || e.contains("/login") {
            return "Claude Code oturumu geçersiz. Terminal'de `claude` yazıp tekrar giriş yap."
        }
        return e.isEmpty ? "Yanıt alınamadı." : "Yanıt alınamadı: \(e.prefix(300))"
    }
}

// MARK: - Popover penceresi

final class LookupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class PopoverController {
    private let panel: LookupPanel
    private let titleLabel = NSTextField(wrappingLabelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let stack = NSStackView()
    private var anchor = NSPoint.zero
    private var screenFrame = NSRect.zero
    private var above = false
    private var monitors: [Any] = []
    private var answer = ""

    init() {
        panel = LookupPanel(contentRect: NSRect(x: 0, y: 0, width: Config.panelWidth, height: 60),
                            styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false

        let effect = NSVisualEffectView()
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.maskImage = PopoverController.roundedMask(radius: 14)
        panel.contentView = effect

        let inner = Config.panelWidth - 30
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .labelColor
        titleLabel.maximumNumberOfLines = 3
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.cell?.truncatesLastVisibleLine = true
        titleLabel.preferredMaxLayoutWidth = inner
        bodyLabel.isSelectable = true
        bodyLabel.preferredMaxLayoutWidth = inner

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 7
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 15, bottom: 13, right: 15)
        stack.translatesAutoresizingMaskIntoConstraints = false
        [titleLabel, spinner, bodyLabel].forEach(stack.addArrangedSubview)
        effect.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            stack.topAnchor.constraint(equalTo: effect.topAnchor),
            stack.widthAnchor.constraint(equalToConstant: Config.panelWidth),
            titleLabel.widthAnchor.constraint(equalToConstant: inner),
            bodyLabel.widthAnchor.constraint(equalToConstant: inner),
        ])

        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel,
                                               queue: .main) { [weak self] _ in self?.close() }
    }

    func show(title: String, at point: NSPoint) {
        anchor = point
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main
        screenFrame = screen?.visibleFrame ?? .zero
        above = point.y - screenFrame.minY < 260

        titleLabel.stringValue = title
        answer = ""
        bodyLabel.attributedStringValue = NSAttributedString()
        bodyLabel.isHidden = true
        spinner.isHidden = false
        spinner.startAnimation(nil)
        relayout()

        if !panel.isVisible {
            panel.alphaValue = 0
            panel.orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                panel.animator().alphaValue = 1
            }
        }
        panel.makeKey()
        installMonitors()
    }

    func update(_ raw: String) {
        answer = PopoverController.clean(raw)
        guard !answer.isEmpty else { return }
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        bodyLabel.isHidden = false
        bodyLabel.attributedStringValue = PopoverController.format(answer)
        relayout()
    }

    func showError(_ message: String) {
        answer = message
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        bodyLabel.isHidden = false
        bodyLabel.attributedStringValue = NSAttributedString(string: message, attributes: [
            .font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.secondaryLabelColor,
        ])
        relayout()
    }

    /// Test için: popover içeriğini koyu bir zemine çizip PNG olarak kaydeder.
    func snapshot(to path: String) {
        guard let view = panel.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        let size = view.bounds.size
        let out = NSImage(size: NSSize(width: size.width + 40, height: size.height + 40), flipped: false) { _ in
            NSColor(white: 0.12, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: size.width + 40, height: size.height + 40).fill()
            NSColor(white: 0.2, alpha: 0.96).setFill()
            NSBezierPath(roundedRect: NSRect(x: 20, y: 20, width: size.width, height: size.height), xRadius: 14, yRadius: 14).fill()
            rep.draw(in: NSRect(x: 20, y: 20, width: size.width, height: size.height))
            return true
        }
        if let tiff = out.tiffRepresentation, let bmp = NSBitmapImageRep(data: tiff),
           let png = bmp.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }

    func close() {
        guard panel.isVisible else { return }
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.08
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in self?.panel.orderOut(nil) })
    }

    private func relayout() {
        stack.layoutSubtreeIfNeeded()
        let w = Config.panelWidth
        let h = ceil(stack.fittingSize.height)
        let x = min(max(anchor.x - 24, screenFrame.minX + 8), screenFrame.maxX - w - 8)
        var y: CGFloat
        if above {
            y = min(anchor.y + 14, screenFrame.maxY - 8 - h)       // alt kenar sabit, yukarı büyür
        } else {
            y = max(anchor.y - 20 - h, screenFrame.minY + 8)       // üst kenar sabit, aşağı büyür
        }
        panel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        panel.invalidateShadow()
    }

    private func installMonitors() {
        guard monitors.isEmpty else { return }
        // Başka bir yere tıklama / kaydırma popover'ı kapatır (Look Up gibi).
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel],
                                                     handler: { [weak self] _ in self?.close() }) {
            monitors.append(m)
        }
        // ⌘C: seçili kısmı ya da tüm açıklamayı kopyalar; diğer tuşlar kapatır.
        if let m = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: { [weak self] event in
            guard let self else { return event }
            if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "c" {
                if let tv = self.panel.firstResponder as? NSTextView, tv.selectedRange().length > 0 {
                    tv.copy(nil)
                } else if !self.answer.isEmpty {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(self.answer, forType: .string)
                }
                return nil
            }
            self.close()
            return nil
        }) {
            monitors.append(m)
        }
    }

    private static func clean(_ raw: String) -> String {
        raw.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "(?m)^#+\\s*", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// İlk satır (Türkçe karşılık) belirgin, açıklama ikincil renkte.
    private static func format(_ text: String) -> NSAttributedString {
        let parts = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let head = String(parts[0])
        let rest = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""

        let out = NSMutableAttributedString()
        let headStyle = NSMutableParagraphStyle()
        headStyle.paragraphSpacing = rest.isEmpty ? 0 : 5
        out.append(NSAttributedString(string: rest.isEmpty ? head : head + "\n", attributes: [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: NSColor.labelColor, .paragraphStyle: headStyle,
        ]))
        if !rest.isEmpty {
            let bodyStyle = NSMutableParagraphStyle()
            bodyStyle.lineSpacing = 2
            bodyStyle.paragraphSpacing = 3
            out.append(NSAttributedString(string: rest, attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: bodyStyle,
            ]))
        }
        return out
    }

    private static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

// MARK: - Uygulama

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var explainer: Explainer!
    private var popover: PopoverController!
    private var requestID = 0

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSApp.servicesProvider = self
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        explainer = Explainer()
        popover = PopoverController()
        NSUpdateDynamicServices()
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--lookup"), i + 1 < args.count { present(args[i + 1]) }
    }

    /// Hizmetler menüsünden gelen çağrı (Info.plist > NSServices > NSMessage = lookUp).
    @objc(lookUp:userData:error:)
    func lookUp(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let text = pboard.string(forType: .string) else { return }
        present(text)
    }

    private func present(_ raw: String) {
        let text = String(raw.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(Config.maxSelection))
        guard !text.isEmpty else { return }
        requestID += 1
        let id = requestID
        popover.show(title: text, at: NSEvent.mouseLocation)
        explainer.explain(text, onUpdate: { [weak self] answer, done in
            guard let self, self.requestID == id else { return }
            self.popover.update(answer)
            if done { self.snapshotIfRequested() }
        }, onError: { [weak self] message in
            guard let self, self.requestID == id else { return }
            self.popover.showError(message)
            self.snapshotIfRequested()
        })
    }

    private func snapshotIfRequested() {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--snapshot"), i + 1 < args.count else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            self.popover.snapshot(to: args[i + 1])
            NSApp.terminate(nil)
        }
    }
}

signal(SIGPIPE, SIG_IGN)
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
