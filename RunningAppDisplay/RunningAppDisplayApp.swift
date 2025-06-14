//
//  RunningAppDisplayApp.swift
//  RunningAppDisplay
//
//  Created by Joel Brewster on 25/1/2025.
//

import Cocoa
import SwiftData

@main
class RunningAppDisplayApp: NSObject, NSApplicationDelegate {
    var runningAppsWindow: NSWindow!
    var workspaceNotificationObserver: Any?
    var appearanceObserver: Any?
    var terminationObserver: Any?
    var leftHandle: EdgeHandleView?
    var rightHandle: EdgeHandleView?
    var recentAppOrder: [String] = []  // Track app usage order by bundle ID
    var updateWorkDebounceTimer: Timer?
    var isUpdating: Bool = false
    var currentDockPosition: DockPosition = {
        if let savedPosition = UserDefaults.standard.string(forKey: "dockPosition"),
           let position = DockPosition(rawValue: savedPosition) {
            return position
        }
        return .center  // Default to center
    }()
    var currentIconSize: CGFloat = UserDefaults.standard.float(forKey: "iconSize") > 0 ? CGFloat(UserDefaults.standard.float(forKey: "iconSize")) : 48
    
    // Add property at top of class
    private var needsFollowUpUpdate = false
    
    // Add properties at top of class
    private var workspaceCache: [WorkspaceGroup]?
    private var workspaceCacheTimestamp: Date?
    private let workspaceCacheLifetime: TimeInterval = 0.5 // Cache valid for 0.5 seconds
    
    // Add property at top of class
    private var windowObservers: [NSObjectProtocol] = []
    
    // Add property at top of class
    private var lastWindowUpdateTime: Date = Date()
    private let minimumWindowUpdateInterval: TimeInterval = 0.3
    
    // Add properties at top of class
    private var updateSource: UpdateSource = .none
    private var pendingUpdateSource: UpdateSource = .none
    
    fileprivate enum UpdateSource {
        case none
        case spaceChange
        case windowMove
        case windowOrder
        case appChange
        
        var priority: Int {
            switch self {
            case .none: return 0
            case .windowOrder: return 1
            case .appChange: return 2
            case .windowMove: return 3
            case .spaceChange: return 4
            }
        }
    }
    
    static func main() {
        let app = NSApplication.shared
        let delegate = RunningAppDisplayApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)  // Use .accessory instead of .prohibited
        
        // Hide from Command-Tab switcher
        NSWindow.allowsAutomaticWindowTabbing = false
        app.run()
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        print("Application did finish launching")
        let workspace = NSWorkspace.shared
        
