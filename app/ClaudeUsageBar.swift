import SwiftUI
import AppKit
import WebKit
import Carbon

// Main entry point
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var popover: NSPopover!
    var usageManager: UsageManager!
    var eventMonitor: Any?
    var hotKeyRef: EventHotKeyRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // NSUserNotification (deprecated but works without permissions for unsigned apps)
        NSLog("✅ App launched, notifications ready")

        // Create status bar item with variable length for compact display
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            // Create Claude logo as initial icon
            updateStatusIcon(percentage: 0)
            button.action = #selector(handleClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.target = self

            // Force the button to be visible
            button.appearsDisabled = false
            button.isEnabled = true
        }

        // Initialize usage manager
        usageManager = UsageManager(statusItem: statusItem, delegate: self)

        // Create popover
        popover = NSPopover()
        popover.contentSize = NSSize(width: 360, height: 300)
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = NSHostingController(rootView: UsageView(usageManager: usageManager))

        // Fetch initial data
        usageManager.fetchUsage()

        // Set up timer to refresh every 5 minutes
        Timer.scheduledTimer(withTimeInterval: 300, repeats: true) { _ in
            self.usageManager.fetchUsage()
        }

        // Set up Cmd+U keyboard shortcut
        setupKeyboardShortcut()
    }

    func setupKeyboardShortcut() {
        // Check Accessibility permissions
        checkAccessibilityPermissions()

        // Only register if user has the shortcut enabled
        if usageManager.shortcutEnabled {
            registerGlobalHotKey()
        }
    }

    func setShortcutEnabled(_ enabled: Bool) {
        if enabled {
            registerGlobalHotKey()
        } else {
            unregisterGlobalHotKey()
        }
    }

    func checkAccessibilityPermissions() {
        // Check if app has Accessibility permissions
        let trusted = AXIsProcessTrusted()

        if !trusted {
            NSLog("⚠️ Accessibility permissions not granted")
            // Show alert to guide user
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                let alert = NSAlert()
                alert.messageText = "Accessibility Permission Required"
                alert.informativeText = "ClaudeUsageBar needs Accessibility permission to use the Cmd+U keyboard shortcut.\n\nPlease enable it in:\nSystem Settings → Privacy & Security → Accessibility"
                alert.alertStyle = .informational
                alert.addButton(withTitle: "Open System Settings")
                alert.addButton(withTitle: "Skip for Now")

                let response = alert.runModal()
                if response == .alertFirstButtonReturn {
                    // Open System Settings
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                }
            }
        } else {
            NSLog("✅ Accessibility permissions granted")
        }
    }

    func registerGlobalHotKey() {
        // Guard against double registration
        if hotKeyRef != nil { return }

        var hotKeyID = EventHotKeyID()
        // Use simple numeric ID instead of FourCharCode
        hotKeyID.signature = 0x436C5542 // 'ClUB' as hex
        hotKeyID.id = 1

        // Cmd+U key code
        let keyCode: UInt32 = 32 // 'U' key
        let modifiers: UInt32 = UInt32(cmdKey)

        // Create event spec for hotkey
        var eventType = EventTypeSpec()
        eventType.eventClass = OSType(kEventClassKeyboard)
        eventType.eventKind = OSType(kEventHotKeyPressed)

        // Install event handler
        var handler: EventHandlerRef?
        let callback: EventHandlerUPP = { (nextHandler, event, userData) -> OSStatus in
            // Get the AppDelegate instance
            let appDelegate = Unmanaged<AppDelegate>.fromOpaque(userData!).takeUnretainedValue()

            // Toggle popover
            DispatchQueue.main.async {
                appDelegate.togglePopover()
            }

            return noErr
        }

        // Install the handler
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &eventType, selfPtr, &handler)

        // Register the hotkey
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)

        if status == noErr {
            NSLog("✅ Registered Cmd+U hotkey successfully")
        } else {
            NSLog("❌ Failed to register hotkey, status: \(status)")
        }
    }

    func unregisterGlobalHotKey() {
        if let hotKey = hotKeyRef {
            UnregisterEventHotKey(hotKey)
            hotKeyRef = nil
            NSLog("🗑️ Unregistered Cmd+U hotkey")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        unregisterGlobalHotKey()
    }

    @objc func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    @objc func togglePopover() {
        if popover.isShown {
            closePopover()
        } else {
            openPopover()
        }
    }

    @objc func handleClick() {
        guard let event = NSApp.currentEvent else { return }

        if event.type == .rightMouseUp {
            // Right click - show menu
            let menu = NSMenu()
            let toggleItem = NSMenuItem(title: "Toggle Usage (⌘U)", action: #selector(togglePopover), keyEquivalent: "u")
            toggleItem.keyEquivalentModifierMask = .command
            menu.addItem(toggleItem)
            menu.addItem(NSMenuItem.separator())
            menu.addItem(NSMenuItem(title: "Quit ClaudeUsageBar", action: #selector(quitApp), keyEquivalent: "q"))
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else {
            // Left click - toggle popover
            togglePopover()
        }
    }

    func openPopover() {
        if let button = statusItem.button {
            // Force UI refresh by updating percentages before showing
            usageManager.updatePercentages()

            // Recreate the content view controller to ensure fresh state
            let usageView = UsageView(usageManager: usageManager, onHeightChange: { [weak self] newHeight in
                guard let self = self else { return }
                // Animate the height change smoothly
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.2
                    self.popover.contentSize = NSSize(width: 360, height: newHeight)
                })
            })
            let hostingController = NSHostingController(rootView: usageView)
            let initialHeight: CGFloat = 280 // Start with collapsed height
            hostingController.view.setFrameSize(NSSize(width: 360, height: initialHeight))
            popover.contentViewController = hostingController

            // Ensure popover size starts at collapsed height
            popover.contentSize = NSSize(width: 360, height: initialHeight)

            // Show popover below menu bar button with arrow pointing up to the icon
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)

            // Force the popover window to the front and make it key
            DispatchQueue.main.async {
                self.popover.contentViewController?.view.window?.makeKeyAndOrderFront(nil)
            }

            // Add event monitor to detect clicks outside the popover
            eventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                if self?.popover.isShown == true {
                    self?.closePopover()
                }
            }
        }
    }

    func closePopover() {
        popover.performClose(nil)

        // Remove event monitor
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    func updateStatusIcon(percentage: Int, displayType: DisplayType = .claude, codexPercentage: Int = 0) {
        guard let button = statusItem.button else { return }

        // Determine color based on percentage
        let color: NSColor
        if percentage < 70 {
            color = NSColor(red: 0.13, green: 0.77, blue: 0.37, alpha: 1.0) // Green
        } else if percentage < 90 {
            color = NSColor(red: 1.0, green: 0.8, blue: 0.0, alpha: 1.0) // Yellow
        } else {
            color = NSColor(red: 1.0, green: 0.23, blue: 0.19, alpha: 1.0) // Red
        }

        // Handle "Both" display mode - format: [claude icon] [claude %] [chatgpt icon] [chatgpt %]
        if displayType == .both {
            let claudeColor = getColorForPercentage(percentage)
            let codexColor = getColorForPercentage(codexPercentage)

            // Create the full status bar content as a single image
            let claudeText = "\(percentage)%"
            let codexText = "\(codexPercentage)%"

            // Use system font for the text with white color for menu bar visibility
            let font = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
            let textAttributes: [NSAttributedString.Key: Any] = [
                .font: font,
                .foregroundColor: NSColor.white
            ]

            let claudeTextSize = claudeText.size(withAttributes: textAttributes)
            let codexTextSize = codexText.size(withAttributes: textAttributes)

            let iconSize: CGFloat = 16
            let spacing: CGFloat = 4
            let totalWidth = iconSize + spacing + claudeTextSize.width + spacing + iconSize + spacing + codexTextSize.width
            let totalHeight: CGFloat = 18

            let combinedImage = NSImage(size: NSSize(width: totalWidth, height: totalHeight))
            combinedImage.lockFocus()

            var xOffset: CGFloat = 0

            // Draw Claude icon
            let claudeIcon = createSparkIcon(color: claudeColor)
            claudeIcon.draw(at: NSPoint(x: xOffset, y: 1), from: NSRect.zero, operation: .sourceOver, fraction: 1.0)
            xOffset += iconSize + spacing

            // Draw Claude percentage
            claudeText.draw(at: NSPoint(x: xOffset, y: 2), withAttributes: textAttributes)
            xOffset += claudeTextSize.width + spacing

            // Draw ChatGPT icon
            let codexIcon = createChatGPTIcon(color: codexColor)
            codexIcon.draw(at: NSPoint(x: xOffset, y: 1), from: NSRect.zero, operation: .sourceOver, fraction: 1.0)
            xOffset += iconSize + spacing

            // Draw Codex percentage
            codexText.draw(at: NSPoint(x: xOffset, y: 2), withAttributes: textAttributes)

            combinedImage.unlockFocus()

            button.image = combinedImage
            button.title = ""
            return
        }

        // Create appropriate icon based on display type
        let icon: NSImage
        if displayType == .codex {
            icon = createChatGPTIcon(color: color)
        } else {
            icon = createSparkIcon(color: color)
        }

        // Set image and title
        button.image = icon
        button.title = " \(percentage)%"
    }

    func getColorForPercentage(_ percentage: Int) -> NSColor {
        if percentage < 70 {
            return NSColor(red: 0.13, green: 0.77, blue: 0.37, alpha: 1.0) // Green
        } else if percentage < 90 {
            return NSColor(red: 1.0, green: 0.8, blue: 0.0, alpha: 1.0) // Yellow
        } else {
            return NSColor(red: 1.0, green: 0.23, blue: 0.19, alpha: 1.0) // Red
        }
    }

    func createSparkIcon(color: NSColor) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size)

        image.lockFocus()

        // SVG path: M8 1L9 6L13 3L10 7L15 8L10 9L13 13L9 10L8 15L7 10L3 13L6 9L1 8L6 7L3 3L7 6L8 1Z
        let path = NSBezierPath()
        path.move(to: NSPoint(x: 8, y: 1))
        path.line(to: NSPoint(x: 9, y: 6))
        path.line(to: NSPoint(x: 13, y: 3))
        path.line(to: NSPoint(x: 10, y: 7))
        path.line(to: NSPoint(x: 15, y: 8))
        path.line(to: NSPoint(x: 10, y: 9))
        path.line(to: NSPoint(x: 13, y: 13))
        path.line(to: NSPoint(x: 9, y: 10))
        path.line(to: NSPoint(x: 8, y: 15))
        path.line(to: NSPoint(x: 7, y: 10))
        path.line(to: NSPoint(x: 3, y: 13))
        path.line(to: NSPoint(x: 6, y: 9))
        path.line(to: NSPoint(x: 1, y: 8))
        path.line(to: NSPoint(x: 6, y: 7))
        path.line(to: NSPoint(x: 3, y: 3))
        path.line(to: NSPoint(x: 7, y: 6))
        path.close()

        color.setFill()
        path.fill()

        image.unlockFocus()
        image.isTemplate = false

        return image
    }

    func createChatGPTIcon(color: NSColor) -> NSImage {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size)

        image.lockFocus()

        // Create ChatGPT icon - circular starburst pattern (similar style to Claude but different)
        // SVG-like path for a circular burst with 8 points
        let path = NSBezierPath()
        let center = NSPoint(x: 8, y: 8)
        let outerRadius: CGFloat = 7
        let innerRadius: CGFloat = 3
        let points = 8

        for i in 0..<points {
            let angle1 = CGFloat(i) * 2.0 * CGFloat.pi / CGFloat(points) - CGFloat.pi / 2.0
            let angle2 = (CGFloat(i) + 0.5) * 2.0 * CGFloat.pi / CGFloat(points) - CGFloat.pi / 2.0

            // Outer point
            let x1 = center.x + outerRadius * cos(angle1)
            let y1 = center.y + outerRadius * sin(angle1)

            // Inner point
            let x2 = center.x + innerRadius * cos(angle2)
            let y2 = center.y + innerRadius * sin(angle2)

            if i == 0 {
                path.move(to: NSPoint(x: x1, y: y1))
            } else {
                path.line(to: NSPoint(x: x1, y: y1))
            }
            path.line(to: NSPoint(x: x2, y: y2))
        }
        path.close()

        color.setFill()
        path.fill()

        image.unlockFocus()
        image.isTemplate = false

        return image
    }
}

