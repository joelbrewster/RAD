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
    
    // Add icon cache
    private var iconCache: [Int: NSImage] = [:]
    private var iconCacheTimestamp: Date?
    private let iconCacheLifetime: TimeInterval = 5.0 // Cache icons for 5 seconds
    
    // Add properties at top of class
    private var updateQueue = DispatchQueue(label: "com.runningappdisplay.updates", qos: .userInteractive)
    private var lastWorkspaceData: [WorkspaceGroup]?
    private var isPreparingUpdate = false
    
    // Cache for sorted workspaces since they don't change during runtime
    private var sortedWorkspaces: [String]? = nil
    // Cache for workspace groups, invalidated only when windows change
    private var cachedWorkspaceGroups: [WorkspaceGroup]? = nil
    
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
        
        // Modify the workspace change observer
        // Remove workspace change observer - we handle this directly in switchToWorkspace
        
        // Add observers for window changes using NotificationCenter.default
        let center = NotificationCenter.default
        
        // Store window observers to remove them later
        windowObservers = [
            // Window movement between spaces/screens
            center.addObserver(forName: NSWindow.didChangeScreenNotification, object: nil, queue: nil) { [weak self] _ in 
                print("Window moved to different screen")
                self?.invalidateWindowCache()
                self?.debouncedUpdateRunningApps(source: .windowMove)
            },
            
            // Window ordering changes
            center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: nil) { [weak self] _ in 
                print("Window ordering changed")
                self?.invalidateWindowCache()
                self?.debouncedUpdateRunningApps(source: .windowOrder)
            },
            
            // Window minimizing/unminimizing
            center.addObserver(forName: NSWindow.didMiniaturizeNotification, object: nil, queue: nil) { [weak self] _ in 
                print("Window minimized")
                self?.invalidateWindowCache()
                self?.debouncedUpdateRunningApps(source: .windowOrder)
            },
            center.addObserver(forName: NSWindow.didDeminiaturizeNotification, object: nil, queue: nil) { [weak self] _ in 
                print("Window unminimized")
                self?.invalidateWindowCache()
                self?.debouncedUpdateRunningApps(source: .windowOrder)
            }
        ]
        
        // Add workspace change observer
        if let workspaceOutput = runAerospaceCommand(args: ["list-workspaces", "--focused"]) {
            lastActiveWorkspace = workspaceOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        
        // Add workspace change check timer (less frequent to reduce spam)
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            if let workspaceOutput = self.runAerospaceCommand(args: ["list-workspaces", "--focused"]) {
                let workspace = workspaceOutput.trimmingCharacters(in: .whitespacesAndNewlines)
                
                // Also check which window is currently focused - handle errors gracefully
                let focusedWindow = self.runAerospaceCommand(args: ["list-windows", "--focused"])?.trimmingCharacters(in: .whitespacesAndNewlines)
                
                let workspaceChanged = workspace != self.lastActiveWorkspace
                let windowChanged = focusedWindow != self.lastActiveWindowId
                
                if workspaceChanged || windowChanged {
                    // Hide tooltips immediately when workspace or window changes
                    DockTooltipWindow.getSharedWindow().alphaValue = 0.0
                    self.lastActiveWorkspace = workspace
                    self.lastActiveWindowId = focusedWindow
                    
                    // Update indicators immediately - no delay
                    self.updateWorkspaceIndicatorsOnly(workspace: workspace)
                    
                    if workspaceChanged {
                        // Workspace changed - check if it has windows only if we haven't checked recently
                        let hasWindows = (self.runAerospaceCommand(args: ["list-windows", "--workspace", workspace])?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                        
                        if hasWindows {
                            // Workspace has content - do full update quickly
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                self.debouncedUpdateRunningApps(source: .spaceChange)
                            }
                        } else {
                            // Empty workspace - longer delay for full update
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                self.debouncedUpdateRunningApps(source: .spaceChange)
                            }
                        }
                    }
                    // Remove window-only updates to reduce spam
                }
            }
        }
        
        // Add window check timer (less frequent to reduce spam)
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.checkForWindowChanges()
        }
        
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
        // Cancel any pending timer
        updateWorkDebounceTimer?.invalidate()
        
        // Use longer debounce time to prevent rapid-fire updates
        updateWorkDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: false) { [weak self] _ in
            self?.updateRunningApps()
        }
    }
    
    private func prepareWorkspaceUpdate() {
        guard !isPreparingUpdate else { return }
        isPreparingUpdate = true
        
        updateQueue.async { [weak self] in
            guard let self = self else { return }
            
            // Get workspace data in background
            let groups = self.getWorkspaceGroups()
            
            // Update UI on main thread
            DispatchQueue.main.async {
                self.lastWorkspaceData = groups
                self.updateRunningApps(with: groups)
                self.isPreparingUpdate = false
                
                // Reset flags after a brief delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
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
    }
    
    func updateRunningApps(with groups: [WorkspaceGroup]? = nil) {
        print("\n=== Layout Update ===")
        print("Current Dock Position: \(currentDockPosition)")
        print("Current Dock Size: \(currentDockSize) (Icon Size: \(currentIconSize))")
        print("Padding - Horizontal: \(horizontalPadding), Vertical: \(verticalPadding), Group Spacing: \(groupSpacing)")
        
        let workspaceGroups = groups ?? lastWorkspaceData ?? getWorkspaceGroups()
        print("Number of Workspace Groups: \(workspaceGroups.count)")
        
        // Get the focused workspace first
        var focusedWorkspace: String? = nil
        if let workspaceOutput = runAerospaceCommand(args: ["list-workspaces", "--focused"]) {
            focusedWorkspace = workspaceOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            print("Focused Workspace: \(focusedWorkspace ?? "None")")
        }

        // Set critical window properties first
        runningAppsWindow.level = .popUpMenu
        runningAppsWindow.collectionBehavior = [.canJoinAllSpaces, .managed, .fullScreenAuxiliary]
        runningAppsWindow.ignoresMouseEvents = false
        runningAppsWindow.acceptsMouseMovedEvents = true
        runningAppsWindow.hasShadow = false
        runningAppsWindow.isOpaque = false
        runningAppsWindow.backgroundColor = .clear

        // Calculate dimensions
        let xiconSize = NSSize(width: currentIconSize, height: currentIconSize)
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
        for group in workspaceGroups {
            let workspaceContainer = NSStackView(frame: .zero)
            workspaceContainer.orientation = .horizontal
            workspaceContainer.spacing = group.windows.isEmpty ? 0 : (currentIconSize * 0.0625)  // Only add spacing if there are windows
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
                // Add 6pt padding at the top of the workspace container
                workspaceContainer.topAnchor.constraint(equalTo: visualContainer.topAnchor, constant: 6),
                // Add 6pt padding at the bottom of the workspace container
                workspaceContainer.bottomAnchor.constraint(equalTo: visualContainer.bottomAnchor, constant: -6),
                // Leading edge: 16pt padding for empty workspaces, 6pt when containing windows
                workspaceContainer.leadingAnchor.constraint(equalTo: visualContainer.leadingAnchor, constant: group.windows.isEmpty ? 16 : 6),
                // Trailing edge: No padding for empty workspaces, -12pt (inset) when containing windows
                // This negative inset creates space for the window icons to breathe
                workspaceContainer.trailingAnchor.constraint(equalTo: visualContainer.trailingAnchor, constant: group.windows.isEmpty ? 0 : -12)
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
            
            // Create a container for the label to control its size
            let labelContainer = NSView(frame: .zero)
            labelContainer.translatesAutoresizingMaskIntoConstraints = false
            labelContainer.addSubview(label)
            
            // Add the container to the workspace container first
            workspaceContainer.addArrangedSubview(labelContainer)
            
            // Now set up constraints after the container is in the view hierarchy
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: labelContainer.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: labelContainer.centerYAnchor),
                labelContainer.widthAnchor.constraint(equalToConstant: 16), // Same width for all workspaces
                labelContainer.heightAnchor.constraint(equalTo: workspaceContainer.heightAnchor)
            ])
            
            workspaceContainer.addArrangedSubview(labelContainer)
            
            // Create stack view for this group's icons with proper constraints
            let groupStack = NSStackView(frame: .zero)
            groupStack.orientation = .horizontal
            groupStack.spacing = 4  // [5] Space between individual icons in a group
            groupStack.distribution = .fillEqually
            groupStack.alignment = .centerY
            
            // Ensure minimum size even when empty
            groupStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
            groupStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            
            // Add minimum width and height constraints for empty workspaces
            if group.windows.isEmpty {
                NSLayoutConstraint.activate([
                    groupStack.widthAnchor.constraint(greaterThanOrEqualToConstant: currentIconSize * 0.5),
                    groupStack.heightAnchor.constraint(equalToConstant: currentIconSize)
                ])
            }
            
            workspaceContainer.addArrangedSubview(groupStack)
            
            // Ensure consistent height for the workspace container
            NSLayoutConstraint.activate([
                workspaceContainer.heightAnchor.constraint(equalToConstant: currentIconSize + 12) // 6px padding top and bottom
            ])
            
            // Add apps for this group
            for window in group.windows {
                if let icon = getIconForWindow(window) {
                    let imageView = ClickableImageView(frame: NSRect(x: 0, y: 0, width: currentIconSize, height: currentIconSize))
                    imageView.image = icon
                    imageView.imageScaling = .scaleProportionallyUpOrDown
                    imageView.wantsLayer = true
                    imageView.layer?.cornerRadius = currentIconSize * 0.1875 // Scales corner radius with size (6px at 32px)
                    imageView.layer?.masksToBounds = true
                    
                    // Store the window ID
                    imageView.tag = window.windowId
                    
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
                    
                    // Store workspace info and app name for click handling
                    imageView.workspace = group.workspace
                    imageView.appName = window.appName
                    imageView.updateTooltipText()  // Update tooltip text immediately
                    
                    // Add click handler
                    imageView.onClick = { [weak self] imageView in
                        guard let workspace = imageView.workspace else { return }
                        
                        // First log the target workspace
                        print("\n=== Click Info ===")
                        print("Target workspace: \(workspace)")
                        print("Window ID to activate: \(imageView.tag)")
                        print("App Name: \(imageView.appName ?? "unknown")")
                        
                        // Switch to workspace first
                        self?.runAerospaceCommand(args: ["workspace", workspace])
                        
                        // After a brief delay, focus the window
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            print("Focusing window \(imageView.tag)")
                            self?.runAerospaceCommand(args: ["focus", "--window-id", "\(imageView.tag)"])
                        }
                        
                        print("==================\n")
                    }
                    
                    groupStack.addArrangedSubview(imageView)
                }
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
        
        print("\n=== Applying Layout ===")
        print("Stack Natural Size - Width: \(stackSize.width), Height: \(stackSize.height)")
        print("Total Size (with padding) - Width: \(totalWidth), Height: \(totalHeight)")
        
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
            
            print("\n=== Window Position ===")
            print("Dock Position: \(currentDockPosition)")
            print("X Position: \(xPosition)")
            print("Screen Visible Frame - X: \(mainScreen.visibleFrame.minX), Y: \(mainScreen.visibleFrame.minY)")
            print("Screen Size - Width: \(mainScreen.visibleFrame.width), Height: \(mainScreen.visibleFrame.height)")
            
            let yPosition = mainScreen.visibleFrame.minY
            let newFrame = NSRect(x: xPosition, y: yPosition, width: totalWidth, height: totalHeight)
            
            print("Final Window Frame - X: \(xPosition), Y: \(yPosition), Width: \(totalWidth), Height: \(totalHeight)")
            print("===================\n")
            
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
        iconCache.removeAll()
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
                
                // Suppress version mismatch warnings and "No window is focused" errors
                if let errorOutput = String(data: errorData, encoding: .utf8), !errorOutput.isEmpty {
                    if !errorOutput.contains("versions don't match") && !errorOutput.contains("No window is focused") {
                        print("Error: \(errorOutput)")
                    }
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
        let windowId: Int
        let pid: Int
        let title: String
        let appName: String
        
        init(line: String) {
            // Parse line like: "12391 | Cursor | Git: Changes (2 files) — RAD"
            let parts = line.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            print("Parsing window info from line: \(line)")
            print("Parts: \(parts)")
            
            // First part is the window ID
            self.windowId = Int(parts[0]) ?? 0
            print("Window ID: \(self.windowId)")
            
            // Second part is the app name
            self.title = parts[1]
            
            // Third part (if exists) is the window title
            self.appName = parts.count > 2 ? parts[2] : parts[1]
            
            // Store window ID as pid too
            self.pid = self.windowId
        }
        
        var appIcon: NSImage? {
            if let app = NSRunningApplication(processIdentifier: pid_t(pid)) {
                return app.icon
            }
            return nil
        }
    }

    struct WorkspaceGroup: Identifiable {
        let workspace: String
        let windows: [WindowInfo]
        
        var id: String { workspace }  // Conform to Identifiable using workspace as the id
    }

    private func getSortedWorkspaces() -> [String] {
        if let cached = sortedWorkspaces {
            return cached
        }
        
        // Get all workspaces first
        guard let workspaceOutput = runAerospaceCommand(args: ["list-workspaces", "--all"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
            return []
        }
        
        // Parse and sort workspaces
        var workspaces = workspaceOutput.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        
        // Sort workspaces (0-9, then alphabetical)
        workspaces.sort { a, b in
            let aNum = Int(a)
            let bNum = Int(b)
            
            switch (aNum, bNum) {
            case (nil, nil): return a < b
            case (nil, _): return false
            case (_, nil): return true
            case (let a?, let b?):
                let aVal = a == 0 ? 10 : a
                let bVal = b == 0 ? 10 : b
                return aVal < bVal
            }
        }
        
        sortedWorkspaces = workspaces
        return workspaces
    }

    private func getWorkspaceGroups() -> [WorkspaceGroup] {
        // Return cached groups if available
        if let cached = cachedWorkspaceGroups {
            return cached
        }
        
        let workspaces = getSortedWorkspaces()
        
        // Create workspace groups for all workspaces, even empty ones
        let groups = workspaces.map { workspace in
            let windows = getWindowsForWorkspace(workspace)
            let windowInfos = windows.map { window in
                let info = WindowInfo(line: window)
                print("Created WindowInfo - ID: \(info.windowId), App: \(info.title), Title: \(info.appName)")
                return info
            }
            return WorkspaceGroup(workspace: workspace, windows: windowInfos)
        }
        
        // Cache the result
        cachedWorkspaceGroups = groups
        return groups
    }
    
    private func invalidateWindowCache() {
        print("Invalidating window cache")
        cachedWorkspaceGroups = nil
        iconCache.removeAll()
        iconCacheTimestamp = nil
    }
    
    private func handleWorkspaceChange(_ source: UpdateSource) {
        if source == .windowMove {
            invalidateWindowCache()
        }
        updateRunningApps()
    }
    
    private func getWindowsForWorkspace(_ workspace: String) -> [String] {
        guard let windowOutput = runAerospaceCommand(args: ["list-windows", "--workspace", workspace]) else {
            return []
        }
        
        let windows = windowOutput.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        
        print("Raw windows in workspace \(workspace):")
        windows.forEach { print($0) }
        
        return windows
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
        // Hide tooltip IMMEDIATELY before anything else
        DockTooltipWindow.getSharedWindow().alphaValue = 0.0
        
        // Switch workspace in background
        updateQueue.async {
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/opt/homebrew/bin/aerospace")
            task.arguments = ["workspace", workspace]
            
            do {
                try task.run()
                task.waitUntilExit()
                
                // Update UI after switch
                DispatchQueue.main.async {
                    self.debouncedUpdateRunningApps(source: .spaceChange)
                }
            } catch {
                print("Error switching workspace: \(error)")
            }
        }
    }
    
    private func updateWorkspaceIndicators(focusedWorkspace: String? = nil) {
        // Use provided workspace or get current one
        let workspace: String
        if let provided = focusedWorkspace {
            workspace = provided
        } else if let current = runAerospaceCommand(args: ["list-workspaces", "--focused"])?
            .trimmingCharacters(in: .whitespacesAndNewlines) {
            workspace = current
        } else {
            return
        }
        
        // Only update if we have a main stack view
        guard let mainStackView = self.mainStackView else { return }
        
        // Cache appearance check
        let isDarkMode = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        
        // Prepare colors and fonts
        let activeOpacity: CGFloat = isDarkMode ? 0.4 : 0.8
        let inactiveOpacity: CGFloat = isDarkMode ? 0.1 : 0.4
        let activeColor = NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: activeOpacity).cgColor
        let inactiveColor = NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: inactiveOpacity).cgColor
        
        CATransaction.begin()
        CATransaction.setDisableActions(true)  // Disable implicit animations
        
        // Direct layer manipulation
        mainStackView.arrangedSubviews.forEach { view in
            guard let container = view.subviews.first?.subviews.first as? NSStackView,
                  let label = container.arrangedSubviews.first as? NSTextField else { return }
            
            let isActive = label.stringValue == workspace
            view.layer?.backgroundColor = isActive ? activeColor : inactiveColor
            
            // Update label without animation
            NSAnimationContext.beginGrouping()
            NSAnimationContext.current.duration = 0
            label.textColor = isActive ? .labelColor : .tertiaryLabelColor
            label.font = NSFont.monospacedSystemFont(
                ofSize: self.currentIconSize * 0.4375,
                weight: isActive ? .bold : .medium
            )
            NSAnimationContext.endGrouping()
        }
        
        CATransaction.commit()
    }
    
    // Fast indicator-only update for empty space switches
    private func updateWorkspaceIndicatorsOnly(workspace: String) {
        guard let mainStackView = self.mainStackView else { return }
        
        let isDarkMode = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let activeOpacity: CGFloat = isDarkMode ? 0.4 : 0.8
        let inactiveOpacity: CGFloat = isDarkMode ? 0.1 : 0.4
        let activeColor = NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: activeOpacity).cgColor
        let inactiveColor = NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: inactiveOpacity).cgColor
        
        // Update indicators immediately without any delays
        mainStackView.arrangedSubviews.forEach { view in
            guard let container = view.subviews.first?.subviews.first as? NSStackView,
                  let label = container.arrangedSubviews.first as? NSTextField else { return }
            
            let isActive = label.stringValue == workspace
            view.layer?.backgroundColor = isActive ? activeColor : inactiveColor
            label.textColor = isActive ? .labelColor : .tertiaryLabelColor
            label.font = NSFont.monospacedSystemFont(
                ofSize: self.currentIconSize * 0.4375,
                weight: isActive ? .bold : .medium
            )
        }
    }
    
    private func getIconForWindow(_ window: WindowInfo) -> NSImage? {
        // Check cache first
        if let cachedIcon = iconCache[window.windowId],
           let timestamp = iconCacheTimestamp,
           Date().timeIntervalSince(timestamp) < iconCacheLifetime {
            return cachedIcon
        }
        
        // If cache is expired or missing, get fresh icon
        var appIcon: NSImage?
        
        // Try to find the app by name first
        let appName = window.title  // The app name is in the title field now
        
        // Special case for Calendar/iCal
        if appName.lowercased().contains("calendar") {
            let calendarPaths = [
                "/System/Applications/Calendar.app",
                "/Applications/Calendar.app"
            ]
            
            for path in calendarPaths {
                if FileManager.default.fileExists(atPath: path) {
                    appIcon = NSWorkspace.shared.icon(forFile: path)
                    if appIcon != nil {
                        print("Using static Calendar icon")
                        break
                    }
                }
            }
            
            if appIcon == nil {
                if let calendarApp = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.iCal") {
                    appIcon = NSWorkspace.shared.icon(forFile: calendarApp.path)
                }
            }
        }
        
        // If no icon yet, try to find the app by name
        if appIcon == nil {
            if let app = NSWorkspace.shared.runningApplications.first(where: { 
                $0.localizedName?.lowercased() == appName.lowercased() ||
                $0.bundleIdentifier?.lowercased().contains(appName.lowercased()) == true
            }) {
                // Try multiple methods to get the icon
                if let icon = app.icon {
                    appIcon = icon
                } else if let bundleID = app.bundleIdentifier,
                          let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                    appIcon = NSWorkspace.shared.icon(forFile: appURL.path)
                }
            }
        }
        
        // If still no icon, try to find the app by common names
        if appIcon == nil {
            let commonApps = [
                ("firefox", "org.mozilla.firefox"),
                ("safari", "com.apple.Safari"),
                ("chrome", "com.google.Chrome"),
                ("terminal", "com.apple.Terminal"),
                ("iterm", "com.googlecode.iterm2"),
                ("notes", "com.apple.Notes"),
                ("mail", "com.apple.mail"),
                ("xcode", "com.apple.dt.Xcode"),
                ("cursor", "com.xata.cursor"),
                ("simulator", "com.apple.iphonesimulator"),
                ("emacs", "org.gnu.Emacs"),
                ("omnifocus", "com.omnigroup.OmniFocus3")
            ]
            
            for (name, bundleId) in commonApps {
                if appName.lowercased().contains(name) {
                    if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) {
                        appIcon = NSWorkspace.shared.icon(forFile: appURL.path)
                        if appIcon != nil { break }
                    }
                }
            }
        }
        
        // Update cache if we got an icon
        if let icon = appIcon {
            iconCache[window.windowId] = icon
            iconCacheTimestamp = Date()
        }
        
        return appIcon ?? NSWorkspace.shared.icon(forFileType: "public.app")
    }
    
    // Add method to check for window changes
    private var lastWindowState: String = ""
    
    private func checkForWindowChanges() {
        // Get current window state with more detail
        var currentState = ""
        for workspace in getSortedWorkspaces() {
            if let windows = runAerospaceCommand(args: ["list-windows", "--workspace", workspace]) {
                // Include the workspace and window details for more granular change detection
                currentState += "\(workspace):\(windows.hash)\n"
            }
        }
        
        // Also include the currently focused window to catch focus changes
        if let focusedWindow = runAerospaceCommand(args: ["list-windows", "--focused"]) {
            currentState += "focused:\(focusedWindow.hash)\n"
        }
        
        // If state changed, update the UI
        if currentState != lastWindowState {
            print("Window state changed, updating UI")
            lastWindowState = currentState
            invalidateWindowCache()
            debouncedUpdateRunningApps(source: .windowMove)
        }
    }
}