        // Create floating window for running apps with larger height
        runningAppsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 100), // Give it an initial size
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        print("Created window with initial frame: \(runningAppsWindow.frame)")
        
        // Update window setup
        runningAppsWindow.level = .popUpMenu 
        runningAppsWindow.backgroundColor = .clear
        runningAppsWindow.isOpaque = false
        runningAppsWindow.hasShadow = false
        runningAppsWindow.ignoresMouseEvents = false
        runningAppsWindow.acceptsMouseMovedEvents = true
        runningAppsWindow.collectionBehavior = [.canJoinAllSpaces, .managed, .fullScreenAuxiliary]
        runningAppsWindow.isMovableByWindowBackground = false
        runningAppsWindow.alphaValue = 1.0
        
        // Make sure window is visible
        runningAppsWindow.makeKeyAndOrderFront(nil)
        
        print("Window setup complete - level: \(runningAppsWindow.level.rawValue), visible: \(runningAppsWindow.isVisible)")
        
        // Keep existing activation observer
        workspaceNotificationObserver = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: nil) { [weak self] notification in
                if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                   let bundleID = app.bundleIdentifier {
                    self?.updateRecentApps(bundleID)
                }
        }
        
        // Add new observer specifically for hiding
        workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didHideApplicationNotification,
            object: nil,
            queue: nil) { [weak self] notification in
                if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                   let bundleID = app.bundleIdentifier {
                    self?.updateRecentApps(bundleID, moveToEnd: true)
                }
        }
        
        terminationObserver = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: nil) { [weak self] notification in
                self?.debouncedUpdateRunningApps(source: .appChange)
        }
        
        // Add observers for workspace changes
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil,
            queue: nil) { [weak self] _ in
                print("Active space changed")
                self?.debouncedUpdateRunningApps(source: .spaceChange)
        }
        
        // Add observers for window changes using NSNotificationCenter.default
        let center = NotificationCenter.default
        
        // Store window observers to remove them later
        windowObservers = [
            // Window movement between spaces/screens
            center.addObserver(forName: NSWindow.didChangeScreenNotification, object: nil, queue: nil) { [weak self] _ in 
                print("Window moved to different screen")
                self?.debouncedUpdateRunningApps(source: .windowMove)
            },
            
            // Window ordering changes
            center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: nil) { [weak self] _ in 
                print("Window ordering changed")
                self?.debouncedUpdateRunningApps(source: .windowOrder)
            },
            
            // Window minimizing/unminimizing
            center.addObserver(forName: NSWindow.didMiniaturizeNotification, object: nil, queue: nil) { [weak self] _ in 
                print("Window minimized")
                self?.debouncedUpdateRunningApps(source: .windowOrder)
            },
            center.addObserver(forName: NSWindow.didDeminiaturizeNotification, object: nil, queue: nil) { [weak self] _ in 
                print("Window unminimized")
                self?.debouncedUpdateRunningApps(source: .windowOrder)
            }
        ]
        
        // Initialize with current running apps
        let runningApps = workspace.runningApplications.filter { 
            $0.activationPolicy == .regular && 
            $0.bundleIdentifier != Bundle.main.bundleIdentifier
        }
        
        // Add frontmost app first (far left)
        if let frontApp = workspace.frontmostApplication?.bundleIdentifier {
            recentAppOrder.append(frontApp)
        }
        
        // Add other apps in current order
        for app in runningApps {
            if let bundleID = app.bundleIdentifier,
               !recentAppOrder.contains(bundleID) {
                if app.isHidden {
                    // Hidden apps go to start (appears right)
                    recentAppOrder.insert(bundleID, at: 0)
                } else {
                    // Normal apps go after front app
                    recentAppOrder.append(bundleID)
                }
            }
        }
        
        // Initial UI update
        debouncedUpdateRunningApps()
        
        // Add appearance change observer
        appearanceObserver = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            self?.debouncedUpdateRunningApps()  // Refresh UI when appearance changes
        }
    }
    
    func updateRecentApps(_ bundleID: String, moveToEnd: Bool = false) {
        // First remove the app from wherever it is in the list
        recentAppOrder.removeAll { $0 == bundleID }
        
        if moveToEnd {
            // For right-click (hidden apps), move to start (appears on right due to reversed sort)
            recentAppOrder.insert(bundleID, at: 0)
        } else if let frontApp = NSWorkspace.shared.frontmostApplication,
                  frontApp.bundleIdentifier == bundleID {
            // If this is the active app, force it to the far left
            recentAppOrder.append(bundleID)
        } else {
            // For non-active apps, put them after the active app
            recentAppOrder.insert(bundleID, at: 0)
        }
        debouncedUpdateRunningApps(source: .appChange)
    }
    
    fileprivate func debouncedUpdateRunningApps(source: UpdateSource = .none) {
        print("Debounce requested from source: \(source)")
        
        // If an update is in progress, only schedule follow-up if new source has higher priority
        if isUpdating {
            if source.priority > pendingUpdateSource.priority {
                print("Update in progress, scheduling higher priority follow-up")
                pendingUpdateSource = source
                needsFollowUpUpdate = true
            } else {
                print("Update in progress, ignoring lower priority update")
            }
            return
        }
        
        // Cancel any pending timer
        updateWorkDebounceTimer?.invalidate()
        
        // Schedule new update
        updateWorkDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
            print("Timer fired")
            guard let self = self else { return }
            
            self.isUpdating = true
            self.updateSource = source
            
            // Clear cache if it's too old or if this is a high-priority update
            if let timestamp = self.workspaceCacheTimestamp,
               (Date().timeIntervalSince(timestamp) >= self.workspaceCacheLifetime || source.priority >= UpdateSource.windowMove.priority) {
                print("Cache invalidated due to time or priority")
                self.workspaceCache = nil
                self.workspaceCacheTimestamp = nil
            }
            
            self.updateRunningApps()
            
            // Reset flags after a brief delay to ensure window updates are complete
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                self.isUpdating = false
                self.updateSource = .none
                
                // If another update was requested while we were updating, process it
                if self.needsFollowUpUpdate {
                    print("Processing follow-up update with source: \(self.pendingUpdateSource)")
                    self.needsFollowUpUpdate = false
                    let nextSource = self.pendingUpdateSource
                    self.pendingUpdateSource = .none
                    self.debouncedUpdateRunningApps(source: nextSource)
                }
            }
        }
    }
    
    func updateRunningApps() {
        print("Starting updateRunningApps")
        print("Current dock position: \(currentDockPosition)")
        
        // Set critical window properties first
        runningAppsWindow.level = .popUpMenu
        runningAppsWindow.collectionBehavior = [.canJoinAllSpaces, .managed, .fullScreenAuxiliary]
        runningAppsWindow.ignoresMouseEvents = false
        runningAppsWindow.acceptsMouseMovedEvents = true
        runningAppsWindow.hasShadow = false
        runningAppsWindow.isOpaque = false
        runningAppsWindow.backgroundColor = .clear

        // Get workspace groups
        let groups = getWorkspaceGroups()
        print("Got \(groups.count) workspace groups with \(groups.reduce(0) { $0 + $1.windows.count }) total windows")
        
        // Calculate dimensions
        let iconSize = NSSize(width: currentIconSize, height: currentIconSize)
        let spacing: CGFloat = 6
        let groupSpacing: CGFloat = 20  // Space between workspace groups
        let horizontalPadding: CGFloat = 6
        let verticalPadding: CGFloat = 6
        let shadowPadding: CGFloat = 0
        let resizeHandleHeight: CGFloat = 8
        
        // Calculate total number of windows and groups for sizing
        let totalWindows = groups.reduce(0) { $0 + $1.windows.count }
        let totalGroups = groups.count
        
        print("Total windows across all groups: \(totalWindows)")
        
        // Calculate exact sizes
        let contentWidth = CGFloat(totalWindows) * (iconSize.width + spacing) + 
                         CGFloat(max(0, totalGroups - 1)) * (groupSpacing - spacing) +
                         (horizontalPadding * 2) - spacing
        let contentHeight: CGFloat = iconSize.height + (verticalPadding * 2) + resizeHandleHeight
        let totalWidth = contentWidth
        let totalHeight = contentHeight
        
        print("Window dimensions - Width: \(totalWidth), Height: \(totalHeight)")
        
        // Create container view
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: totalWidth, height: totalHeight))
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.red.withAlphaComponent(0.3).cgColor // Debug tint
        
        // Create and add resize handle
        let resizeHandle = ResizeHandleView(frame: NSRect(x: shadowPadding, 
                                                        y: totalHeight - resizeHandleHeight - shadowPadding,
                                                        width: contentWidth,
                                                        height: resizeHandleHeight))
        resizeHandle.delegate = self
        containerView.addSubview(resizeHandle)
        
        // Create background view
        let backgroundView = NSView(frame: NSRect(x: shadowPadding, 
                                                y: shadowPadding,
                                                width: contentWidth, 
                                                height: contentHeight - resizeHandleHeight))
        backgroundView.wantsLayer = true
        backgroundView.layer?.backgroundColor = NSColor.blue.withAlphaComponent(0.3).cgColor // Debug tint
        
        // Create visual effect view for blur
        let blurView = NSVisualEffectView(frame: backgroundView.bounds)
        blurView.blendingMode = .behindWindow
        blurView.state = .active
        blurView.material = .hudWindow
        blurView.alphaValue = 0.8
        blurView.wantsLayer = true
        blurView.layer?.backgroundColor = NSColor.purple.withAlphaComponent(0.3).cgColor // Debug tint
        blurView.isEmphasized = true
        blurView.appearance = NSApp.effectiveAppearance
        blurView.layer?.borderWidth = 0
        
        // Create main stack view with padding
        let mainStackView = NSStackView(frame: NSRect(x: horizontalPadding, 
                                                    y: verticalPadding,
                                                    width: contentWidth - (horizontalPadding * 2),
                                                    height: iconSize.height))
        mainStackView.wantsLayer = true
        mainStackView.layer?.backgroundColor = NSColor.green.withAlphaComponent(0.3).cgColor // Debug tint
        mainStackView.orientation = .horizontal
        mainStackView.spacing = groupSpacing
        mainStackView.distribution = .fill
        mainStackView.alignment = .centerY
        
        // Set up view hierarchy
        backgroundView.addSubview(blurView)
        blurView.addSubview(mainStackView)
        containerView.addSubview(backgroundView)
        
        print("View hierarchy setup:")
        print("Container view frame: \(containerView.frame)")
        print("Background view frame: \(backgroundView.frame)")
        print("Blur view frame: \(blurView.frame)")
        print("Main stack view frame: \(mainStackView.frame)")
        
        // Add apps for each group
        for group in groups {
            print("\nProcessing group \(group.workspace) with \(group.windows.count) windows")
            // Create stack view for this group
            let groupStack = NSStackView(frame: NSRect(x: 0, y: 0, 
                                                     width: CGFloat(group.windows.count) * (iconSize.width + spacing) - spacing, 
                                                     height: iconSize.height))
            groupStack.wantsLayer = true
            groupStack.layer?.backgroundColor = NSColor.yellow.withAlphaComponent(0.3).cgColor // Debug tint
            groupStack.orientation = .horizontal
            groupStack.spacing = spacing
            groupStack.distribution = .fillEqually
            groupStack.alignment = .centerY
            
            print("Created group stack with frame: \(groupStack.frame)")
            
            // Add separator before group (except first group)
            if let firstGroup = groups.first, group.workspace != firstGroup.workspace {
                let separator = NSView(frame: NSRect(x: 0, y: 0, width: 2, height: iconSize.height * 0.8))
                separator.wantsLayer = true
                separator.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.3).cgColor
                separator.layer?.cornerRadius = 1
                mainStackView.addArrangedSubview(separator)
                print("Added separator")
            }
            
            // Add apps for this group
            for window in group.windows {
                print("Processing window - PID: \(window.pid), Title: \(window.title)")
                
                // Try to get icon from running app first
                var appIcon: NSImage?
                var isHidden = false
                
                if let app = NSRunningApplication(processIdentifier: pid_t(window.pid)) {
                    print("Found running app: \(app.localizedName ?? "unknown"), Bundle ID: \(app.bundleIdentifier ?? "none")")
                    appIcon = app.icon
                    isHidden = app.isHidden
                }
                
                // Fallback to system icons if no running app found
                if appIcon == nil {
                    print("Using fallback icon for: \(window.title)")
                    let commonAppIcons = [
                        "Firefox Developer Edition": "/Applications/Firefox Developer Edition.app",
                        "Firefox": "/Applications/Firefox.app",
                        "Safari": "/Applications/Safari.app",
                        "Finder": "/System/Library/CoreServices/Finder.app",
                        "Xcode": "/Applications/Xcode.app",
                        "Music": "/System/Applications/Music.app",
                        "Signal": "/Applications/Signal.app",
                        "Cursor": "/Applications/Cursor.app"
                    ]
                    
                    if let appPath = commonAppIcons[window.title] {
                        appIcon = NSWorkspace.shared.icon(forFile: appPath)
                    }
                }
                
                // Final fallback to generic app icon
                if appIcon == nil {
                    appIcon = NSWorkspace.shared.icon(forFileType: "app")
                }
                
                // Ensure we have an icon and size it correctly
                guard let icon = appIcon else { continue }
                icon.size = NSSize(width: currentIconSize, height: currentIconSize)
                print("Got icon with size: \(icon.size)")
                
                let containerView = NSView(frame: NSRect(x: 0, y: 0, width: iconSize.width, height: iconSize.height))
                containerView.wantsLayer = true
                containerView.layer?.backgroundColor = NSColor.red.withAlphaComponent(0.3).cgColor // Debug tint
                
                let imageView = ClickableImageView(frame: containerView.bounds)
                imageView.imageScaling = .scaleProportionallyDown
                imageView.image = icon
                imageView.wantsLayer = true
                imageView.layer?.cornerRadius = 6
                imageView.layer?.masksToBounds = true
                imageView.tag = Int(window.pid)
                imageView.alphaValue = isHidden ? 0.5 : 1.0
                
                containerView.addSubview(imageView)
                containerView.widthAnchor.constraint(equalToConstant: iconSize.width).isActive = true
                
                groupStack.addArrangedSubview(containerView)
                print("Added icon view for \(window.title)")
            }
            
            mainStackView.addArrangedSubview(groupStack)
        }
        
        // Position window
        if let mainScreen = NSScreen.screens.first {
            let xPosition: CGFloat = switch currentDockPosition {
            case .left:
                mainScreen.visibleFrame.minX
            case .center:
                (mainScreen.visibleFrame.width - totalWidth) / 2 + mainScreen.visibleFrame.minX
            case .right:
                mainScreen.visibleFrame.maxX - totalWidth
            }
            
            // Position at bottom of screen with some padding
            let yPosition = mainScreen.visibleFrame.minY + 10 // Add 10px padding from bottom
            
            let newFrame = NSRect(x: xPosition, y: yPosition, width: totalWidth, height: totalHeight)
            print("Positioning window at: \(newFrame)")
            
            runningAppsWindow.setFrame(newFrame, display: true)
            
            // Force window to front and make visible
            runningAppsWindow.orderFront(nil)
            runningAppsWindow.makeKeyAndOrderFront(nil)
            
            // Debug window state
            print("Window level: \(runningAppsWindow.level.rawValue)")
            print("Window is visible: \(runningAppsWindow.isVisible)")
            print("Window alpha: \(runningAppsWindow.alphaValue)")
            print("Window frame: \(runningAppsWindow.frame)")
        }
        
        // Set up view hierarchy
        backgroundView.addSubview(mainStackView)
        containerView.addSubview(backgroundView)
        runningAppsWindow.contentView = containerView
        
        // Add edge handles
        leftHandle = EdgeHandleView(frame: NSRect(x: shadowPadding, 
                                                y: shadowPadding,
                                                width: 20,
                                                height: contentHeight - resizeHandleHeight),
                                   isLeft: true)
        leftHandle?.currentPosition = currentDockPosition
        leftHandle?.delegate = self

        rightHandle = EdgeHandleView(frame: NSRect(x: shadowPadding + contentWidth - 20,
                                                 y: shadowPadding,
                                                 width: 20,
                                                 height: contentHeight - resizeHandleHeight),
                                    isLeft: false)
        rightHandle?.currentPosition = currentDockPosition
        rightHandle?.delegate = self

        if let left = leftHandle, let right = rightHandle {
            containerView.addSubview(left)
            containerView.addSubview(right)
        }
    }
    
    deinit {
        if let observer = appearanceObserver as? NSKeyValueObservation {
            observer.invalidate()
        }
        if let observer = workspaceNotificationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        if let observer = terminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        // Remove window observers
        for observer in windowObservers {
            NotificationCenter.default.removeObserver(observer)
        }
    }
    
    private func runAerospaceCommand(args: [String]) -> String? {
        let paths = [
            "/opt/homebrew/bin/aerospace",
            "/usr/local/bin/aerospace",
            "/usr/bin/aerospace"
        ]
        
        for path in paths {
            print("Trying path: \(path)")
            let task = Process()
            task.executableURL = URL(fileURLWithPath: path)
            task.arguments = args
            
            // Set PATH environment variable
            var env = ProcessInfo.processInfo.environment
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:" + (env["PATH"] ?? "")
            task.environment = env
            
            let pipe = Pipe()
            task.standardOutput = pipe
            
            let errorPipe = Pipe()
            task.standardError = errorPipe
            
            do {
                try task.run()
                task.waitUntilExit()
                
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()
                
                if let errorOutput = String(data: errorData, encoding: .utf8), !errorOutput.isEmpty {
                    print("Error output: \(errorOutput)")
                }
                
                if let output = String(data: data, encoding: .utf8) {
                    print("Success with path: \(path)")
                    print("Output: \(output)")
                    return output
                }
            } catch {
                print("Failed with path \(path): \(error)")
                continue
            }
        }
        print("All paths failed")
        return nil
    }

    struct WindowInfo: Codable {
        let pid: Int
        let title: String
        let appName: String
        let isHidden: Bool
        
        var appIcon: NSImage? {
            if let app = NSRunningApplication(processIdentifier: pid_t(pid)) {
                print("Getting icon for PID \(pid): \(app.localizedName ?? "unknown"), Has icon: \(app.icon != nil)")
                return app.icon
            }
            print("Failed to get icon for PID \(pid)")
            return nil
        }
    }

    struct WorkspaceGroup: Identifiable {
        let workspace: String
        let windows: [WindowInfo]
        
        var id: String { workspace }  // Conform to Identifiable using workspace as the id
    }

    private func getWorkspaceGroups() -> [WorkspaceGroup] {
        // Check if cache is valid
        if let cache = workspaceCache,
           let timestamp = workspaceCacheTimestamp,
           Date().timeIntervalSince(timestamp) < workspaceCacheLifetime {
            print("Using cached workspace data (age: \(Date().timeIntervalSince(timestamp))s)")
            return cache
        }
        
        print("=== Getting Fresh Workspace Groups ===")
        var groups: [WorkspaceGroup] = []
        
        // Get list of workspaces
        let workspaces = getWorkspaces()
        print("Found \(workspaces.count) workspaces: \(workspaces)")
        
        // Get windows for each workspace
        for workspace in workspaces {
            print("\nGetting windows for workspace: \(workspace)")
            let windows = getWindowsForWorkspace(workspace)
            if !windows.isEmpty {
                let windowInfos = windows.map { window -> WindowInfo in
                    let info = WindowInfo(pid: Int(window.pid), title: window.title, appName: window.name, isHidden: false)
                    print("Created WindowInfo - PID: \(info.pid), Name: \(info.appName)")
                    if let app = NSRunningApplication(processIdentifier: pid_t(info.pid)) {
                        print("Found running app: \(app.localizedName ?? "unknown"), Has icon: \(app.icon != nil)")
                    } else {
                        print("No running app found for PID \(info.pid)")
                    }
                    return info
                }
                groups.append(WorkspaceGroup(workspace: workspace, windows: windowInfos))
                print("Found \(windows.count) windows in workspace \(workspace)")
            }
        }
        
        print("\nUpdating cache with \(groups.count) workspace groups")
        workspaceCache = groups
        workspaceCacheTimestamp = Date()
        
        return groups
    }
    
    private func getWorkspaces() -> [String] {
        guard let workspaceOutput = runAerospaceCommand(args: ["list-workspaces", "--all"]) else {
            print("Failed to get workspace list")
            return []
        }
        
        return workspaceOutput.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
    
    private func getWindowsForWorkspace(_ workspace: String) -> [(pid: Int32, title: String, name: String)] {
        guard let windowOutput = runAerospaceCommand(args: ["list-windows", "--workspace", workspace]) else {
            return []
        }
        
        return windowOutput.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .compactMap { line -> (pid: Int32, title: String, name: String)? in
                let parts = line.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                guard parts.count >= 3,
                      let windowId = Int32(parts[0]) else {
                    return nil
                }
                
                // Use the app name to find the actual running app
                let appName = parts[1].trimmingCharacters(in: .whitespaces)
                print("Looking for app with name: \(appName)")
                
                // Find running app by name
                if let app = NSWorkspace.shared.runningApplications.first(where: { 
                    $0.localizedName?.lowercased() == appName.lowercased() ||
                    $0.bundleIdentifier?.lowercased().contains(appName.lowercased()) == true
                }) {
                    print("Found running app: \(app.localizedName ?? "unknown"), PID: \(app.processIdentifier)")
                    return (pid: app.processIdentifier, title: parts[1], name: parts[2])
                }
                
                // Special case for common apps
                let commonApps = [
                    "Firefox Developer Edition": "org.mozilla.firefoxdeveloperedition",
                    "Firefox": "org.mozilla.firefox",
                    "Safari": "com.apple.Safari",
                    "Finder": "com.apple.finder",
                    "Xcode": "com.apple.dt.Xcode",
                    "Music": "com.apple.Music",
                    "Signal": "org.whispersystems.signal-desktop",
                    "Cursor": "com.cursor.Cursor"
                ]
                
                if let bundleId = commonApps[appName],
                   let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleId }) {
                    print("Found app via bundle ID: \(app.localizedName ?? "unknown"), PID: \(app.processIdentifier)")
                    return (pid: app.processIdentifier, title: parts[1], name: parts[2])
                }
                
                print("Could not find running app for: \(appName)")
                return (pid: windowId, title: parts[1], name: parts[2])
            }
    }
    
    private func shouldProcessWindowUpdate() -> Bool {
        let now = Date()
        let timeSinceLastUpdate = now.timeIntervalSince(lastWindowUpdateTime)
        if timeSinceLastUpdate >= minimumWindowUpdateInterval {
            lastWindowUpdateTime = now
            return true
        }
        return false
    }
}

