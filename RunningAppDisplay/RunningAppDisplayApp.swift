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
    var recentAppOrder: [String] = []  // Track app usage order by bundle ID
    
    static func main() {
        let app = NSApplication.shared
        let delegate = RunningAppDisplayApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Setup workspace notifications
        let workspace = NSWorkspace.shared
        workspaceNotificationObserver = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: nil) { [weak self] notification in
                if let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                   let bundleID = app.bundleIdentifier {
                    self?.updateRecentApps(bundleID)
                }
        }
        
        // Create floating window for running apps with larger height
        runningAppsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 32, height: 32),  // Increased height to accommodate larger icons
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        // Update window setup
        runningAppsWindow.level = .statusBar
        runningAppsWindow.backgroundColor = .clear
        runningAppsWindow.isOpaque = false
        runningAppsWindow.hasShadow = false
        runningAppsWindow.ignoresMouseEvents = false  // This is important
        runningAppsWindow.acceptsMouseMovedEvents = true  // This too
        runningAppsWindow.collectionBehavior = [.canJoinAllSpaces, .transient]
        
        // Initialize with current running apps
        if let frontApp = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
            updateRecentApps(frontApp)
        }
        updateRunningApps()
        
        // Add appearance change observer
        appearanceObserver = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            self?.updateRunningApps()  // Refresh UI when appearance changes
        }
    }
    
    func updateRecentApps(_ bundleID: String) {
        // Remove if exists and add to front
        recentAppOrder.removeAll { $0 == bundleID }
        recentAppOrder.insert(bundleID, at: 0)
        updateRunningApps()
    }
    
    func updateRunningApps() {
        let workspace = NSWorkspace.shared
        var runningApps = workspace.runningApplications.filter { 
            $0.activationPolicy == .regular && 
            $0.bundleIdentifier != Bundle.main.bundleIdentifier  // Filter out RAD app
        }
        
        // Sort apps based on recent usage
        runningApps.sort { app1, app2 in
            guard let id1 = app1.bundleIdentifier,
                  let id2 = app2.bundleIdentifier else { return false }
            
            let index1 = recentAppOrder.firstIndex(of: id1) ?? Int.max
            let index2 = recentAppOrder.firstIndex(of: id2) ?? Int.max
            return index1 < index2
        }
        
        let iconSize = NSSize(width: 40, height: 40)  // Standard macOS icon size
        let spacing: CGFloat = 8
        let horizontalPadding: CGFloat = 8
        let verticalPadding: CGFloat = 4  // Reduced from 12 to 4
        let shadowPadding: CGFloat = 15
        
        // Calculate total width and height including shadow space
        let contentWidth = CGFloat(runningApps.count) * (iconSize.width + spacing) - spacing + (horizontalPadding * 2)
        let contentHeight: CGFloat = iconSize.height + (verticalPadding * 2)
        let totalWidth = contentWidth + (shadowPadding * 2)
        let totalHeight = contentHeight + (shadowPadding * 2)
        
        // Create container view with extra space for shadow
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: totalWidth, height: totalHeight))
        
        // Create background view positioned to allow shadow space
        let backgroundView = NSView(frame: NSRect(x: shadowPadding, y: shadowPadding, 
                                                width: contentWidth, height: contentHeight))
        backgroundView.wantsLayer = true
        
        // Create a custom corner mask that ONLY rounds top-left corner
        let maskedCorners: CACornerMask = [.layerMinXMaxYCorner]  // Only top-left corner
        backgroundView.layer?.maskedCorners = maskedCorners
        backgroundView.layer?.cornerRadius = 8
        
        // Set background color based on appearance
        let isDarkMode = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if isDarkMode {
            backgroundView.layer?.backgroundColor = NSColor(white: 0.2, alpha: 0.95).cgColor
        } else {
            backgroundView.layer?.backgroundColor = NSColor(white: 0.95, alpha: 0.95).cgColor
        }
        
        // Add shadow with more subtle menubar-like appearance
        backgroundView.layer?.shadowColor = NSColor.black.cgColor
        backgroundView.layer?.shadowOpacity = 0.4
        backgroundView.layer?.shadowOffset = NSSize(width: 2, height: -8)
        backgroundView.layer?.shadowRadius = 8
        backgroundView.layer?.masksToBounds = false
        
        // Add the actual Dock-style border with correct colors per mode
        if isDarkMode {
            backgroundView.layer?.borderColor = NSColor(red: 65/255, green: 65/255, blue: 65/255, alpha: 1.0).cgColor  // #414141
        } else {
            backgroundView.layer?.borderColor = NSColor(red: 229/255, green: 229/255, blue: 229/255, alpha: 1.0).cgColor  // #e5e5e5
        }
        backgroundView.layer?.borderWidth = 1
        
        // Create stack view
        let stackView = NSStackView(frame: NSRect(x: horizontalPadding, y: verticalPadding, 
                                                width: contentWidth - (horizontalPadding * 2), 
                                                height: iconSize.height))
        stackView.orientation = .horizontal
        stackView.spacing = spacing
        
        // Position window - SIMPLE, BOTTOM RIGHT, FLUSH
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let shadowOffset: CGFloat = 15  // Back to a simple, single offset
        let xPosition = screen.visibleFrame.maxX - totalWidth + shadowOffset  // Push right
        let yPosition = screen.visibleFrame.minY - shadowOffset  // Push down
        
        runningAppsWindow.setFrame(NSRect(x: xPosition, y: yPosition, width: totalWidth, height: totalHeight), display: true)
        
        // Set up view hierarchy
        backgroundView.addSubview(stackView)
        containerView.addSubview(backgroundView)
        runningAppsWindow.contentView = containerView
        runningAppsWindow.backgroundColor = .clear
        runningAppsWindow.isOpaque = false
        // runningApps.hasShadow = false
        
        // Add app icons
        for app in runningApps {
            if let appIcon = app.icon {
                // First create the outer container with fixed size
                let containerView = NSView(frame: NSRect(x: 0, y: 0, width: iconSize.width, height: iconSize.height))
                containerView.wantsLayer = true
//                containerView.layer?.borderWidth = 1
//                containerView.layer?.borderColor = NSColor.red.cgColor
                
                // Create image view that will be constrained inside container
                let imageView = ClickableImageView()
                imageView.wantsLayer = true
                imageView.layer?.masksToBounds = true
                imageView.translatesAutoresizingMaskIntoConstraints = false
                
                // Add to container
                containerView.addSubview(imageView)
                
                // Constrain image view to container edges
                NSLayoutConstraint.activate([
                    imageView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
                    imageView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
                    imageView.topAnchor.constraint(equalTo: containerView.topAnchor),
                    imageView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
                ])
                
                // Set the image
                appIcon.size = iconSize
                imageView.image = appIcon
                imageView.imageScaling = .scaleProportionallyDown
                
                // Add container to stack
                stackView.addArrangedSubview(containerView)
                
                // Store the app reference for click handling
                imageView.tag = Int(app.processIdentifier)
            }
        }
        
        runningAppsWindow.orderFront(nil)
    }
    
    deinit {
        if let observer = appearanceObserver as? NSKeyValueObservation {
            observer.invalidate()
        }
    }
}

