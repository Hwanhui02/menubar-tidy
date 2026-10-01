import AppKit
import ApplicationServices
import ScreenCaptureKit
import ServiceManagement

// 메뉴바 정리: ‹ 버튼 왼쪽 구분선(│)보다 왼쪽에 둔 아이콘을 숨긴다.
// 좌클릭 = 기본 동작(아래로 아이콘 격자 / 옆으로 펼침, 설정에서 선택), 우클릭 = 설정.
@MainActor
final class Tidy: NSObject, NSApplicationDelegate {
    // 새 항목은 기본으로 맨 왼쪽(노치 밑)에 붙으므로, 첫 실행 위치를 오른쪽 끝 근처로 지정한다.
    // 값 = 화면 오른쪽 끝에서의 거리(pt). 이후엔 Cmd+드래그한 위치가 autosave로 유지된다.
    lazy var toggle = makeItem("tidy.toggle", at: 250)
    lazy var divider = makeItem("tidy.divider", at: 270)
    let defaults = UserDefaults.standard
    var hidden = false

    // 좌클릭 기본 동작: true = 아래로(아이콘 격자), false = 옆으로(메뉴바에서 펼침)
    var dropDown: Bool {
        get { defaults.object(forKey: "dropDown") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "dropDown") }
    }

    var autoHide: Bool {
        get { defaults.object(forKey: "autoHide") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "autoHide") }
    }

    func makeItem(_ name: String, at pos: Double) -> NSStatusItem {
        let key = "NSStatusItem Preferred Position \(name)"
        if defaults.object(forKey: key) == nil { defaults.set(pos, forKey: key) }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = name
        return item
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        _ = toggle  // toggle 먼저 생성
        rescan()
        // 앱이 켜지면 메뉴바 아이콘은 조금 뒤에 생기므로 3초 뒤, 꺼지면 바로 목록을 새로 만든다.
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self.rescan() }
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { self.rescan() }
        }
        divider.button?.attributedTitle = NSAttributedString(
            string: "│", attributes: [.foregroundColor: NSColor.tertiaryLabelColor])
        toggle.button?.target = self
        toggle.button?.action = #selector(clicked)
        toggle.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        setHidden(false)  // 처음엔 펼쳐서 구분선 위치를 보여주고, 자동 숨김이 접는다
        scheduleRehide()
        if !defaults.bool(forKey: "welcomed") { welcome() }
    }

    func setHidden(_ h: Bool) {
        // 구분선이 토글 오른쪽으로 옮겨졌으면 접지 않는다(토글까지 사라져 못 되돌림).
        if h, let d = divider.button?.window?.frame.minX,
           let t = toggle.button?.window?.frame.minX, d > t { return }
        hidden = h
        divider.length = h ? 10_000 : NSStatusItem.variableLength
        // 숨김 상태(화면 밖)의 위치는 실제 순서와 어긋날 때가 있어서, 펼쳐졌을 때의 순서를 기록해 둔다.
        if !h && AXIsProcessTrusted() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                guard !self.hidden else { return }
                let items = self.menuBarItems()
                self.barOrder = items.map(\.name)
                // 펼쳐서 보이는 동안 아직 모양을 못 찍은 아이콘을 찍어 둔다(macOS 27은 이때만 가능).
                let missing = items.filter { self.iconCache[$0.name] == nil && self.isVisible($0) }
                if !missing.isEmpty && CGPreflightScreenCaptureAccess() {
                    Task { @MainActor in
                        for (j, img) in await self.capture(missing) { self.iconCache[missing[j].name] = img }
                    }
                }
            }
        }
        toggle.button?.image = NSImage(systemSymbolName: h ? "chevron.left" : "chevron.right",
                                       accessibilityDescription: h ? "숨긴 항목 보기" : "항목 숨기기")
    }

    @objc func clicked() {
        let e = NSApp.currentEvent
        if e?.type == .rightMouseUp || e?.modifierFlags.contains(.control) == true {
            closePanel()
            showSettings(at: toggle.button)
        } else if dropDown {
            showPanel()
        } else {
            sideToggle()
        }
    }

    @objc func sideToggle() {
        closePanel()
        setHidden(!hidden)
        scheduleRehide()
    }

    func scheduleRehide() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(rehide), object: nil)
        if autoHide && !hidden { perform(#selector(rehide), with: nil, afterDelay: 15) }
    }

    @objc func rehide() { setHidden(true) }

    // MARK: 아래로 펼치기 — 윈도우 트레이처럼 숨은 아이콘을 격자로 보여준다

    var panel: NSPanel?
    var clickMonitor: Any?
    var shown: [Item] = []
    var iconCache: [String: NSImage] = [:]

    func showPanel() {
        if panel != nil { closePanel(); return }
        guard AXIsProcessTrusted() else { showSettings(at: toggle.button); return }
        let all = menuBarItems()
        shown = all.filter { !isVisible($0) }
        if shown.isEmpty { shown = all }  // 가려진 게 없으면 전부
        // 기본은 메뉴바 순서(왼→오). ⌘+드래그로 바꾼 순서가 있으면 그걸 따르고, 새 아이콘은 뒤에 붙는다.
        let order = gridOrder, bar = barOrder
        shown = shown.enumerated().sorted {
            (order.firstIndex(of: $0.element.name) ?? Int.max, bar.firstIndex(of: $0.element.name) ?? Int.max, $0.offset)
                < (order.firstIndex(of: $1.element.name) ?? Int.max, bar.firstIndex(of: $1.element.name) ?? Int.max, $1.offset)
        }.map(\.element)

        let cols = max(1, min(shown.count + 1, 6)), cell = NSSize(width: 38, height: 32), pad: CGFloat = 8
        let rows = (shown.count + 1 + cols - 1) / cols  // +1 = 설정(⋯) 버튼
        let size = NSSize(width: CGFloat(cols) * cell.width + pad * 2, height: CGFloat(rows) * cell.height + pad * 2)
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: false)
        p.level = .popUpMenu
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.appearance = toggle.button?.effectiveAppearance  // 캡처 아이콘 색(메뉴바 색)과 배경을 맞춘다
        let fx = NSView(frame: NSRect(origin: .zero, size: size))  // 아이콘 버튼을 담는 판
        if #available(macOS 26, *) {  // 제어 센터·메뉴와 같은 Liquid Glass
            let glass = NSGlassEffectView(frame: fx.frame)
            glass.cornerRadius = 14
            glass.contentView = fx
            p.contentView = glass
        } else {
            let ve = NSVisualEffectView(frame: fx.frame)
            ve.material = .menu
            ve.state = .active
            ve.wantsLayer = true
            ve.layer?.cornerRadius = 10
            ve.layer?.masksToBounds = true
            ve.addSubview(fx)
            p.contentView = ve
        }

        var buttons: [NSButton] = []
        for i in 0...shown.count {
            let isMore = i == shown.count
            let img = isMore ? NSImage(systemSymbolName: "ellipsis", accessibilityDescription: "설정")
                             : iconCache[shown[i].name] ?? fallbackIcon(shown[i])
            let b = IconButton(image: img ?? NSImage(), target: self,
                             action: isMore ? #selector(moreClicked(_:)) : #selector(iconClicked(_:)))
            b.isBordered = false
            b.imageScaling = .scaleProportionallyDown
            b.tag = i
            b.toolTip = isMore ? "설정" : shown[i].name + " (⌘+드래그로 순서 바꾸기)"
            b.onDrop = { [weak self] from, pt in self?.reorder(from: from, to: pt, cols: cols, cell: cell, pad: pad, height: size.height) }
            let r = i / cols, c = i % cols
            b.frame = NSRect(x: pad + CGFloat(c) * cell.width,
                             y: size.height - pad - CGFloat(r + 1) * cell.height,
                             width: cell.width, height: cell.height)
            fx.addSubview(b)
            buttons.append(b)
        }

        if let bf = toggle.button?.window?.frame, let scr = NSScreen.screens.first?.frame {
            let x = min(max(bf.midX - size.width / 2, scr.minX + 4), scr.maxX - size.width - 4)
            p.setFrameOrigin(NSPoint(x: x, y: bf.minY - size.height - 4))
        }
        p.orderFrontRegardless()
        panel = p
        rescan()  // 앱이 나중에 아이콘을 추가했을 수도 있으니 다음번을 위해 새로 찾아 둔다
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.closePanel() }
        }

        // 실제 메뉴바 아이콘 모양은 화면 기록 권한이 있을 때만 캡처해서 교체한다.
        // 캡처할 때마다 화면 기록 표시(보라 점)가 떠서, 한 번 찍은 아이콘은 캐시하고 새 것만 찍는다.
        if CGPreflightScreenCaptureAccess() {
            let items = shown
            Task { @MainActor in
                let missing = items.indices.filter { self.iconCache[items[$0].name] == nil }
                guard !missing.isEmpty else { return }
                let imgs = await self.capture(missing.map { items[$0] })
                for (j, img) in imgs {
                    let i = missing[j]
                    self.iconCache[items[i].name] = img
                    if i < buttons.count { buttons[i].image = img }
                }
            }
        }
    }

    func closePanel() {
        panel?.orderOut(nil)
        panel = nil
        if let m = clickMonitor { NSEvent.removeMonitor(m) }
        clickMonitor = nil
    }

    var overflowMaxX: CGFloat?  // macOS 27 시스템 «의 오른쪽 끝. 그보다 왼쪽 항목은 시스템이 가린 것

    // 화면 안에 있고 노치·시스템 «에도 안 걸린 항목만 "보이는" 것으로 본다.
    func isVisible(_ it: Item) -> Bool {
        guard let scr = NSScreen.screens.first else { return true }
        let f = it.frame
        if let o = overflowMaxX, f.minX < o { return false }
        if f.minX < scr.frame.minX || f.maxX > scr.frame.maxX { return false }
        if let l = scr.auxiliaryTopLeftArea, let r = scr.auxiliaryTopRightArea,
           f.maxX > l.maxX, f.minX < r.minX { return false }
        return true
    }

    func fallbackIcon(_ it: Item) -> NSImage? {
        guard let c = it.appIcon?.copy() as? NSImage else { return nil }
        c.size = NSSize(width: 18, height: 18)
        return c
    }

    func capture(_ items: [Item]) async -> [Int: NSImage] {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        else { return [:] }
        let bar = content.windows.filter { $0.windowLayer == 25 }  // kCGStatusWindowLevel
        let scale = NSScreen.screens.first?.backingScaleFactor ?? 2
        var out: [Int: NSImage] = [:]
        let scr = NSScreen.screens.first
        let id = scr?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        let display = content.displays.first { $0.displayID == id }
        for (i, it) in items.enumerated() {
            guard let w = bar.first(where: { abs($0.frame.minX - it.frame.minX) < 2
                                             && abs($0.frame.width - it.frame.width) < 2 }) else {
                // macOS 27은 아이콘마다 창이 따로 없다 → 화면에 보이는 아이콘만 그 자리를 찍는다.
                guard let display, isVisible(it) else { continue }
                let cfg = SCStreamConfiguration()
                cfg.sourceRect = it.frame
                cfg.width = Int(it.frame.width * scale)
                cfg.height = Int(it.frame.height * scale)
                cfg.showsCursor = false
                if let cg = try? await SCScreenshotManager.captureImage(
                    contentFilter: SCContentFilter(display: display, excludingWindows: []), configuration: cfg) {
                    out[i] = NSImage(cgImage: cg, size: it.frame.size)
                }
                continue
            }
            let cfg = SCStreamConfiguration()
            cfg.width = Int(w.frame.width * scale)
            cfg.height = Int(w.frame.height * scale)
            cfg.showsCursor = false
            if let cg = try? await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: w), configuration: cfg) {
                out[i] = NSImage(cgImage: cg, size: w.frame.size)
            }
        }
        return out
    }

    @objc func iconClicked(_ b: NSButton) {
        closePanel()
        open(shown[b.tag])
    }

    // 누르기 명령(AXPress)을 무시하는 도우미 아이콘 → 그 앱이 클릭 때 보내는 알림을 직접 보낸다.
    // Gemini 메뉴바 아이콘(GeminiAppLauncher)은 클릭 시 본 앱에 "작은 입력창 열기" 알림을 보낸다.
    // ponytail: 알려진 앱만 목록으로. 같은 증상 앱이 또 나오면 여기에 추가.
    static let notifyInstead: [String: (app: String, note: String, launchArg: String)] = [
        "com.google.GeminiMacOS.launcher": ("com.google.GeminiMacOS", "com.google.GeminiMacOS.launcher.openMinichat", "--minichat"),
    ]

    func open(_ it: Item) {
        if let bid = it.app.bundleIdentifier, let n = Self.notifyInstead[bid] {
            if NSRunningApplication.runningApplications(withBundleIdentifier: n.app).isEmpty,
               let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: n.app) {
                let cfg = NSWorkspace.OpenConfiguration()  // 본 앱이 꺼져 있으면 알림을 못 받으니 켜면서 연다
                cfg.arguments = [n.launchArg]
                NSWorkspace.shared.openApplication(at: url, configuration: cfg)
            } else {
                DistributedNotificationCenter.default().postNotificationName(
                    .init(n.note), object: nil, userInfo: nil, deliverImmediately: true)
            }
            return
        }
        let press = {
            // AXPress는 대상 앱이 메뉴를 닫을 때까지 막힐 수 있어 백그라운드에서 부른다.
            DispatchQueue.global().async { AXUIElementPerformAction(it.element, kAXPressAction as CFString) }
        }
        // 화면 밖(숨김) 항목은 AXPress가 실패한다 → 아주 잠깐 펼쳐서 누르고 바로 다시 접는다.
        // 메뉴는 열린 자리에 그대로 남는다. 토글 아이콘·순서 기록은 건드리지 않으려고 길이만 바꾼다.
        // ponytail: 0.15/0.4초는 이 Mac 기준. 메뉴가 안 열리는 앱이 생기면 늘리기.
        guard hidden, it.frame.maxX <= 0 else { press(); return }
        divider.length = NSStatusItem.variableLength
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { press() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            if self.hidden { self.divider.length = 10_000 }
        }
    }

    // 마지막으로 펼쳐졌을 때의 실제 메뉴바 순서(왼→오)
    var barOrder: [String] {
        get { defaults.stringArray(forKey: "barOrder") ?? [] }
        set { defaults.set(newValue, forKey: "barOrder") }
    }

    // 격자 안에서만의 순서(실제 메뉴바 순서는 바꾸지 않는다)
    var gridOrder: [String] {
        get { defaults.stringArray(forKey: "gridOrder") ?? [] }
        set { defaults.set(newValue, forKey: "gridOrder") }
    }

    func reorder(from: Int, to pt: NSPoint, cols: Int, cell: NSSize, pad: CGFloat, height: CGFloat) {
        guard from < shown.count else { closePanel(); showPanel(); return }  // ⋯ 버튼은 고정
        let c = min(max(Int((pt.x - pad) / cell.width), 0), cols - 1)
        let r = max(Int((height - pad - pt.y) / cell.height), 0)
        let to = min(r * cols + c, shown.count - 1)
        let it = shown.remove(at: from)
        shown.insert(it, at: to)
        let names = shown.map(\.name)
        gridOrder = names + gridOrder.filter { !names.contains($0) }
        closePanel()
        showPanel()  // 새 순서로 다시 그린다
    }

    @objc func moreClicked(_ b: NSButton) { showSettings(at: b) }

    func showSettings(at view: NSView?) {
        let menu = NSMenu()
        if !AXIsProcessTrusted() { add(menu, "손쉬운 사용 권한 허용…", #selector(requestAX)) }
        if !CGPreflightScreenCaptureAccess() { add(menu, "실제 아이콘 모양 보기 (화면 기록 권한)…", #selector(requestCapture)) }
        if menu.items.count > 0 { menu.addItem(.separator()) }
        if dropDown { add(menu, "옆으로 펼치기/접기", #selector(sideToggle)) }
        else { add(menu, "아래로 펼치기", #selector(showPanelAction)) }
        menu.addItem(.separator())
        let mode = NSMenuItem(title: "좌클릭 기본 동작", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        add(sub, "아래로 (아이콘 격자)", #selector(setDropDown)).state = dropDown ? .on : .off
        add(sub, "옆으로 (메뉴바에서 펼침)", #selector(setSide)).state = dropDown ? .off : .on
        mode.submenu = sub
        menu.addItem(mode)
        add(menu, "15초 뒤 자동 숨김", #selector(flipAutoHide)).state = autoHide ? .on : .off
        add(menu, "로그인 시 실행", #selector(flipLogin)).state =
            SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        add(menu, "종료", #selector(NSApplication.terminate(_:))).target = NSApp
        guard let v = view else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: v.bounds.height + 4), in: v)
    }

    // 처음 실행한 사람에게 한 번만 보여주는 안내
    func welcome() {
        defaults.set(true, forKey: "welcomed")
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "MenuBarTidy 사용법"
        a.informativeText = """
        • 메뉴바에 생긴 │ 왼쪽에 둔 아이콘은 숨겨집니다. ⌘를 누른 채 아이콘을 끌어서 옮기세요.
        • ‹ 클릭: 숨은 아이콘(노치에 가린 것 포함)을 아래로 펼쳐 봅니다.
        • ‹ 우클릭: 설정(펼치는 방식, 자동 숨김, 로그인 시 실행, 종료).
        • 펼친 아이콘을 누르려면 '손쉬운 사용' 권한이 필요합니다.
          실제 아이콘 모양까지 보려면 설정에서 '화면 기록' 권한도 켜 주세요.
        """
        a.addButton(withTitle: "손쉬운 사용 권한 켜기")
        a.addButton(withTitle: "나중에")
        if a.runModal() == .alertFirstButtonReturn { requestAX() }
    }

    @objc func requestCapture() { closePanel(); CGRequestScreenCaptureAccess() }

    @discardableResult
    func add(_ m: NSMenu, _ title: String, _ sel: Selector) -> NSMenuItem {
        let mi = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        mi.target = self
        m.addItem(mi)
        return mi
    }

    struct Item { let element: AXUIElement; let name: String; let appIcon: NSImage?; let frame: CGRect; let isCC: Bool; let app: NSRunningApplication }

    // 메뉴바 아이콘이 있는 앱 PID. 아이콘 없는 앱(대부분)에 묻는 게 앱당 ~20ms라 전체 검색은 1초 넘게 걸린다.
    // 그래서 전체 검색은 백그라운드에서 동시에 돌리고(~0.15초), 평소엔 이 목록만 묻는다(~0.003초).
    var barPIDs: Set<pid_t> = []

    func rescan() {
        let pids = NSWorkspace.shared.runningApplications.map(\.processIdentifier)
        DispatchQueue.global().async {
            var found = [Bool](repeating: false, count: pids.count)
            found.withUnsafeMutableBufferPointer { buf in
                DispatchQueue.concurrentPerform(iterations: pids.count) { i in
                    let a = AXUIElementCreateApplication(pids[i])
                    AXUIElementSetMessagingTimeout(a, 0.1)
                    buf[i] = (attr(a, "AXExtrasMenuBar") as AXUIElement?) != nil
                }
            }
            let set = Set(pids.indices.filter { found[$0] }.map { pids[$0] })
            DispatchQueue.main.async { self.barPIDs = set }
        }
    }

    func menuBarItems() -> [Item] {
        var all: [Item] = []
        overflowMaxX = nil
        let known = barPIDs
        for app in NSWorkspace.shared.runningApplications where known.isEmpty || known.contains(app.processIdentifier) {
            let a = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(a, 0.1)
            guard let bar: AXUIElement = attr(a, "AXExtrasMenuBar"),
                  let kids: [AXUIElement] = attr(bar, kAXChildrenAttribute) else { continue }
            // 시스템 항목(배터리·시계 등)을 그리는 쪽: macOS 26은 제어 센터, 27은 MenuBarAgent
            let isCC = app.bundleIdentifier == "com.apple.controlcenter" || app.bundleIdentifier == "com.apple.MenuBarAgent"
            let appName = app.localizedName ?? "?"
            for k in kids {
                var acts: CFArray?
                AXUIElementCopyActionNames(k, &acts)
                guard (acts as? [String] ?? []).contains(kAXPressAction) else {
                    // 누를 수 없는 항목. macOS 27의 시스템 «(가려진 항목 보기) 버튼이 이것 — 위치만 기억한다.
                    if isCC, let v: AXValue = attr(k, kAXPositionAttribute) {
                        var p = CGPoint.zero; AXValueGetValue(v, .cgPoint, &p)
                        var sz = CGSize.zero
                        if let w: AXValue = attr(k, kAXSizeAttribute) { AXValueGetValue(w, .cgSize, &sz) }
                        if sz.width > 0 { overflowMaxX = p.x + sz.width }
                    }
                    continue
                }
                let desc = (attr(k, kAXDescriptionAttribute) as String?)
                    ?? (attr(k, kAXTitleAttribute) as String?) ?? ""
                if isCC && desc.isEmpty { continue }  // 제어 센터의 이름 없는 빈 자리 항목(x=0)
                // 제어 센터 항목은 "제어 센터 — 배터리" 대신 "배터리"로
                let name = isCC ? (desc.isEmpty ? appName : desc)
                                : (desc.isEmpty || desc == appName ? appName : "\(appName) — \(desc)")
                var p = CGPoint.zero, s = CGSize.zero
                if let v: AXValue = attr(k, kAXPositionAttribute) { AXValueGetValue(v, .cgPoint, &p) }
                if let v: AXValue = attr(k, kAXSizeAttribute) { AXValueGetValue(v, .cgSize, &s) }
                all.append(Item(element: k, name: name, appIcon: app.icon,
                                frame: CGRect(origin: p, size: s), isCC: isCC, app: app))
            }
        }
        // macOS 26은 제어 센터가 다른 앱 아이콘까지 대신 그려서 같은 항목이 두 번 잡힌다.
        // 같은 자리에 원래 앱 항목이 있으면 제어 센터 쪽을 버린다. (27은 숨은 항목들이 « 뒤에
        // 비슷한 x로 겹쳐 있어서, 앱 항목끼리는 위치가 같아도 합치지 않는다.)
        let appX = Set(all.filter { !$0.isCC }.map { Int($0.frame.minX.rounded()) })
        return all
            .filter { it in it.frame.width > 0 && it.frame.width < 500
                      && it.app.processIdentifier != getpid()  // 우리 ‹ │
                      && !(it.isCC && appX.contains(Int(it.frame.minX.rounded()))) }
            .sorted { $0.frame.minX < $1.frame.minX }
    }

    @objc func requestAX() {
        AXIsProcessTrustedWithOptions(
            [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
    }

    @objc func showPanelAction() { showPanel() }
    @objc func setDropDown() { dropDown = true }
    @objc func setSide() { dropDown = false }

    @objc func flipAutoHide() { autoHide.toggle(); scheduleRehide() }

    @objc func flipLogin() {
        let s = SMAppService.mainApp
        do { s.status == .enabled ? try s.unregister() : try s.register() }
        catch { NSAlert(error: error).runModal() }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let tidy = Tidy()
    app.delegate = tidy
    app.setActivationPolicy(.accessory)
    app.run()
}

// ⌘+드래그로 격자 안에서 아이콘을 옮긴다. 그냥 클릭은 보통 버튼처럼 동작.
final class IconButton: NSButton {
    var onDrop: ((Int, NSPoint) -> Void)?

    override func mouseDown(with e: NSEvent) {
        guard e.modifierFlags.contains(.command), let sv = superview else { return super.mouseDown(with: e) }
        let start = frame.origin, p0 = sv.convert(e.locationInWindow, from: nil)
        sv.addSubview(self)  // 맨 위로
        alphaValue = 0.7
        while let ev = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let p = sv.convert(ev.locationInWindow, from: nil)
            setFrameOrigin(NSPoint(x: start.x + p.x - p0.x, y: start.y + p.y - p0.y))
            if ev.type == .leftMouseUp {
                alphaValue = 1
                onDrop?(tag, p)
                return
            }
        }
    }
}

func attr<T>(_ e: AXUIElement, _ name: String) -> T? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success else { return nil }
    return v as? T
}