// Add this class at the top level
class ClickableImageView: NSImageView {
    private var popover: NSPopover?
    private var isMouseInside = false
    private var originalIcon: NSImage?
    private var grayscaleIcon: NSImage?
    
    override var acceptsFirstResponder: Bool { return true }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        setupInitialIcon()
    }
    
    private func setupInitialIcon() {
        guard let app = NSRunningApplication(processIdentifier: pid_t(self.tag)) else { return }
        
        // Store original icon
        if let appIcon = app.icon {
            appIcon.size = bounds.size
            originalIcon = appIcon
            
            // Create grayscale version if app is hidden
            if app.isHidden {
                grayscaleIcon = createGrayscaleIcon(from: appIcon)
                self.image = grayscaleIcon
                self.alphaValue = 0.5
            } else {
                self.image = appIcon
                self.alphaValue = 1.0
            }
        }
        
        // Enable smooth transitions
        wantsLayer = true
        layer?.actions = [
            "contents": NSNull(),
            "opacity": CABasicAnimation(keyPath: "opacity")
        ]
    }
    
    private func createGrayscaleIcon(from icon: NSImage) -> NSImage? {
        guard let cgImage = icon.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        
        let ciImage = CIImage(cgImage: cgImage)
        let filter = CIFilter(name: "CIColorMonochrome")!
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(CIColor(red: 0.7, green: 0.7, blue: 0.7), forKey: kCIInputColorKey)
        filter.setValue(1.0, forKey: kCIInputIntensityKey)
        
        guard let output = filter.outputImage else { return nil }
        let context = CIContext(options: nil)
        guard let cgOutput = context.createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cgOutput, size: bounds.size)
    }
    
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .enabledDuringMouseDrag, .mouseMoved],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }
    
    override func mouseMoved(with event: NSEvent) {
        if isMouseInside {
            showTooltipIfNeeded()
        }
    }
    
    private func showTooltipIfNeeded() {
        guard isMouseInside,
              let app = NSRunningApplication(processIdentifier: pid_t(self.tag)),
              window != nil,
              popover == nil  // Only show if not already showing
              else { return }
        
        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.animates = true
        
        let label = NSTextField(labelWithString: app.localizedName ?? "Unknown")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alignment = .center
        label.sizeToFit()
        
        let padding: CGFloat = 16
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: label.frame.width + padding, height: 30))
        contentView.addSubview(label)
        
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
        ])
        
        popover.contentViewController = NSViewController()
        popover.contentViewController?.view = contentView
        
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
        self.popover = popover
    }
    
    override func mouseEntered(with event: NSEvent) {
        isMouseInside = true
        
        // Always show original colored icon on hover with smooth transition
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            self.animator().image = originalIcon
            self.animator().alphaValue = 1.0
        }
        
        showTooltipIfNeeded()
    }
    
    override func mouseExited(with event: NSEvent) {
        isMouseInside = false
        popover?.close()
        popover = nil
        
        // Return to grayscale if app is hidden with smooth transition
        if let app = NSRunningApplication(processIdentifier: pid_t(self.tag)) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                if app.isHidden {
                    self.animator().image = grayscaleIcon
                    self.animator().alphaValue = 0.5
                } else {
                    self.animator().image = originalIcon
                    self.animator().alphaValue = 1.0
                }
            }
        }
    }
    
    override func mouseDown(with event: NSEvent) {
        guard let app = NSRunningApplication(processIdentifier: pid_t(self.tag)),
              let bundleID = app.bundleIdentifier,
              let appDelegate = NSApplication.shared.delegate as? RunningAppDisplayApp else { return }
        
        // Update to use non-deprecated activation method
        _ = app.activate(options: .activateAllWindows)
        
        // Reset opacity and icon since app is now active
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            self.animator().image = originalIcon
            self.animator().alphaValue = 1.0
        }
        
        // Force active app to far left by moving all other apps right
        let currentApps = appDelegate.recentAppOrder.filter { $0 != bundleID }
        appDelegate.recentAppOrder = [bundleID] + currentApps
        
        // Update UI
        appDelegate.debouncedUpdateRunningApps()
    }
    
    override func rightMouseDown(with event: NSEvent) {
        guard let app = NSRunningApplication(processIdentifier: pid_t(self.tag)),
              let bundleID = app.bundleIdentifier,
              let appDelegate = NSApplication.shared.delegate as? RunningAppDisplayApp else { return }
        
        // Hide the app
        _ = app.hide()
        
        // Animate to grayscale
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            self.animator().image = grayscaleIcon
            self.animator().alphaValue = 0.5
        }
        
        // FORCE IT TO THE RIGHT - PERIOD.
        appDelegate.recentAppOrder.removeAll { $0 == bundleID }
        appDelegate.recentAppOrder.insert(bundleID, at: 0)  // This puts it far right because of reversed sort
        
        // Update UI
        appDelegate.debouncedUpdateRunningApps()
    }
}