// NSColor extension for hex conversion
extension NSColor {
    var hexString: String {
        guard let rgbColor = self.usingColorSpace(.deviceRGB) else {
            return "#000000"
        }
        let r = Int(rgbColor.redComponent * 255)
        let g = Int(rgbColor.greenComponent * 255)
        let b = Int(rgbColor.blueComponent * 255)
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

// Service type enum for viewing data in the popup
enum ServiceType: String, CaseIterable {
    case claude = "Claude"
    case codex = "Codex"
}

// Display type enum for menu bar display
enum DisplayType: String, CaseIterable {
    case claude = "Claude"
    case codex = "Codex"
    case both = "Both"
}

// Main entry point
@main
struct Main {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

class UsageManager: ObservableObject {
    // Claude usage data
    @Published var sessionUsage: Int = 0
    @Published var sessionLimit: Int = 100
    @Published var weeklyUsage: Int = 0
    @Published var weeklyLimit: Int = 100
    @Published var weeklySonnetUsage: Int = 0
    @Published var weeklySonnetLimit: Int = 100
    @Published var sessionResetsAt: Date?
    @Published var weeklyResetsAt: Date?
    @Published var weeklySonnetResetsAt: Date?

    // Codex usage data
    @Published var codexFiveHourUsage: Int = 0
    @Published var codexWeeklyUsage: Int = 0
    @Published var codexFiveHourResetsAt: Date?
    @Published var codexWeeklyResetsAt: Date?

    // Service selection (for popup view)
    @Published var selectedService: ServiceType = .claude
    // Display type (for menu bar)
    @Published var displayedService: DisplayType = .claude

    // General
    @Published var lastUpdated: Date = Date()
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var notificationsEnabled: Bool = true
    @Published var openAtLogin: Bool = false
    @Published var hasWeeklySonnet: Bool = false
    @Published var hasFetchedData: Bool = false
    @Published var hasFetchedCodexData: Bool = false
    @Published var isAccessibilityEnabled: Bool = false
    @Published var shortcutEnabled: Bool = true

    private var statusItem: NSStatusItem?
    private var sessionCookie: String = ""
    private var codexAuthToken: String = ""
    private var codexCookie: String = ""
    private weak var delegate: AppDelegate?
    private var lastNotifiedThreshold: Int = 0

    init(statusItem: NSStatusItem?, delegate: AppDelegate? = nil) {
        self.statusItem = statusItem
        self.delegate = delegate
        loadSessionCookie()
        loadCodexCredentials()
        loadSettings()
        checkAccessibilityStatus()
    }

    func checkAccessibilityStatus() {
        isAccessibilityEnabled = AXIsProcessTrusted()
    }

    func loadSessionCookie() {
        if let savedCookie = UserDefaults.standard.string(forKey: "claude_session_cookie") {
            sessionCookie = savedCookie
        }
    }

    func loadCodexCredentials() {
        if let savedToken = UserDefaults.standard.string(forKey: "codex_auth_token") {
            codexAuthToken = savedToken
        }
        if let savedCookie = UserDefaults.standard.string(forKey: "codex_cookie") {
            codexCookie = savedCookie
        }
    }

    func loadSettings() {
        notificationsEnabled = UserDefaults.standard.bool(forKey: "notifications_enabled")
        // Default to true if not set
        if !UserDefaults.standard.bool(forKey: "has_set_notifications") {
            notificationsEnabled = true
            UserDefaults.standard.set(true, forKey: "has_set_notifications")
        }
        openAtLogin = UserDefaults.standard.bool(forKey: "open_at_login")
        lastNotifiedThreshold = UserDefaults.standard.integer(forKey: "last_notified_threshold")
        // Default shortcut to enabled if not previously set
        if UserDefaults.standard.object(forKey: "shortcut_enabled") == nil {
            shortcutEnabled = true
        } else {
            shortcutEnabled = UserDefaults.standard.bool(forKey: "shortcut_enabled")
        }
        // Load displayed service preference
        if let savedDisplay = UserDefaults.standard.string(forKey: "displayed_service"),
           let display = DisplayType(rawValue: savedDisplay) {
            displayedService = display
        }
    }

    func saveSettings() {
        UserDefaults.standard.set(notificationsEnabled, forKey: "notifications_enabled")
        UserDefaults.standard.set(openAtLogin, forKey: "open_at_login")
        UserDefaults.standard.set(shortcutEnabled, forKey: "shortcut_enabled")
        UserDefaults.standard.set(displayedService.rawValue, forKey: "displayed_service")
        UserDefaults.standard.synchronize()
    }

    func saveSessionCookie(_ cookie: String) {
        NSLog("ClaudeUsage: Saving cookie, length: \(cookie.count)")
        sessionCookie = cookie
        UserDefaults.standard.set(cookie, forKey: "claude_session_cookie")
        UserDefaults.standard.synchronize()
        NSLog("ClaudeUsage: Cookie saved successfully")
    }

    func saveCodexCredentials(token: String, cookie: String) {
        NSLog("CodexUsage: Saving credentials, token length: \(token.count), cookie length: \(cookie.count)")
        codexAuthToken = token
        codexCookie = cookie
        UserDefaults.standard.set(token, forKey: "codex_auth_token")
        UserDefaults.standard.set(cookie, forKey: "codex_cookie")
        UserDefaults.standard.synchronize()
        NSLog("CodexUsage: Credentials saved successfully")
    }

    func clearSessionCookie() {
        NSLog("ClaudeUsage: Clearing cookie")
        sessionCookie = ""
        UserDefaults.standard.removeObject(forKey: "claude_session_cookie")
        UserDefaults.standard.synchronize()

        // Reset all data
        sessionUsage = 0
        weeklyUsage = 0
        weeklySonnetUsage = 0
        sessionResetsAt = nil
        weeklyResetsAt = nil
        weeklySonnetResetsAt = nil
        hasFetchedData = false
        hasWeeklySonnet = false
        errorMessage = nil
        lastNotifiedThreshold = 0
        UserDefaults.standard.set(0, forKey: "last_notified_threshold")

        // Update status bar to show 0%
        delegate?.updateStatusIcon(percentage: 0, displayType: .claude)

        NSLog("ClaudeUsage: Cookie cleared, data reset")
    }

    func clearCodexCredentials() {
        NSLog("CodexUsage: Clearing credentials")
        codexAuthToken = ""
        codexCookie = ""
        UserDefaults.standard.removeObject(forKey: "codex_auth_token")
        UserDefaults.standard.removeObject(forKey: "codex_cookie")
        UserDefaults.standard.synchronize()

        // Reset Codex data
        codexFiveHourUsage = 0
        codexWeeklyUsage = 0
        codexFiveHourResetsAt = nil
        codexWeeklyResetsAt = nil
        hasFetchedCodexData = false
        errorMessage = nil

        // Update status bar to show 0%
        if displayedService == .codex {
            delegate?.updateStatusIcon(percentage: 0, displayType: .codex)
        } else if displayedService == .both {
            updateStatusBar()
        }

        NSLog("CodexUsage: Credentials cleared, data reset")
    }

    func fetchOrganizationId(completion: @escaping (String?) -> Void) {
        // Get org ID from the lastActiveOrg cookie value
        let cookieParts = sessionCookie.components(separatedBy: ";")
        for part in cookieParts {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("lastActiveOrg=") {
                let orgId = trimmed.replacingOccurrences(of: "lastActiveOrg=", with: "")
                NSLog("📋 Found org ID in cookie: \(orgId)")
                completion(orgId)
                return
            }
        }

        // If not in cookie, fetch from bootstrap
        guard let url = URL(string: "https://claude.ai/api/bootstrap") else {
            completion(nil)
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("sessionKey=\(sessionCookie)", forHTTPHeaderField: "Cookie")

        NSLog("📡 Fetching bootstrap to get org ID...")

        URLSession.shared.dataTask(with: request) { data, response, error in
            guard let data = data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let account = json["account"] as? [String: Any],
                  let lastActiveOrgId = account["lastActiveOrgId"] as? String else {
                NSLog("❌ Could not parse org ID from bootstrap")
                completion(nil)
                return
            }
            NSLog("✅ Got org ID from bootstrap: \(lastActiveOrgId)")
            completion(lastActiveOrgId)
        }.resume()
    }

    func fetchUsage() {
        // Fetch Claude data if cookie is set
        if !sessionCookie.isEmpty {
            isLoading = true
            errorMessage = nil

            // Extract org ID from cookie
            fetchOrganizationId { [weak self] orgId in
                guard let self = self, let orgId = orgId else {
                    DispatchQueue.main.async {
                        self?.errorMessage = "Could not get org ID from cookie"
                        self?.isLoading = false
                    }
                    return
                }

                self.fetchUsageWithOrgId(orgId)
            }
        }

        // Fetch Codex data if credentials are set
        if !codexAuthToken.isEmpty && !codexCookie.isEmpty {
            fetchCodexUsage()
        }
    }

    func fetchUsageWithOrgId(_ orgId: String) {
        let urlString = "https://claude.ai/api/organizations/\(orgId)/usage"

        guard let url = URL(string: urlString) else {
            DispatchQueue.main.async {
                self.errorMessage = "Invalid URL"
                self.isLoading = false
            }
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        // Use the full cookie string (user provides all cookies, not just sessionKey)
        request.setValue(sessionCookie, forHTTPHeaderField: "Cookie")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Origin")
        request.setValue("https://claude.ai", forHTTPHeaderField: "Referer")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        request.setValue("claude.ai", forHTTPHeaderField: "authority")

        NSLog("🔍 Fetching from: \(urlString)")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                self?.isLoading = false

                if let error = error {
                    NSLog("❌ Error: \(error.localizedDescription)")
                    self?.errorMessage = "Network error"
                    self?.updateStatusBar()
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    self?.errorMessage = "Invalid response"
                    self?.updateStatusBar()
                    return
                }

                NSLog("📡 Status: \(httpResponse.statusCode)")

                if let data = data, let responseString = String(data: data, encoding: .utf8) {
                    NSLog("📦 Response: \(responseString)")
                }

                if httpResponse.statusCode == 200, let data = data {
                    self?.parseUsageData(data)
                } else {
                    self?.errorMessage = "HTTP \(httpResponse.statusCode)"
                }

                self?.updateStatusBar()
            }
        }.resume()
    }

    func parseUsageData(_ data: Data) {
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                errorMessage = "Invalid JSON"
                return
            }

            NSLog("📊 Parsing usage data...")

            let iso8601Formatter = ISO8601DateFormatter()
            iso8601Formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

            // Parse the actual claude.ai response format
            if let fiveHour = json["five_hour"] as? [String: Any] {
                if let sessionUtil = fiveHour["utilization"] as? Double {
                    sessionUsage = Int(sessionUtil)
                    sessionLimit = 100
                }
                if let resetsAtString = fiveHour["resets_at"] as? String {
                    NSLog("🕐 Session resets_at string: \(resetsAtString)")
                    if let resetsAt = iso8601Formatter.date(from: resetsAtString) {
                        sessionResetsAt = resetsAt
                        NSLog("✅ Parsed session reset time: \(resetsAt)")
                    } else {
                        NSLog("❌ Failed to parse session reset time")
                    }
                }
            }

            if let sevenDay = json["seven_day"] as? [String: Any] {
                if let weeklyUtil = sevenDay["utilization"] as? Double {
                    weeklyUsage = Int(weeklyUtil)
                    weeklyLimit = 100
                }
                if let resetsAtString = sevenDay["resets_at"] as? String {
                    NSLog("🕐 Weekly resets_at string: \(resetsAtString)")
                    if let resetsAt = iso8601Formatter.date(from: resetsAtString) {
                        weeklyResetsAt = resetsAt
                        NSLog("✅ Parsed weekly reset time: \(resetsAt)")
                    } else {
                        NSLog("❌ Failed to parse weekly reset time")
                    }
                }
            }

            // Check for seven_day_sonnet (Pro plan feature)
            if let sevenDaySonnet = json["seven_day_sonnet"] as? [String: Any] {
                hasWeeklySonnet = true
                if let sonnetUtil = sevenDaySonnet["utilization"] as? Double {
                    weeklySonnetUsage = Int(sonnetUtil)
                    weeklySonnetLimit = 100
                }
                if let resetsAtString = sevenDaySonnet["resets_at"] as? String {
                    NSLog("🕐 Weekly Sonnet resets_at string: \(resetsAtString)")
                    if let resetsAt = iso8601Formatter.date(from: resetsAtString) {
                        weeklySonnetResetsAt = resetsAt
                        NSLog("✅ Parsed weekly Sonnet reset time: \(resetsAt)")
                    } else {
                        NSLog("❌ Failed to parse weekly Sonnet reset time")
                    }
                }
            } else {
                hasWeeklySonnet = false
            }

            // Log what we found
            NSLog("✅ Parsed: Session \(sessionUsage)%, Weekly \(weeklyUsage)%\(hasWeeklySonnet ? ", Weekly Sonnet \(weeklySonnetUsage)%" : "")")

            lastUpdated = Date()
            errorMessage = nil
            hasFetchedData = true

            // Update percentage values for progress bars
            updatePercentages()
        } catch {
            NSLog("❌ Parse error: \(error.localizedDescription)")
            errorMessage = "Parse error"
        }
    }

    func fetchCodexUsage() {
        guard !codexAuthToken.isEmpty, !codexCookie.isEmpty else {
            DispatchQueue.main.async {
                self.errorMessage = "Both Codex credentials required"
            }
            return
        }

        let urlString = "https://chatgpt.com/backend-api/wham/usage"

        guard let url = URL(string: urlString) else {
            DispatchQueue.main.async {
                self.errorMessage = "Invalid Codex URL"
            }
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"

        // Set required headers
        request.setValue("*/*", forHTTPHeaderField: "accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "accept-language")
        request.setValue("Bearer \(codexAuthToken)", forHTTPHeaderField: "authorization")
        request.setValue(codexCookie, forHTTPHeaderField: "Cookie")
        request.setValue("chatgpt.com", forHTTPHeaderField: "authority")
        request.setValue("https://chatgpt.com", forHTTPHeaderField: "origin")
        request.setValue("https://chatgpt.com/codex/settings/usage", forHTTPHeaderField: "referer")
        request.setValue("empty", forHTTPHeaderField: "sec-fetch-dest")
        request.setValue("cors", forHTTPHeaderField: "sec-fetch-mode")
        request.setValue("same-origin", forHTTPHeaderField: "sec-fetch-site")
        request.setValue("u=1, i", forHTTPHeaderField: "priority")
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/144.0.0.0 Safari/537.36", forHTTPHeaderField: "user-agent")

        NSLog("🔍 Fetching Codex usage from: \(urlString)")

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    NSLog("❌ Codex Error: \(error.localizedDescription)")
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    return
                }

                NSLog("📡 Codex Status: \(httpResponse.statusCode)")

                if let data = data, let responseString = String(data: data, encoding: .utf8) {
                    NSLog("📦 Codex Response: \(responseString)")
                }

                if httpResponse.statusCode == 200, let data = data {
                    self?.parseCodexUsageData(data)
                } else {
                    NSLog("❌ Codex HTTP \(httpResponse.statusCode)")
                }

                self?.updateStatusBar()
            }
        }.resume()
    }