// Add this class at the top level
class ClickableImageView: NSImageView {
    var workspace: String?
    var appName: String?
    private var tooltipWindow: DockTooltipWindow {
        return DockTooltipWindow.getSharedWindow()
    }
    var onClick: ((ClickableImageView) -> Void)?
    var onRightClick: ((ClickableImageView) -> Void)?
    
    static func hideTooltip() {
        // Hide tooltip without animation
        let tooltipWindow = DockTooltipWindow.getSharedWindow()
        tooltipWindow.alphaValue = 0.0
    }
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    // Update tooltip text when app name or workspace is set
    func updateTooltipText() {
        tooltipWindow.updateText("\(appName ?? "Unknown")\nWorkspace \(workspace ?? "Unknown")")
    }
    
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        
        // Update and position before showing
        updateTooltipText()
        positionTooltip()
        
        // Ensure window is in front and visible
        tooltipWindow.orderFront(nil)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            tooltipWindow.animator().alphaValue = 1.0
        }
    }
    
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            tooltipWindow.animator().alphaValue = 0.0
        }
    }
    
    private func positionTooltip() {
        guard let window = self.window else { return }
        
        // Get the screen that contains the icon
        guard let screen = window.screen ?? NSScreen.main else { return }
        
        // Convert our frame to screen coordinates
        let screenFrame = window.convertToScreen(convert(bounds, to: nil))
        
        // Calculate tooltip position
        let tooltipSize = tooltipWindow.frame.size
        let tooltipX = screenFrame.midX - (tooltipSize.width / 2)
        let tooltipY = screenFrame.maxY + 20 // Increased gap to move tooltip up
        
        // Ensure tooltip stays within screen bounds
        let finalX = max(screen.visibleFrame.minX + 5,
                        min(tooltipX,
                            screen.visibleFrame.maxX - tooltipSize.width - 5))
        
        let finalY = min(tooltipY + tooltipSize.height,
                        screen.visibleFrame.maxY - 5)
        
        tooltipWindow.setFrameTopLeftPoint(NSPoint(x: finalX, y: finalY))
    }
    
    deinit {
        // No need to close the window since it's shared
    }
    
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
    
    // Required for mouse tracking
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        
        // Remove existing tracking areas
        trackingAreas.forEach { removeTrackingArea($0) }
        
        // Add new tracking area
        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .activeAlways]
        let trackingArea = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(trackingArea)
    }
    
    private func createNewWindow() {
        // Check if we have accessibility permissions first
        if !AXIsProcessTrusted() {
            // Show alert explaining why we need permissions
            let alert = NSAlert()
            alert.messageText = "Accessibility Permissions Required"
            alert.informativeText = "To create new windows, RunningAppDisplay needs accessibility permissions. Please enable them in System Settings > Privacy & Security > Accessibility."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Cancel")
            
            if alert.runModal() == .alertFirstButtonReturn {
                // Open System Settings directly to the Accessibility section
                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                    NSWorkspace.shared.open(url)
                }
            }
            return
        }

        // If we have permissions, proceed with creating the window
        guard let eventSource = CGEventSource(stateID: .hidSystemState) else { return }
        
        // Simple Command+N
        if let keyDownEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: 45, keyDown: true) {
            keyDownEvent.flags = .maskCommand
            
            if let keyUpEvent = CGEvent(keyboardEventSource: eventSource, virtualKey: 45, keyDown: false) {
                keyDownEvent.post(tap: .cghidEventTap)
                keyUpEvent.post(tap: .cghidEventTap)
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
        case .small: return 32
        case .medium: return 40
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