// Add resize handle delegate protocol
protocol ResizeHandleDelegate: AnyObject {
    func handleResize(newSize: CGFloat)
}

// Add resize handle implementation
extension RunningAppDisplayApp: ResizeHandleDelegate {
    func handleResize(newSize: CGFloat) {
        let screenHeight = NSScreen.main?.frame.height ?? 1000
        let maxIconSize: CGFloat = screenHeight / 3
        let minIconSize: CGFloat = 38
        
        let clampedSize = min(max(newSize, minIconSize), maxIconSize)
        
        if abs(currentIconSize - clampedSize) > 0.5 {
            currentIconSize = clampedSize
            UserDefaults.standard.set(Float(clampedSize), forKey: "iconSize")
            
            // Force window to stay interactive
            runningAppsWindow.ignoresMouseEvents = false
            runningAppsWindow.acceptsMouseMovedEvents = true
            
            // Use debounced update
            debouncedUpdateRunningApps()
            
            // Ensure window stays interactive after update
            DispatchQueue.main.async {
                self.runningAppsWindow.ignoresMouseEvents = false
                self.runningAppsWindow.acceptsMouseMovedEvents = true
            }
        }
    }
}

// Add this class at the top level
class ResizeHandleView: NSView {
    weak var delegate: ResizeHandleDelegate?
    private var isDragging = false
    private var lastY: CGFloat = 0
    private let sizeIncrement: CGFloat = 15
    private var handleIndicator: NSView!
    
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        
        // Create the handle indicator (initially hidden)
        handleIndicator = NSView(frame: NSRect(x: frame.width/2 - 20, y: 2, width: 40, height: 4))
        handleIndicator.wantsLayer = true
        handleIndicator.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.0).cgColor
        handleIndicator.layer?.cornerRadius = 2
        addSubview(handleIndicator)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        ))
    }
    
    override func mouseEntered(with event: NSEvent) {
        NSCursor.resizeUpDown.push()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            handleIndicator.animator().alphaValue = 0.5
        }
    }
    
    override func mouseExited(with event: NSEvent) {
        NSCursor.pop()
        if !isDragging {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                handleIndicator.animator().alphaValue = 0
            }
        }
    }
    
    override func mouseDown(with event: NSEvent) {
        isDragging = true
        lastY = NSEvent.mouseLocation.y
        print("=== DRAG START ===")
        print("Initial Y: \(lastY)")
    }
    
    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        
        let currentY = NSEvent.mouseLocation.y
        let deltaY = (currentY - lastY) * 100
        
        if abs(deltaY) > 0.5 {
            lastY = currentY
            
            if let appDelegate = NSApplication.shared.delegate as? RunningAppDisplayApp {
                let sizeChange: CGFloat = (deltaY > 0 ? 15 : -15) // Back to original 15-pixel increments
                let newSize = appDelegate.currentIconSize + sizeChange
                print("Resizing to: \(newSize) (Delta: \(deltaY))")
                delegate?.handleResize(newSize: newSize)
            }
        }
    }
    
    override func mouseUp(with event: NSEvent) {
        isDragging = false
        if !NSPointInRect(convert(event.locationInWindow, from: nil), bounds) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                handleIndicator.animator().alphaValue = 0
            }
        }
        print("=== DRAG END ===")
        print("Final Y: \(NSEvent.mouseLocation.y)")
    }
}