    func parseCodexUsageData(_ data: Data) {
        do {
            guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                NSLog("❌ Invalid Codex JSON")
                return
            }

            NSLog("📊 Parsing Codex usage data...")

            // Parse rate_limit for 5-hour usage
            if let rateLimit = json["rate_limit"] as? [String: Any],
               let primaryWindow = rateLimit["primary_window"] as? [String: Any],
               let usedPercent = primaryWindow["used_percent"] as? Int,
               let resetAt = primaryWindow["reset_at"] as? Int {

                codexFiveHourUsage = usedPercent
                codexFiveHourResetsAt = Date(timeIntervalSince1970: TimeInterval(resetAt))

                NSLog("✅ Codex 5-hour: \(usedPercent)%, resets at: \(codexFiveHourResetsAt!)")
            }

            // Parse rate_limit for weekly usage
            if let rateLimit = json["rate_limit"] as? [String: Any],
               let secondaryWindow = rateLimit["secondary_window"] as? [String: Any],
               let usedPercent = secondaryWindow["used_percent"] as? Int,
               let resetAt = secondaryWindow["reset_at"] as? Int {

                codexWeeklyUsage = usedPercent
                codexWeeklyResetsAt = Date(timeIntervalSince1970: TimeInterval(resetAt))

                NSLog("✅ Codex weekly: \(usedPercent)%, resets at: \(codexWeeklyResetsAt!)")
            }

            hasFetchedCodexData = true
            lastUpdated = Date()

            NSLog("✅ Parsed Codex: 5-hour \(codexFiveHourUsage)%, Weekly \(codexWeeklyUsage)%")

            // Update percentage values
            updatePercentages()
        } catch {
            NSLog("❌ Codex Parse error: \(error.localizedDescription)")
        }
    }

    func updateStatusBar() {
        // Calculate percentages for both services
        let claudePercentage = Int((Double(sessionUsage) / Double(sessionLimit)) * 100)
        let codexPercentage = codexFiveHourUsage

        // Show the percentage for the displayed service
        switch displayedService {
        case .claude:
            delegate?.updateStatusIcon(percentage: claudePercentage, displayType: .claude)
        case .codex:
            delegate?.updateStatusIcon(percentage: codexPercentage, displayType: .codex)
        case .both:
            delegate?.updateStatusIcon(percentage: claudePercentage, displayType: .both, codexPercentage: codexPercentage)
        }

        // Check for notification thresholds (only for Claude)
        if displayedService == .claude || displayedService == .both {
            checkNotificationThresholds(percentage: claudePercentage)
        }
    }

    func checkNotificationThresholds(percentage: Int) {
        NSLog("🔔 Checking notifications: percentage=\(percentage)%, enabled=\(notificationsEnabled), lastNotified=\(lastNotifiedThreshold)%")

        guard notificationsEnabled else {
            NSLog("⚠️ Notifications disabled")
            return
        }

        let thresholds = [25, 50, 75, 90]

        for threshold in thresholds {
            if percentage >= threshold && lastNotifiedThreshold < threshold {
                NSLog("📬 Sending notification for \(threshold)% threshold")
                sendNotification(percentage: percentage, threshold: threshold)
                lastNotifiedThreshold = threshold
                // Persist the threshold
                UserDefaults.standard.set(lastNotifiedThreshold, forKey: "last_notified_threshold")
                UserDefaults.standard.synchronize()
            }
        }

        // Reset if usage drops below current threshold
        if percentage < lastNotifiedThreshold {
            let newThreshold = thresholds.filter { $0 <= percentage }.last ?? 0
            NSLog("🔄 Resetting notification threshold from \(lastNotifiedThreshold)% to \(newThreshold)%")
            lastNotifiedThreshold = newThreshold
            UserDefaults.standard.set(lastNotifiedThreshold, forKey: "last_notified_threshold")
            UserDefaults.standard.synchronize()
        }
    }

    func sendNotification(percentage: Int, threshold: Int) {
        let notification = NSUserNotification()
        notification.title = "Claude Usage Alert"
        notification.informativeText = "You've reached \(percentage)% of your 5-hour session limit"
        notification.soundName = NSUserNotificationDefaultSoundName

        NSUserNotificationCenter.default.deliver(notification)
        NSLog("📬 Sent notification for \(threshold)% threshold")
    }

    func sendTestNotification() {
        NSLog("🔔 Test notification button clicked")

        let notification = NSUserNotification()
        notification.title = "Claude Usage Alert"
        notification.informativeText = "Test notification - You've reached 75% of your 5-hour session limit"
        notification.soundName = NSUserNotificationDefaultSoundName

        NSUserNotificationCenter.default.deliver(notification)
        NSLog("📬 Test notification sent successfully")
    }

    @Published var sessionPercentage: Double = 0.0
    @Published var weeklyPercentage: Double = 0.0
    @Published var weeklySonnetPercentage: Double = 0.0
    @Published var codexFiveHourPercentage: Double = 0.0
    @Published var codexWeeklyPercentage: Double = 0.0

    func updatePercentages() {
        sessionPercentage = Double(sessionUsage) / Double(sessionLimit)
        weeklyPercentage = Double(weeklyUsage) / Double(weeklyLimit)
        weeklySonnetPercentage = Double(weeklySonnetUsage) / Double(weeklySonnetLimit)
        codexFiveHourPercentage = Double(codexFiveHourUsage) / 100.0
        codexWeeklyPercentage = Double(codexWeeklyUsage) / 100.0
    }
}

