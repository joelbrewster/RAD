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
    var recentAppOrder: [String] = []  // Track app usage order by bundle ID
    var updateWorkDebounceTimer: Timer?
    var isUpdating: Bool = false
    private var lastActiveWindowId: String?
    private var lastActiveWorkspace: String?
    var currentDockPosition: DockPosition = {
        if let savedPosition = UserDefaults.standard.string(forKey: "dockPosition"),
           let position = DockPosition(rawValue: savedPosition) {
            return position
        }
        return .center  // Default to center
    }()
    
    var currentDockSize: DockSize = {
        if let savedSize = UserDefaults.standard.string(forKey: "dockSize"),
           let size = DockSize(rawValue: savedSize) {
            return size
        }
        return .medium  // Default to medium
    }()

    // PADDING VALUES TO CONSOLIDATE:
    var currentIconSize: CGFloat { currentDockSize.iconSize }  // Dynamic size based on DockSize
    
    // Scale padding values based on icon size
    var horizontalPadding: CGFloat { currentIconSize * 0.25 }  // [1] Main container edge padding (left/right)
    var verticalPadding: CGFloat { currentIconSize * 0.25 }    // [1] Main container edge padding (top/bottom)
    var groupSpacing: CGFloat { currentIconSize * 0.25 }       // [2] Space between workspace groups in main container
    let shadowPadding: CGFloat = 0      // [3] Shadow offset for window positioning
    
    // View references
    private var mainStackView: NSStackView?
    
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
                // Add new apps to the end of the list
                recentAppOrder.append(bundleID)
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
        // If an update is in progress, only schedule follow-up if new source has higher priority
        if isUpdating {
            if source.priority > pendingUpdateSource.priority {
                pendingUpdateSource = source
                needsFollowUpUpdate = true
            }
            return
        }
        
        // Cancel any pending timer
        updateWorkDebounceTimer?.invalidate()
        
        // Schedule new update with longer interval
        updateWorkDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            guard let self = self else { return }
            
            self.isUpdating = true
            self.updateSource = source
            
            // Clear cache if it's too old or if this is a high-priority update
            if let timestamp = self.workspaceCacheTimestamp,
               (Date().timeIntervalSince(timestamp) >= self.workspaceCacheLifetime || source.priority >= UpdateSource.windowMove.priority) {
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
                    self.needsFollowUpUpdate = false
                    let nextSource = self.pendingUpdateSource
                    self.pendingUpdateSource = .none
                    self.debouncedUpdateRunningApps(source: nextSource)
                }
            }
        }
    }
    
    func updateRunningApps() {
        // Get the focused workspace first
        var focusedWorkspace: String? = nil
        if let workspaceOutput = runAerospaceCommand(args: ["list-workspaces", "--focused"]) {
            focusedWorkspace = workspaceOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        }

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
        
        // Calculate dimensions
        let iconSize = NSSize(width: currentIconSize, height: currentIconSize)
        let spacing: CGFloat = 4  // Spacing between icons
        let workspaceNumberWidth: CGFloat = 8  // Width for workspace number
        
        // Create container view that will size to fit content
        let containerView = DockContainerView(frame: .zero)
        containerView.appDelegate = self
        containerView.wantsLayer = true
        
        // Create background view that will size to fit content
        let backgroundView = NSView(frame: .zero)
        backgroundView.wantsLayer = true
        
        // Create visual effect view for blur
        let blurView = NSVisualEffectView(frame: .zero)
        blurView.blendingMode = .behindWindow
        blurView.state = .active
        blurView.material = .hudWindow  // Closest to SwiftUI's ultraThinMaterial
        blurView.wantsLayer = true
        blurView.isEmphasized = false
        blurView.appearance = NSApp.effectiveAppearance
        blurView.layer?.borderWidth = 0
                    blurView.layer?.cornerRadius = 8  // [7] Corner radius for main container background
        blurView.alphaValue = 1.0
        
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
        
        // Create main stack view that will size to fit content
        mainStackView = NSStackView(frame: .zero)
        mainStackView?.orientation = .horizontal
        mainStackView?.spacing = groupSpacing
        mainStackView?.distribution = .gravityAreas
        mainStackView?.alignment = .centerY
        
        if let mainStackView = self.mainStackView {
            blurView.addSubview(mainStackView)
            containerView.addSubview(backgroundView)
            
            // Setup constraints to make views resize with content
            mainStackView.translatesAutoresizingMaskIntoConstraints = false
            backgroundView.translatesAutoresizingMaskIntoConstraints = false
            blurView.translatesAutoresizingMaskIntoConstraints = false
            containerView.translatesAutoresizingMaskIntoConstraints = false
            
            // Set hugging and compression resistance
            mainStackView.setContentHuggingPriority(.defaultHigh, for: .horizontal)
            mainStackView.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
            
            NSLayoutConstraint.activate([
                // Main stack view constraints - let it determine its own size
                mainStackView.leadingAnchor.constraint(equalTo: blurView.leadingAnchor, constant: horizontalPadding),
                mainStackView.trailingAnchor.constraint(equalTo: blurView.trailingAnchor, constant: -horizontalPadding),
                mainStackView.topAnchor.constraint(equalTo: blurView.topAnchor, constant: verticalPadding),
                mainStackView.bottomAnchor.constraint(equalTo: blurView.bottomAnchor, constant: -verticalPadding),
            
            // Background view constraints - size to container
            backgroundView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            backgroundView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            backgroundView.topAnchor.constraint(equalTo: containerView.topAnchor),
            backgroundView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            
            // Blur view constraints - size to background
            blurView.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor),
            blurView.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor),
            blurView.topAnchor.constraint(equalTo: backgroundView.topAnchor),
            blurView.bottomAnchor.constraint(equalTo: backgroundView.bottomAnchor),
            
            // Container constraints - size to main stack
            containerView.widthAnchor.constraint(equalTo: mainStackView.widthAnchor, constant: horizontalPadding * 2),
            containerView.heightAnchor.constraint(equalTo: mainStackView.heightAnchor, constant: verticalPadding * 2)
        ])}
        
        // Add apps for each group
        for group in groups {
            let workspaceContainer = NSStackView(frame: .zero)
            workspaceContainer.orientation = .horizontal
            workspaceContainer.spacing = currentIconSize * 0.0625  // [4] Space between workspace number and icon group (2px at 32px)
            workspaceContainer.distribution = .fill
            workspaceContainer.alignment = .centerY
            
            // Create container for workspace with custom background
            let visualContainer = NSView(frame: .zero)
            visualContainer.wantsLayer = true
            visualContainer.layer?.cornerRadius = 6  // [6] Corner radius for workspace group background
            
            // Set background color based on active state and appearance mode
            let isActive = group.workspace == focusedWorkspace
            let isDarkMode = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            
            // Create pure white color in sRGB color space
            let whiteColor = NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
            
            // Set opacity exactly as specified for each mode
            let opacity: CGFloat
            if isActive {
                opacity = isDarkMode ? 0.4 : 0.8  // Active: dark=0.4, light=0.8
            } else {
                opacity = isDarkMode ? 0.1 : 0.4  // Inactive: dark=0.1, light=0.4
            }
            
            visualContainer.layer?.backgroundColor = whiteColor.withAlphaComponent(opacity).cgColor
            
            visualContainer.addSubview(workspaceContainer)
            
            // Keep the workspaceContainer exactly as it was, just constrain it to fill the visual wrapper
            workspaceContainer.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                workspaceContainer.topAnchor.constraint(equalTo: visualContainer.topAnchor, constant: 6),
                workspaceContainer.bottomAnchor.constraint(equalTo: visualContainer.bottomAnchor, constant: -6),
                workspaceContainer.leadingAnchor.constraint(equalTo: visualContainer.leadingAnchor, constant: 6),
                workspaceContainer.trailingAnchor.constraint(equalTo: visualContainer.trailingAnchor, constant: -6)
            ])
            
            // Add workspace label with updated style for active state
            let label = NSTextField(frame: .zero)
            label.stringValue = group.workspace
            label.isEditable = false
            label.isBordered = false
            label.backgroundColor = .clear
            label.textColor = isActive ? .labelColor : .tertiaryLabelColor
            label.font = NSFont.monospacedSystemFont(ofSize: currentIconSize * 0.4375, weight: isActive ? .bold : .medium) // Scales font with icon size (14pt at 32px)
            label.alignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                label.widthAnchor.constraint(equalToConstant: 20)
            ])
            workspaceContainer.addArrangedSubview(label)
            
            // Create stack view for this group's icons with proper constraints
            let groupStack = NSStackView(frame: .zero)
            groupStack.orientation = .horizontal
            groupStack.spacing = 4  // [5] Space between individual icons in a group
            groupStack.distribution = .fillEqually
            groupStack.alignment = .centerY
            workspaceContainer.addArrangedSubview(groupStack)
            
            // Add apps for this group
            for window in group.windows {
                // Try to get icon from running app first
                var appIcon: NSImage?
                
                if let app = NSRunningApplication(processIdentifier: pid_t(window.pid)) {
                    // Special case for Calendar.app
                    if window.appName.lowercased().contains("calendar") {
                        if let calendarApp = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
                            appIcon = NSWorkspace.shared.icon(forFile: calendarApp.path)
                        }
                    } else {
                        appIcon = app.icon
                    }
                }
                
                guard let icon = appIcon else { continue }
                
                let imageView = ClickableImageView(frame: NSRect(x: 0, y: 0, width: currentIconSize, height: currentIconSize))
                imageView.image = icon
                imageView.imageScaling = .scaleProportionallyUpOrDown
                imageView.wantsLayer = true
                imageView.layer?.cornerRadius = currentIconSize * 0.1875 // Scales corner radius with size (6px at 32px)
                imageView.layer?.masksToBounds = true
                imageView.tag = Int(window.pid)
                
                // Scale the image to fit the view size while maintaining aspect ratio
                let scaledImage = NSImage(size: NSSize(width: currentIconSize, height: currentIconSize))
                scaledImage.lockFocus()
                let drawRect = NSRect(x: 0, y: 0, width: currentIconSize, height: currentIconSize)
                icon.draw(in: drawRect, from: .zero, operation: .copy, fraction: 1.0)
                scaledImage.unlockFocus()
                imageView.image = scaledImage
                
                // Add size constraints to ensure exact size
                imageView.translatesAutoresizingMaskIntoConstraints = false
                NSLayoutConstraint.activate([
                    imageView.widthAnchor.constraint(equalToConstant: currentIconSize),
                    imageView.heightAnchor.constraint(equalToConstant: currentIconSize)
                ])
                
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
                            app.activate()
                        }
                    }
                }
                
                groupStack.addArrangedSubview(imageView)
            }
            
            // Add to main stack view
            mainStackView?.addArrangedSubview(visualContainer)
        }
        
        // Force layout of the entire view hierarchy
        containerView.layoutSubtreeIfNeeded()
        
        guard let mainStackView = self.mainStackView else { return }
        
        // Get the natural size after layout
        let stackSize = mainStackView.fittingSize
        let totalWidth = stackSize.width + (horizontalPadding * 2)
        let totalHeight = stackSize.height + (verticalPadding * 2)
        
        // Update window size first
        let currentFrame = runningAppsWindow.frame
        runningAppsWindow.setFrame(NSRect(x: currentFrame.minX, 
                                        y: currentFrame.minY,
                                        width: totalWidth,
                                        height: totalHeight), 
                                 display: false)
        
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
            
            print("Positioning dock \(currentDockPosition) at x: \(xPosition)")
            print("Stack natural size - width: \(stackSize.width), height: \(stackSize.height)")
            
            let yPosition = mainScreen.visibleFrame.minY
            let newFrame = NSRect(x: xPosition, y: yPosition, width: totalWidth, height: totalHeight)
            
            print("Setting window frame - x: \(xPosition), y: \(yPosition), width: \(totalWidth), height: \(totalHeight)")
            print("Screen visible frame - x: \(mainScreen.visibleFrame.minX), y: \(mainScreen.visibleFrame.minY), width: \(mainScreen.visibleFrame.width), height: \(mainScreen.visibleFrame.height)")
            
            runningAppsWindow.setFrame(newFrame, display: true)
        }
        
        runningAppsWindow.contentView = containerView
        

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
                    let info = WindowInfo(pid: Int(window.pid), title: window.title, appName: window.name)
                    // print("Created WindowInfo - PID: \(info.pid), Name: \(info.appName)")
                    if let app = NSRunningApplication(processIdentifier: pid_t(info.pid)), app.icon != nil {
                        // print("Found running app: \(app.localizedName ?? "unknown") with icon")
                    } else {
                        // print("No running app or icon found for PID \(info.pid)")
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
        
        let allWorkspaces = workspaceOutput.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            
        // Only return workspaces that have windows in them
        return allWorkspaces.filter { workspace in
            if let windowOutput = runAerospaceCommand(args: ["list-windows", "--workspace", workspace]) {
                let windows = windowOutput.components(separatedBy: .newlines)
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                return !windows.isEmpty
            }
            return false
        }
    }
    
    private func getWindowsForWorkspace(_ workspace: String) -> [(pid: Int32, title: String, name: String)] {
        // Get the focused window first
        if let focusedWindow = runAerospaceCommand(args: ["list-windows", "--focused"]) {
            let windowInfo = focusedWindow.trimmingCharacters(in: .whitespacesAndNewlines)
            if windowInfo != lastActiveWindowId {
                lastActiveWindowId = windowInfo
                
                // Get the current workspace
                if let workspaceOutput = runAerospaceCommand(args: ["list-workspaces", "--focused"]) {
                    let workspace = workspaceOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                    if workspace != lastActiveWorkspace {
                        lastActiveWorkspace = workspace
                        print("Active window: \(windowInfo) in workspace: \(workspace)")
                    }
                }
            }
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
    
    func switchToWorkspace(_ workspace: String) {
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
    var onRightClick: ((ClickableImageView) -> Void)?
    
    override func mouseDown(with event: NSEvent) {
        onClick?(self)
    }
    
    override func rightMouseDown(with event: NSEvent) {
        if let app = NSRunningApplication(processIdentifier: pid_t(tag)) {
            print("Right clicked app: \(app.localizedName ?? "Unknown") in workspace: \(workspace ?? "Unknown")")
            
            // Switch to workspace first
            if let workspace = workspace,
               let appDelegate = NSApp.delegate as? RunningAppDisplayApp {
                appDelegate.switchToWorkspace(workspace)
            }
            
            // Focus the app after a short delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                app.activate(options: .activateIgnoringOtherApps)
                
                // Try to create new window after app is activated
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    self.createNewWindow()
                }
            }
        }
        onRightClick?(self)
    }
    
    private func createNewWindow() {
        // Create the keyboard event for Command+N
        let eventCallback: CGEventTapCallBack = { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
            return Unmanaged.passRetained(event)
        }
        
        // Create an event source
        if let eventSource = CGEventSource(stateID: .hidSystemState) {
            let nKeycode: CGKeyCode = 45  // 'n' key
            
            // Create key events
            if let keyDownEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: nKeycode, keyDown: true) {
                keyDownEvent.flags = .maskCommand
                
                if let keyUpEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: nKeycode, keyDown: false) {
                    // Post the events
                    keyDownEvent.post(tap: .cghidEventTap)
                    keyUpEvent.post(tap: .cghidEventTap)
                }
            }
        } else {
            // If we can't create events, we need accessibility permissions
            let alert = NSAlert()
            alert.messageText = "Accessibility Permissions Required"
            alert.informativeText = "To create new windows, RunningAppDisplay needs accessibility permissions. Please enable them in System Settings > Privacy & Security > Accessibility."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Cancel")
            
            if alert.runModal() == .alertFirstButtonReturn {
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
        }
    }
}