enum DockPosition: String {
    case left = "left"
    case center = "center"
    case right = "right"
}

protocol EdgeHandleDelegate: AnyObject {
    func handleEdgeDrag(fromLeftEdge: Bool, currentPosition: DockPosition)
}

class EdgeHandleView: NSView {
    weak var delegate: EdgeHandleDelegate?
    private var isDragging = false
    private var startX: CGFloat = 0
    private let isLeftHandle: Bool
    var currentPosition: DockPosition = .right  // Start at right by default
    
    init(frame: NSRect, isLeft: Bool) {
        self.isLeftHandle = isLeft
        super.init(frame: frame)
        wantsLayer = true
        
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func mouseEntered(with event: NSEvent) {
        NSCursor.resizeLeftRight.push()
    }
    
    override func mouseExited(with event: NSEvent) {
        NSCursor.pop()
    }
    
    override func mouseDown(with event: NSEvent) {
        isDragging = true
        startX = NSEvent.mouseLocation.x
    }
    
    override func mouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        let currentX = NSEvent.mouseLocation.x
        let deltaX = currentX - startX
        
        if (isLeftHandle && deltaX < -10) {
            print("Moving dock LEFT from \(currentPosition)")
            delegate?.handleEdgeDrag(fromLeftEdge: true, currentPosition: currentPosition)
            isDragging = false
        } else if (!isLeftHandle && deltaX > 10) {
            print("Moving dock RIGHT from \(currentPosition)")
            delegate?.handleEdgeDrag(fromLeftEdge: false, currentPosition: currentPosition)
            isDragging = false
        }
    }
    