// Custom NSTextField that properly handles paste
class CustomTextField: NSTextField {
    var onTextChange: ((String) -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.type == .keyDown {
            if (event.modifierFlags.contains(.command)) {
                switch event.charactersIgnoringModifiers {
                case "v":
                    if let string = NSPasteboard.general.string(forType: .string) {
                        self.stringValue = string
                        onTextChange?(string)
                        NSLog("ClaudeUsage: Pasted text length: \(string.count)")
                        return true
                    }
                case "a":
                    self.currentEditor()?.selectAll(nil)
                    return true
                case "c":
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(self.stringValue, forType: .string)
                    return true
                case "x":
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(self.stringValue, forType: .string)
                    self.stringValue = ""
                    onTextChange?("")
                    return true
                default:
                    break
                }
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification)
        onTextChange?(self.stringValue)
    }
}

// Custom TextView that ensures keyboard commands work
class PasteableNSTextView: NSTextView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Only handle keyboard shortcuts if this text view is the first responder (has focus)
        guard self.window?.firstResponder == self else {
            return super.performKeyEquivalent(with: event)
        }

        if event.modifierFlags.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "v": // Paste
                paste(nil)
                return true
            case "c": // Copy
                copy(nil)
                return true
            case "x": // Cut
                cut(nil)
                return true
            case "a": // Select All
                selectAll(nil)
                return true
            default:
                break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

// Multi-line text field with proper paste support
struct PasteableTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        let textView = PasteableNSTextView()