enum DockSize: String {
    case small = "small"
    case medium = "medium"
    case large = "large"
    
    var iconSize: CGFloat {
        switch self {
        case .small: return 24
        case .medium: return 32
        case .large: return 48
        }
    }
}

enum DockPosition: String {
    case left = "left"
    case center = "center"
    case right = "right"
}

class DockContainerView: NSView {
    weak var appDelegate: RunningAppDisplayApp?
    
    override func rightMouseDown(with event: NSEvent) {
        let menu = NSMenu()
        menu.autoenablesItems = true
        
        // Size submenu
        let sizeMenu = NSMenu()
        let sizeMenuItem = NSMenuItem(title: "Size", action: nil, keyEquivalent: "")
        sizeMenuItem.submenu = sizeMenu
        
        // Add size options
        let sizes: [(title: String, size: DockSize)] = [
            ("Small", .small),
            ("Medium", .medium),
            ("Large", .large)
        ]
        
        for (title, size) in sizes {
            let item = NSMenuItem(title: title, action: #selector(handleSizeSelection(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = size
            item.state = appDelegate?.currentDockSize == size ? .on : .off
            sizeMenu.addItem(item)
        }
        
        // Position submenu
        let positionMenu = NSMenu()
        let positionMenuItem = NSMenuItem(title: "Position", action: nil, keyEquivalent: "")
        positionMenuItem.submenu = positionMenu
        
        // Add position options
        let positions: [(title: String, position: DockPosition)] = [
            ("Left", .left),
            ("Center", .center),
            ("Right", .right)
        ]
        
        for (title, position) in positions {
            let item = NSMenuItem(title: title, action: #selector(handlePositionSelection(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = position
            item.state = appDelegate?.currentDockPosition == position ? .on : .off
            positionMenu.addItem(item)
        }
        
        menu.addItem(sizeMenuItem)
        menu.addItem(positionMenuItem)
        
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
    
    @objc private func handleSizeSelection(_ sender: NSMenuItem) {
        guard let size = sender.representedObject as? DockSize else { return }
        appDelegate?.updateDockSize(size)
    }
    
    @objc private func handlePositionSelection(_ sender: NSMenuItem) {
        guard let position = sender.representedObject as? DockPosition else { return }
        appDelegate?.updateDockPosition(position)
    }
}



extension RunningAppDisplayApp {
    func updateDockSize(_ newSize: DockSize) {
        currentDockSize = newSize
        UserDefaults.standard.set(newSize.rawValue, forKey: "dockSize")
        debouncedUpdateRunningApps()
    }
    
    func updateDockPosition(_ newPosition: DockPosition) {
        guard let screen = NSScreen.main else { return }
        
        // Update position state
        currentDockPosition = newPosition
        UserDefaults.standard.set(newPosition.rawValue, forKey: "dockPosition")
        
        // Force layout to get correct size
        if let contentView = runningAppsWindow.contentView {
            contentView.layoutSubtreeIfNeeded()
        }
        
        guard let mainStackView = self.mainStackView else { return }
        
        // Get the natural size of the content
        let stackSize = mainStackView.fittingSize
        let totalWidth = stackSize.width + (horizontalPadding * 2)
        let totalHeight = stackSize.height + (verticalPadding * 2)
        
        // Calculate new window position
        let newX: CGFloat = switch newPosition {
        case .left:
            screen.visibleFrame.minX - shadowPadding
        case .center:
            (screen.visibleFrame.width - totalWidth) / 2
        case .right:
            screen.visibleFrame.maxX - totalWidth + shadowPadding
        }
        
        // Update window frame in one operation
        let newFrame = NSRect(x: newX, 
                            y: runningAppsWindow.frame.minY,
                            width: totalWidth,
                            height: totalHeight)
        runningAppsWindow.setFrame(newFrame, display: true, animate: false)
        
        // Clear all content and force complete rebuild
        if let contentView = runningAppsWindow.contentView {
            contentView.subviews.forEach { $0.removeFromSuperview() }
            
            // Use debounced update
            debouncedUpdateRunningApps()
        }
    }
}