    override func mouseUp(with event: NSEvent) {
        isDragging = false
    }
}

extension RunningAppDisplayApp: EdgeHandleDelegate {
    func handleEdgeDrag(fromLeftEdge: Bool, currentPosition: DockPosition) {
        guard let screen = NSScreen.main else { return }
        
        let newPosition: DockPosition
        
        if fromLeftEdge {
            newPosition = switch currentPosition {
                case .right: .center
                case .center: .left
                case .left: .left
            }
        } else {
            newPosition = switch currentPosition {
                case .left: .center
                case .center: .right
                case .right: .right
            }
        }
        
        // Update position state
        currentDockPosition = newPosition
        leftHandle?.currentPosition = newPosition
        rightHandle?.currentPosition = newPosition
        UserDefaults.standard.set(newPosition.rawValue, forKey: "dockPosition")
        
        // Calculate new window position
        let shadowOffset: CGFloat = 0
        let newX: CGFloat = switch newPosition {
        case .left:
            screen.visibleFrame.minX - shadowOffset
        case .center:
            (screen.visibleFrame.width - runningAppsWindow.frame.width) / 2
        case .right:
            screen.visibleFrame.maxX - runningAppsWindow.frame.width + shadowOffset
        }
        
        // Update window position before rebuild
        runningAppsWindow.setFrameOrigin(NSPoint(x: newX, y: runningAppsWindow.frame.minY))
        
        // Clear all content and force complete rebuild
        if let contentView = runningAppsWindow.contentView {
            contentView.subviews.forEach { $0.removeFromSuperview() }
            
            // Use debounced update
            debouncedUpdateRunningApps()
        }
    }
}