        textView.isEditable = true
        textView.isSelectable = true
        textView.font = NSFont.systemFont(ofSize: 11)
        textView.textColor = .labelColor
        textView.backgroundColor = .textBackgroundColor
        textView.drawsBackground = true
        textView.isRichText = false
        textView.delegate = context.coordinator
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.usesFindBar = false
        textView.isGrammarCheckingEnabled = false
        textView.allowsUndo = true

        // Enable wrapping
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? PasteableNSTextView else { return }
        if textView.string != text {
            textView.string = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PasteableTextField

        init(_ parent: PasteableTextField) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

// Custom progress bar that renders with correct color immediately (no flickering)
struct ColoredProgressBar: View {
    var value: Double  // 0.0 to 1.0
    var tintColor: Color
    var targetValue: Double? = nil  // Optional target indicator (0.0 to 1.0)

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                // Background
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.2))
                    .frame(height: 6)

                // Target indicator (yellow bar)
                if let target = targetValue, target > 0 {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.yellow.opacity(0.5))
                        .frame(width: max(0, geometry.size.width * CGFloat(min(target, 1.0))), height: 6)
                }

                // Actual usage bar
                RoundedRectangle(cornerRadius: 3)
                    .fill(tintColor)
                    .frame(width: max(0, geometry.size.width * CGFloat(min(value, 1.0))), height: 6)
            }
        }
        .frame(height: 6)
    }
}