// Add this class at the top level
class ClickableImageView: NSImageView {
    private var popover: NSPopover?
    private var isMouseInside = false
    private var lastMouseMovement: Date?
    private var tooltipTimer: Timer?
    
    override var acceptsFirstResponder: Bool { return true }
    
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
        lastMouseMovement = Date()
        tooltipTimer?.invalidate()
        
        tooltipTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
            self?.showTooltipIfNeeded()
        }
    }
    
    private func showTooltipIfNeeded() {
        guard isMouseInside,
              let app = NSRunningApplication(processIdentifier: pid_t(self.tag)) else { return }
        
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
        lastMouseMovement = Date()
        
        tooltipTimer?.invalidate()
        tooltipTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: false) { [weak self] _ in
            self?.showTooltipIfNeeded()
        }
    }
    
    override func mouseExited(with event: NSEvent) {
        isMouseInside = false
        tooltipTimer?.invalidate()
        tooltipTimer = nil
        popover?.close()
        popover = nil
    }
    
    override func mouseDown(with event: NSEvent) {
        tooltipTimer?.invalidate()
        if let app = NSRunningApplication(processIdentifier: pid_t(self.tag)) {
            popover?.close()
            _ = app.activate(options: [.activateIgnoringOtherApps])
        }
    }
    
    override func rightMouseDown(with event: NSEvent) {
        let pid = pid_t(self.tag)
        kill(pid, SIGTERM)  // Try graceful termination first
        
        // If app doesn't quit within 2 seconds, force quit
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            kill(pid, SIGKILL)
        }
    }
}
