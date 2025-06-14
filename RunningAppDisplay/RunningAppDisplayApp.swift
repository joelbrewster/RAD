//
//  RunningAppDisplayApp.swift
//  RunningAppDisplay
//
//  Created by Joel Brewster on 25/1/2025.
//

import Cocoa
import SwiftData
import Foundation
import UniformTypeIdentifiers

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
        // print("Application did finish launching")
        let workspace = NSWorkspace.shared
        
        // Create floating window for running apps with larger height
        runningAppsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 100),
            styleMask: [.borderless, .nonactivatingPanel],  // Add nonactivatingPanel
            backing: .buffered,
            defer: false
        )
        
        // print("Created window with initial frame: \(runningAppsWindow.frame)")
        
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
        
        // Make sure window is visible but don't make it key
        runningAppsWindow.orderFront(nil)
        
        // print("Window setup complete - level: \(runningAppsWindow.level.rawValue), visible: \(runningAppsWindow.isVisible)")
        
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
                // print("Active space changed")
                self?.debouncedUpdateRunningApps(source: .spaceChange)
        }
        
        // Add observers for window changes using NSNotificationCenter.default
        let center = NotificationCenter.default
        
        // Store window observers to remove them later
        windowObservers = [
            // Window movement between spaces/screens
            center.addObserver(forName: NSWindow.didChangeScreenNotification, object: nil, queue: nil) { [weak self] _ in 
                // print("Window moved to different screen")
                self?.debouncedUpdateRunningApps(source: .windowMove)
            },
            
            // Window ordering changes
            center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: nil) { [weak self] _ in 
                // print("Window ordering changed")
                self?.debouncedUpdateRunningApps(source: .windowOrder)
            },
            
            // Window minimizing/unminimizing
            center.addObserver(forName: NSWindow.didMiniaturizeNotification, object: nil, queue: nil) { [weak self] _ in 
                // print("Window minimized")
                self?.debouncedUpdateRunningApps(source: .windowOrder)
            },
            center.addObserver(forName: NSWindow.didDeminiaturizeNotification, object: nil, queue: nil) { [weak self] _ in 
                // print("Window unminimized")
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
        // print("Debounce requested from source: \(source)")
        
        // If an update is in progress, only schedule follow-up if new source has higher priority
        if isUpdating {
            if source.priority > pendingUpdateSource.priority {
                // print("Update in progress, scheduling higher priority follow-up")
                pendingUpdateSource = source
                needsFollowUpUpdate = true
            } else {
                // print("Update in progress, ignoring lower priority update")
            }
            return
        }
        
        // Cancel any pending timer
        updateWorkDebounceTimer?.invalidate()
        
        // Schedule new update
        updateWorkDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
            // print("Timer fired")
            guard let self = self else { return }
            
            self.isUpdating = true
            self.updateSource = source
            
            // Clear cache if it's too old or if this is a high-priority update
            if let timestamp = self.workspaceCacheTimestamp,
               (Date().timeIntervalSince(timestamp) >= self.workspaceCacheLifetime || source.priority >= UpdateSource.windowMove.priority) {
                // print("Cache invalidated due to time or priority")
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
                    // print("Processing follow-up update with source: \(self.pendingUpdateSource)")
                    self.needsFollowUpUpdate = false
                    let nextSource = self.pendingUpdateSource
                    self.pendingUpdateSource = .none
                    self.debouncedUpdateRunningApps(source: nextSource)
                }
            }
        }
    }
    
    func updateRunningApps() {
        // print("Starting updateRunningApps")
        // print("Current dock position: \(currentDockPosition)")
        
        // Set critical window properties first
        runningAppsWindow.level = .popUpMenu
        runningAppsWindow.collectionBehavior = [.canJoinAllSpaces, .managed, .fullScreenAuxiliary]
        runningAppsWindow.ignoresMouseEvents = false
        runningAppsWindow.acceptsMouseMovedEvents = true
        runningAppsWindow.hasShadow = false
        runningAppsWindow.isOpaque = false
        runningAppsWindow.backgroundColor = .clear

        // Cache common icons
        let iconCache = NSCache<NSString, NSImage>()
        
        // Get workspace groups
        let groups = getWorkspaceGroups()
        // print("Got \(groups.count) workspace groups with \(groups.reduce(0) { $0 + $1.windows.count }) total windows")
        
        // Calculate dimensions
        let iconSize = NSSize(width: currentIconSize, height: currentIconSize)
        let spacing: CGFloat = 4  // Tighter spacing between icons
        let groupSpacing: CGFloat = 16  // Space between workspace groups
        let horizontalPadding: CGFloat = 6
        let verticalPadding: CGFloat = 6
        let shadowPadding: CGFloat = 0
        let resizeHandleHeight: CGFloat = 8
        
        // Calculate total number of windows and groups for sizing
        let totalWindows = groups.reduce(0) { $0 + $1.windows.count }
        let totalGroups = groups.count
        
        // Calculate exact sizes
        let contentWidth = CGFloat(totalWindows) * iconSize.width + 
                         CGFloat(totalWindows - 1) * spacing +  // Spacing between icons
                         CGFloat(max(0, totalGroups - 1)) * (groupSpacing - spacing) +  // Extra space between groups
                         CGFloat(totalGroups) * 16 + // Space for workspace numbers
                         (horizontalPadding * 2)
        let contentHeight: CGFloat = iconSize.height + (verticalPadding * 2) + resizeHandleHeight
        let totalWidth = contentWidth
        let totalHeight = contentHeight
        
        // Create container view
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: totalWidth, height: totalHeight))
        containerView.wantsLayer = true
        
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
        
        // Create visual effect view for blur
        let blurView = NSVisualEffectView(frame: backgroundView.bounds)
        blurView.blendingMode = .behindWindow
        blurView.state = .active
        blurView.material = .hudWindow
        blurView.alphaValue = 0.7
        blurView.wantsLayer = true
        blurView.isEmphasized = true
        blurView.appearance = NSApp.effectiveAppearance
        blurView.layer?.borderWidth = 0
        blurView.layer?.cornerRadius = 12
        
        // Set corner masking based on position
        switch currentDockPosition {
        case .left:
            blurView.layer?.maskedCorners = [.layerMaxXMaxYCorner]
        case .center:
            blurView.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        case .right:
            blurView.layer?.maskedCorners = [.layerMinXMaxYCorner]
        }
        
        // Set up view hierarchy
        backgroundView.addSubview(blurView)
        
        // Create main stack view with padding
        let mainStackView = NSStackView(frame: NSRect(x: horizontalPadding, 
                                                    y: verticalPadding,
                                                    width: contentWidth - (horizontalPadding * 2),
                                                    height: iconSize.height))
        mainStackView.orientation = .horizontal
        mainStackView.spacing = groupSpacing
        mainStackView.distribution = .gravityAreas
        mainStackView.alignment = .centerY
        
        blurView.addSubview(mainStackView)
        containerView.addSubview(backgroundView)
        
        // Add apps for each group
        for group in groups {
            // Create container for workspace group
            let workspaceContainer = NSStackView(frame: .zero)
            workspaceContainer.orientation = .horizontal
            workspaceContainer.spacing = 4
            workspaceContainer.distribution = .gravityAreas
            workspaceContainer.alignment = .centerY
            
            // Just wrap the container in a visual style
            let visualContainer = NSView(frame: .zero)
            visualContainer.wantsLayer = true
            visualContainer.layer?.cornerRadius = 6
            visualContainer.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.15).cgColor
            visualContainer.addSubview(workspaceContainer)
            
            // Keep the workspaceContainer exactly as it was, just constrain it to fill the visual wrapper
            workspaceContainer.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                workspaceContainer.topAnchor.constraint(equalTo: visualContainer.topAnchor),
                workspaceContainer.bottomAnchor.constraint(equalTo: visualContainer.bottomAnchor),
                workspaceContainer.leadingAnchor.constraint(equalTo: visualContainer.leadingAnchor),
                workspaceContainer.trailingAnchor.constraint(equalTo: visualContainer.trailingAnchor)
            ])
            
            // Add workspace label
            let label = NSTextField(frame: NSRect(x: 0, y: 0, width: 12, height: 14))
            label.stringValue = group.workspace
            label.isEditable = false
            label.isBordered = false
            label.backgroundColor = .clear
            label.textColor = .secondaryLabelColor
            label.font = NSFont.systemFont(ofSize: 10, weight: .medium)
            label.alignment = .center
            workspaceContainer.addArrangedSubview(label)
            
            // Add separator before group (except first group)
            if let firstGroup = groups.first, group.workspace != firstGroup.workspace {
                let separator = NSView(frame: NSRect(x: -groupSpacing/2, y: 2, width: 1, height: iconSize.height - 4))
                separator.wantsLayer = true
                separator.layer?.backgroundColor = NSColor.separatorColor.withAlphaComponent(0.3).cgColor
                workspaceContainer.addSubview(separator)
            }
            
            // Create stack view for this group's icons
            let groupStack = NSStackView(frame: .zero)
            groupStack.orientation = .horizontal
            groupStack.spacing = spacing
            groupStack.distribution = .gravityAreas
            groupStack.alignment = .centerY
            workspaceContainer.addArrangedSubview(groupStack)
            
            // Add apps for this group
            for window in group.windows {
                // Try to get icon from running app first
                var appIcon: NSImage?
                var isHidden = false
                
                                    if let app = NSRunningApplication(processIdentifier: pid_t(window.pid)) {
                        // Check cache first
                        let cacheKey = "\(app.bundleIdentifier ?? String(app.processIdentifier))" as NSString
                    if let cachedIcon = iconCache.object(forKey: cacheKey) {
                        appIcon = cachedIcon
                    } else {
                        appIcon = app.icon
                        if let icon = appIcon {
                            iconCache.setObject(icon, forKey: cacheKey)
                        }
                    }
                    isHidden = app.isHidden
                }
                
                // Fallback to system icons if no running app found
                if appIcon == nil {
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
                        let cacheKey = appPath as NSString
                        if let cachedIcon = iconCache.object(forKey: cacheKey) {
                            appIcon = cachedIcon
                        } else {
                            appIcon = NSWorkspace.shared.icon(forFile: appPath)
                            if let icon = appIcon {
                                iconCache.setObject(icon, forKey: cacheKey)
                            }
                        }
                    }
                }
                
                // Final fallback to generic app icon
                if appIcon == nil {
                    appIcon = NSWorkspace.shared.icon(for: UTType.application)
                }
                
                // Ensure we have an icon and size it correctly
                guard let icon = appIcon else { continue }
                icon.size = NSSize(width: currentIconSize - 2, height: currentIconSize - 2)
                
                let imageView = ClickableImageView(frame: NSRect(x: 0, y: 0, width: iconSize.width, height: iconSize.height))
                imageView.imageScaling = .scaleProportionallyDown
                imageView.image = icon
                imageView.wantsLayer = true
                imageView.layer?.cornerRadius = 6
                imageView.layer?.masksToBounds = true
                imageView.tag = Int(window.pid)
                imageView.alphaValue = isHidden ? 0.5 : 1.0
                
                // Store workspace info for click handling
                imageView.workspace = group.workspace
                
                // Add click handler
                imageView.onClick = { [weak self] imageView in
                    guard let workspace = imageView.workspace else { return }
                    
                    // Switch to workspace first
                    self?.switchToWorkspace(workspace)
                    
                    // Focus the window after a short delay
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        if let app = NSRunningApplication(processIdentifier: pid_t(imageView.tag)) {
                            app.activate(options: .activateIgnoringOtherApps)
                        }
                    }
                }
                
                groupStack.addArrangedSubview(imageView)
            }
            
            // Add to main stack view using the visual wrapper
            mainStackView.addArrangedSubview(visualContainer)
        }
        
        // Position window
        if let mainScreen = NSScreen.screens.first {
            let xPosition: CGFloat = switch currentDockPosition {
            case .left:
                mainScreen.visibleFrame.minX - shadowPadding
            case .center:
                (mainScreen.visibleFrame.width - totalWidth) / 2 + mainScreen.visibleFrame.minX
            case .right:
                mainScreen.visibleFrame.maxX - totalWidth + shadowPadding
            }
            
            let yPosition = mainScreen.visibleFrame.minY
            let newFrame = NSRect(x: xPosition, y: yPosition, width: totalWidth, height: totalHeight)
            
            runningAppsWindow.setFrame(newFrame, display: true)
        }
        
        runningAppsWindow.contentView = containerView
        
        // Add edge handles
        leftHandle = EdgeHandleView(frame: NSRect(x: shadowPadding, 
                                                y: shadowPadding,
                                                width: 20,
                                                height: contentHeight - resizeHandleHeight),
                                  isLeft: true)
        leftHandle?.delegate = self
        
        rightHandle = EdgeHandleView(frame: NSRect(x: shadowPadding + contentWidth - 20,
                                                 y: shadowPadding,
                                                 width: 20,
                                                 height: contentHeight - resizeHandleHeight),
                                   isLeft: false)
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
            let task = Process()
            task.executableURL = URL(fileURLWithPath: path)
            task.arguments = args
            
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
                    print("Error: \(errorOutput)")
                }
                
                if let output = String(data: data, encoding: .utf8) {
                    return output
                }
            } catch {
                continue
            }
        }
        return nil
    }

    struct WindowInfo: Codable {
        let pid: Int
        let title: String
        let appName: String
        let isHidden: Bool
        
        var appIcon: NSImage? {
            if let app = NSRunningApplication(processIdentifier: pid_t(pid)) {
                // print("Getting icon for PID \(pid): \(app.localizedName ?? "unknown"), Has icon: \(app.icon != nil)")
                return app.icon
            }
            // print("Failed to get icon for PID \(pid)")
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
            // print("Using cached workspace data (age: \(Date().timeIntervalSince(timestamp))s)")
            return cache
        }
        
        // print("=== Getting Fresh Workspace Groups ===")
        var groups: [WorkspaceGroup] = []
        
        // Get list of workspaces
        let workspaces = getWorkspaces()
        // print("Found \(workspaces.count) workspaces: \(workspaces)")
        
        // Get windows for each workspace
        for workspace in workspaces {
            // print("\nGetting windows for workspace: \(workspace)")
            let windows = getWindowsForWorkspace(workspace)
            if !windows.isEmpty {
                let windowInfos = windows.map { window -> WindowInfo in
                    let info = WindowInfo(pid: Int(window.pid), title: window.title, appName: window.name, isHidden: false)
                    // print("Created WindowInfo - PID: \(info.pid), Name: \(info.appName)")
                    if let app = NSRunningApplication(processIdentifier: pid_t(info.pid)) {
                        // print("Found running app: \(app.localizedName ?? "unknown"), Has icon: \(app.icon != nil)")
                    } else {
                        // print("No running app found for PID \(info.pid)")
                    }
                    return info
                }
                groups.append(WorkspaceGroup(workspace: workspace, windows: windowInfos))
                // print("Found \(windows.count) windows in workspace \(workspace)")
            }
        }
        
        // print("\nUpdating cache with \(groups.count) workspace groups")
        workspaceCache = groups
        workspaceCacheTimestamp = Date()
        
        return groups
    }
    
    private func getWorkspaces() -> [String] {
        guard let workspaceOutput = runAerospaceCommand(args: ["list-workspaces", "--all"]) else {
            // print("Failed to get workspace list")
            return []
        }
        
        return workspaceOutput.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
    
    private func getWindowsForWorkspace(_ workspace: String) -> [(pid: Int32, title: String, name: String)] {
        // Get the focused window first
        if let focusedWindow = runAerospaceCommand(args: ["list-windows", "--focused"]) {
            print("Active window: \(focusedWindow)")
        }
        
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
                
                let appName = parts[1].trimmingCharacters(in: .whitespaces)
                
                // Find running app by name
                if let app = NSWorkspace.shared.runningApplications.first(where: { 
                    $0.localizedName?.lowercased() == appName.lowercased() ||
                    $0.bundleIdentifier?.lowercased().contains(appName.lowercased()) == true
                }) {
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
                    return (pid: app.processIdentifier, title: parts[1], name: parts[2])
                }
                
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
    
    private func switchToWorkspace(_ workspace: String) {
        // Run workspace switch async to not block UI
        DispatchQueue.global(qos: .userInteractive).async { [weak self] in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/aerospace")
            task.arguments = ["workspace", workspace]
            
            do {
                try task.run()
                task.waitUntilExit()
                
                // Small delay to ensure workspace switch completes
                Thread.sleep(forTimeInterval: 0.1)
                
                // Now activate the window on the main thread
                DispatchQueue.main.async {
                    self?.debouncedUpdateRunningApps()
                }
            } catch {
                // print("Error switching workspace: \(error)")
            }
        }
    }
}

// Add this class at the top level
class ClickableImageView: NSImageView {
    var workspace: String?
    var onClick: ((ClickableImageView) -> Void)?
    
    override func mouseDown(with event: NSEvent) {
        onClick?(self)
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
        // print("=== DRAG START ===")
        // print("Initial Y: \(lastY)")
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
                // print("Resizing to: \(newSize) (Delta: \(deltaY))")
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
        // print("=== DRAG END ===")
        // print("Final Y: \(NSEvent.mouseLocation.y)")
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
            // print("Moving dock LEFT from \(currentPosition)")
            delegate?.handleEdgeDrag(fromLeftEdge: true, currentPosition: currentPosition)
            isDragging = false
        } else if (!isLeftHandle && deltaX > 10) {
            // print("Moving dock RIGHT from \(currentPosition)")
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