struct UsageView: View {
    @ObservedObject var usageManager: UsageManager
    @State private var sessionCookieInput: String = ""
    @State private var showingCookieInput: Bool = false
    @State private var showingSettings: Bool = false
    @State private var codexAuthTokenInput: String = ""
    @State private var codexCookieInput: String = ""
    @State private var showingCodexInput: Bool = false
    var onHeightChange: ((CGFloat) -> Void)?

    var calculatedHeight: CGFloat {
        var height: CGFloat = 280 // Base height for header, usage bars, buttons
        if showingCookieInput { height += 260 }
        if showingCodexInput { height += 300 }
        if showingSettings { height += 250 }
        return min(height, 600) // Cap at 600 to prevent going off screen
    }

    func updatePopoverHeight() {
        onHeightChange?(calculatedHeight)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                    HStack {
                        Text("Usage Monitor")
                            .font(.headline)
                        Spacer()
                        Picker("", selection: $usageManager.selectedService) {
                            ForEach(ServiceType.allCases, id: \.self) { service in
                                Text(service.rawValue).tag(service)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 150)
                    }
                    .padding(.bottom, 4)

                if let error = usageManager.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.orange)
                        .padding(.bottom, 4)
                }

                // Show welcome message if no data has been fetched for selected service
                if usageManager.selectedService == .claude && !usageManager.hasFetchedData {
                    Text("👋 Welcome! Set your Claude session cookie below to get started.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 4)
                } else if usageManager.selectedService == .codex && !usageManager.hasFetchedCodexData {
                    Text("👋 Welcome! Set your Codex credentials below to get started.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding(.vertical, 4)
                }

            // Claude Usage Display
            if usageManager.selectedService == .claude && usageManager.hasFetchedData {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Session (5 hour)")
                        .font(.subheadline)
                    Spacer()
                    if let resetTime = usageManager.sessionResetsAt {
                        Text("Resets \(formatResetTime(resetTime))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                ColoredProgressBar(value: usageManager.sessionPercentage, tintColor: colorForPercentage(usageManager.sessionPercentage))

                Text("\(Int(usageManager.sessionPercentage * 100))% used")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            // Weekly Usage
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Weekly (7 day)")
                        .font(.subheadline)
                    Spacer()
                    if let resetTime = usageManager.weeklyResetsAt {
                        Text("Resets \(formatResetTime(resetTime, includeDate: true))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                let weeklyTarget = calculateWeeklyTarget(resetDate: usageManager.weeklyResetsAt)
                ColoredProgressBar(value: usageManager.weeklyPercentage, tintColor: colorForPercentage(usageManager.weeklyPercentage), targetValue: weeklyTarget)

                HStack {
                    Text("\(Int(usageManager.weeklyPercentage * 100))% used")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Spacer()

                    if weeklyTarget > 0 {
                        let difference = (usageManager.weeklyPercentage - weeklyTarget) * 100
                        if abs(difference) >= 0.1 {
                            let status = difference > 0 ? "Ahead of Target" : "Behind Target"
                            let color: Color = difference > 0 ? .orange : .green
                            Text("\(String(format: "%.1f", abs(difference)))% \(status)")
                                .font(.caption)
                                .foregroundColor(color)
                        }
                    }
                }
            }

            // Weekly Sonnet Usage (only show if available)
            if usageManager.hasWeeklySonnet && usageManager.hasFetchedData && usageManager.selectedService == .claude {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Weekly Sonnet (7 day)")
                            .font(.subheadline)
                        Spacer()
                        if let resetTime = usageManager.weeklySonnetResetsAt {
                            Text("Resets \(formatResetTime(resetTime, includeDate: true))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }

                    let sonnetTarget = calculateWeeklyTarget(resetDate: usageManager.weeklySonnetResetsAt)
                    ColoredProgressBar(value: usageManager.weeklySonnetPercentage, tintColor: colorForPercentage(usageManager.weeklySonnetPercentage), targetValue: sonnetTarget)

                    HStack {
                        Text("\(Int(usageManager.weeklySonnetPercentage * 100))% used")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        Spacer()

                        if sonnetTarget > 0 {
                            let difference = (usageManager.weeklySonnetPercentage - sonnetTarget) * 100
                            if abs(difference) >= 0.1 {
                                let status = difference > 0 ? "Ahead of Target" : "Behind Target"
                                let color: Color = difference > 0 ? .orange : .green
                                Text("\(String(format: "%.1f", abs(difference)))% \(status)")
                                    .font(.caption)
                                    .foregroundColor(color)
                            }
                        }
                    }
                }
            }
            }

            // Codex Usage Display
            if usageManager.selectedService == .codex && usageManager.hasFetchedCodexData {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Session (5 hour)")
                        .font(.subheadline)
                    Spacer()
                    if let resetTime = usageManager.codexFiveHourResetsAt {
                        Text("Resets \(formatResetTime(resetTime))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                ColoredProgressBar(value: usageManager.codexFiveHourPercentage, tintColor: colorForPercentage(usageManager.codexFiveHourPercentage))

                Text("\(Int(usageManager.codexFiveHourPercentage * 100))% used")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Weekly (7 day)")
                        .font(.subheadline)
                    Spacer()
                    if let resetTime = usageManager.codexWeeklyResetsAt {
                        Text("Resets \(formatResetTime(resetTime, includeDate: true))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                let codexWeeklyTarget = calculateWeeklyTarget(resetDate: usageManager.codexWeeklyResetsAt)
                ColoredProgressBar(value: usageManager.codexWeeklyPercentage, tintColor: colorForPercentage(usageManager.codexWeeklyPercentage), targetValue: codexWeeklyTarget)

                HStack {
                    Text("\(Int(usageManager.codexWeeklyPercentage * 100))% used")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    Spacer()

                    if codexWeeklyTarget > 0 {
                        let difference = (usageManager.codexWeeklyPercentage - codexWeeklyTarget) * 100
                        if abs(difference) >= 0.1 {
                            let status = difference > 0 ? "Ahead of Target" : "Behind Target"
                            let color: Color = difference > 0 ? .orange : .green
                            Text("\(String(format: "%.1f", abs(difference)))% \(status)")
                                .font(.caption)
                                .foregroundColor(color)
                        }
                    }
                }
            }
            }

            if (usageManager.selectedService == .claude && usageManager.hasFetchedData) ||
               (usageManager.selectedService == .codex && usageManager.hasFetchedCodexData) {
            Divider()

            HStack {
                Text("Last updated: \(formatTime(usageManager.lastUpdated))")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button("Refresh") {
                    if usageManager.selectedService == .claude {
                        usageManager.fetchUsage()
                    } else {
                        usageManager.fetchCodexUsage()
                    }
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }
            }

            // Toggle for Claude or Codex credentials
            if usageManager.selectedService == .claude {
                Button(showingCookieInput ? "Hide Cookie" : "Set Session Cookie") {
                    showingCookieInput.toggle()
                }
                .buttonStyle(.borderless)
                .font(.caption)
            } else {
                Button(showingCodexInput ? "Hide Credentials" : "Set Codex Credentials") {
                    showingCodexInput.toggle()
                }
                .buttonStyle(.borderless)
                .font(.caption)
            }

            if showingCookieInput {
                VStack(alignment: .leading, spacing: 8) {
                    Text("How to get your session cookie:")
                        .font(.caption)
                        .fontWeight(.semibold)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("1. Go to Settings > Usage on claude.ai")
                        Text("2. Press F12 (or Cmd+Option+I)")
                        Text("3. Go to Network tab")
                        Text("4. Refresh page, click 'usage' request")
                        Text("5. Find 'Cookie' in Request Headers")
                        Text("6. Copy full cookie value\n   (starts with anthropic-device-id=...)")
                    }
                    .font(.caption2)
                    .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Paste full cookie string:")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        VStack(spacing: 4) {
                            PasteableTextField(text: $sessionCookieInput, placeholder: "Paste cookie here...")
                                .frame(height: 60)
                                .cornerRadius(4)

                            HStack(spacing: 8) {
                                Button("Save Cookie & Fetch") {
                                    // Trim whitespace and newlines
                                    let trimmedCookie = sessionCookieInput.trimmingCharacters(in: .whitespacesAndNewlines)

                                    NSLog("ClaudeUsage: Save clicked, input length: \(trimmedCookie.count)")
                                    if trimmedCookie.isEmpty {
                                        usageManager.errorMessage = "Cookie field is empty!"
                                    } else {
                                        usageManager.saveSessionCookie(trimmedCookie)
                                        usageManager.fetchUsage()
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)

                                if usageManager.hasFetchedData {
                                    Button("Clear Cookie") {
                                        sessionCookieInput = ""
                                        usageManager.clearSessionCookie()
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                }
                .padding(8)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(6)
            }

            if showingCodexInput {
                VStack(alignment: .leading, spacing: 8) {
                    Text("How to get your Codex credentials:")
                        .font(.caption)
                        .fontWeight(.semibold)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("1. Go to chatgpt.com/codex/settings/usage")
                        Text("2. Press F12 (or Cmd+Option+I)")
                        Text("3. Go to Network tab")
                        Text("4. Refresh page, click 'usage' request")
                        Text("5. Find 'authorization' header")
                        Text("   Copy the Bearer token (after 'Bearer ')")
                        Text("6. Find 'cookie' header")
                        Text("   Copy the full cookie value")
                    }
                    .font(.caption2)
                    .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Paste Bearer token:")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        VStack(spacing: 4) {
                            PasteableTextField(text: $codexAuthTokenInput, placeholder: "Paste Bearer token here...")
                                .frame(height: 60)
                                .cornerRadius(4)
                        }
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Paste full cookie string:")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        VStack(spacing: 4) {
                            PasteableTextField(text: $codexCookieInput, placeholder: "Paste cookie here...")
                                .frame(height: 60)
                                .cornerRadius(4)

                            HStack(spacing: 8) {
                                Button("Save & Fetch") {
                                    // Trim whitespace and newlines
                                    let trimmedToken = codexAuthTokenInput.trimmingCharacters(in: .whitespacesAndNewlines)
                                    let trimmedCookie = codexCookieInput.trimmingCharacters(in: .whitespacesAndNewlines)

                                    NSLog("CodexUsage: Save clicked, token length: \(trimmedToken.count), cookie length: \(trimmedCookie.count)")

                                    // Always save whatever is provided
                                    usageManager.saveCodexCredentials(token: trimmedToken, cookie: trimmedCookie)

                                    // Only fetch if both credentials are filled
                                    if !trimmedToken.isEmpty && !trimmedCookie.isEmpty {
                                        NSLog("CodexUsage: Both credentials provided, calling fetchCodexUsage()")
                                        usageManager.fetchCodexUsage()
                                    } else {
                                        NSLog("CodexUsage: Missing credentials - token: \(trimmedToken.isEmpty), cookie: \(trimmedCookie.isEmpty)")
                                    }
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)

                                if usageManager.hasFetchedCodexData {
                                    Button("Clear Credentials") {
                                        codexAuthTokenInput = ""
                                        codexCookieInput = ""
                                        usageManager.clearCodexCredentials()
                                    }
                                    .buttonStyle(.bordered)
                                    .controlSize(.small)
                                }
                            }
                        }
                    }
                }
                .padding(8)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(6)
            }

            // Support Section
            Button(action: {
                NSWorkspace.shared.open(URL(string: "https://donate.stripe.com/3cIcN5b5H7Q8ay8bIDfIs02")!)
            }) {
                HStack(spacing: 4) {
                    Text("☕")
                    Text("Buy Dev a Coffee")
                }
            }
            .buttonStyle(.borderless)
            .font(.caption)
            .foregroundColor(.orange)

            // Settings Section
            Button(showingSettings ? "Hide Settings" : "Settings") {
                showingSettings.toggle()
            }
            .buttonStyle(.borderless)
            .font(.caption)

            if showingSettings {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Menu Bar Display")
                            .font(.caption)
                            .fontWeight(.semibold)
                        Picker("Show usage for:", selection: Binding(
                            get: { usageManager.displayedService },
                            set: { newValue in
                                usageManager.displayedService = newValue
                                usageManager.saveSettings()
                                usageManager.updateStatusBar()
                            }
                        )) {
                            ForEach(DisplayType.allCases, id: \.self) { display in
                                Text(display.rawValue).tag(display)
                            }
                        }
                        .pickerStyle(.radioGroup)
                        Text("Choose which service's usage to display in the menu bar")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }

                    Divider()

                    Toggle(isOn: Binding(
                        get: { usageManager.openAtLogin },
                        set: { newValue in
                            usageManager.openAtLogin = newValue
                            usageManager.saveSettings()
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Open at Login")
                                .font(.caption)
                            Text("Launch app automatically when you log in")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    .toggleStyle(.checkbox)

                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: Binding(
                            get: { usageManager.notificationsEnabled },
                            set: { newValue in
                                usageManager.notificationsEnabled = newValue
                                usageManager.saveSettings()
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Enable Notifications")
                                    .font(.caption)
                                Text("Get alerts at 25%, 50%, 75%,\nand 90% session usage")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .toggleStyle(.checkbox)

                        Button("Test Notification") {
                            usageManager.sendTestNotification()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }

                    Divider()

                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: Binding(
                            get: { usageManager.shortcutEnabled },
                            set: { newValue in
                                usageManager.shortcutEnabled = newValue
                                usageManager.saveSettings()
                                if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
                                    appDelegate.setShortcutEnabled(newValue)
                                }
                            }
                        )) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Keyboard Shortcut (⌘U)")
                                    .font(.caption)
                                Text("Toggle popup from anywhere.\nDisable if it conflicts with other apps.")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .toggleStyle(.switch)

                        if usageManager.shortcutEnabled && !usageManager.isAccessibilityEnabled {
                            Button("Grant Accessibility Permission") {
                                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)

                            Text("Accessibility permission may be needed\nfor the shortcut to work in all apps")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(8)
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(6)
            }
            }
            .padding(EdgeInsets(top: 20, leading: 16, bottom: 16, trailing: 16))
        }
        .frame(width: 360, height: calculatedHeight)
        .onChange(of: showingCookieInput) { _ in
            updatePopoverHeight()
        }
        .onChange(of: showingCodexInput) { _ in
            updatePopoverHeight()
        }
        .onChange(of: showingSettings) { _ in
            updatePopoverHeight()
        }
        .onAppear {
            // Reset state to ensure clean view on each open
            showingCookieInput = false
            showingCodexInput = false
            showingSettings = false

            // Load saved Claude cookie when view appears
            if let savedCookie = UserDefaults.standard.string(forKey: "claude_session_cookie") {
                sessionCookieInput = String(savedCookie.prefix(20)) + "..."
            }
            // Load saved Codex credentials when view appears
            if let savedToken = UserDefaults.standard.string(forKey: "codex_auth_token") {
                codexAuthTokenInput = String(savedToken.prefix(20)) + "..."
            }
            if let savedCookie = UserDefaults.standard.string(forKey: "codex_cookie") {
                codexCookieInput = String(savedCookie.prefix(20)) + "..."
            }
            // Force refresh to ensure progress bars show colors
            usageManager.updatePercentages()
        }
        .onChange(of: usageManager.selectedService) { _ in
            // Reset menu states when switching services
            showingCookieInput = false
            showingCodexInput = false
        }
    }

    func formatNumber(_ number: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: number)) ?? "\(number)"
    }

    func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    func formatResetTime(_ date: Date, includeDate: Bool = false) -> String {
        let formatter = DateFormatter()

        if includeDate {
            // Format: "on 31 Jan 2026 at 7:59 AM"
            formatter.dateFormat = "d MMM yyyy 'at' h:mm a"
            return "on \(formatter.string(from: date))"
        } else {
            formatter.timeStyle = .short
            formatter.dateStyle = .none
            return "at \(formatter.string(from: date))"
        }
    }

    func colorForPercentage(_ percentage: Double) -> Color {
        if percentage < 0.7 {
            return .green
        } else if percentage < 0.9 {
            return .orange
        } else {
            return .red
        }
    }

    // Calculate target usage based on days elapsed in the weekly cycle
    func calculateWeeklyTarget(resetDate: Date?) -> Double {
        guard let resetDate = resetDate else { return 0.0 }

        let now = Date()
        let weekDuration: TimeInterval = 7 * 24 * 60 * 60 // 7 days in seconds

        // Calculate when the period started (7 days before reset)
        let periodStart = resetDate.addingTimeInterval(-weekDuration)

        // Calculate days elapsed since period start
        let elapsed = now.timeIntervalSince(periodStart)
        let daysElapsed = elapsed / (24 * 60 * 60)

        // Target is proportional to days elapsed (capped at 100%)
        let target = min(daysElapsed / 7.0, 1.0)

        return target
    }

}
