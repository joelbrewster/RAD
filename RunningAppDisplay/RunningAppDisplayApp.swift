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
        
        terminationObserver = workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: nil) { [weak self] notification in
                self?.updateRunningApps()
        }
        
        // Create floating window for running apps with larger height
        runningAppsWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 0, height: 0),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        // Update window setup
        runningAppsWindow.level = .statusBar
        runningAppsWindow.backgroundColor = .clear
        runningAppsWindow.isOpaque = false
        runningAppsWindow.hasShadow = false
        runningAppsWindow.ignoresMouseEvents = false
        runningAppsWindow.acceptsMouseMovedEvents = true
        runningAppsWindow.collectionBehavior = [.canJoinAllSpaces, .transient]
        runningAppsWindow.alphaValue = 1.0  // Keep window fully opaque
        
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
        
//        let iconSize = NSSize(width: 19, height: 19)
        let iconSize = NSSize(width: 48, height: 48)
        let spacing: CGFloat = 10
        let horizontalPadding: CGFloat = 6
        let verticalPadding: CGFloat = 6
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
        
        // Create visual effect view for blur
        let blurView = NSVisualEffectView(frame: backgroundView.bounds)
        blurView.blendingMode = .withinWindow
        blurView.state = .active
        blurView.material = .titlebar
        blurView.wantsLayer = true
        blurView.isEmphasized = true
        blurView.appearance = NSAppearance(named: .darkAqua)  // Force dark appearance
        
        // Adjust corner radius to match system UI
        blurView.layer?.cornerRadius = 16
        blurView.layer?.maskedCorners = [.layerMinXMaxYCorner]
        
        // Add blur view to background
        backgroundView.addSubview(blurView)
        
        // Remove border completely
        backgroundView.layer?.borderWidth = 0
        
        // Create stack view with proper sizing and distribution
        let stackView = NSStackView(frame: NSRect(x: horizontalPadding, y: verticalPadding, 
                                                width: contentWidth - (horizontalPadding * 2), 
                                                height: iconSize.height))
        stackView.orientation = .horizontal
        stackView.spacing = spacing
        stackView.distribution = .fillEqually  // Changed to fillEqually
        stackView.alignment = .centerY
        stackView.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        
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
        
        // Ensure container view is above blur and fully opaque
        containerView.layer?.zPosition = 1
        containerView.alphaValue = 1.0
        
        // Make sure stack view with icons is fully opaque
        stackView.alphaValue = 1.0
        
        // Add app icons
        for app in runningApps {
            if let appIcon = app.icon {
                appIcon.size = iconSize
                
                if let cgImage = appIcon.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                    let ciImage = CIImage(cgImage: cgImage)
                    
                    if let filter = CIFilter(name: "CIColorControls") {
                        filter.setValue(ciImage, forKey: kCIInputImageKey)
                        // Set saturation so they're not too strong on the screen - disable while I play
                        filter.setValue(1, forKey: kCIInputSaturationKey)
                        
                        if let outputImage = filter.outputImage {
                            let context = CIContext()
                            if let cgOutput = context.createCGImage(outputImage, from: outputImage.extent) {
                                let filteredIcon = NSImage(cgImage: cgOutput, size: iconSize)
                                
                                // Create fixed-size container
                                let containerView = NSView(frame: NSRect(x: 0, y: 0, width: iconSize.width, height: iconSize.height))
                                containerView.wantsLayer = true
                                
                                // Configure image view to fit within container
                                let imageView = ClickableImageView(frame: containerView.bounds)
                                imageView.imageScaling = .scaleProportionallyDown
                                imageView.image = filteredIcon
                                imageView.wantsLayer = true
                                imageView.layer?.masksToBounds = true
                                imageView.tag = Int(app.processIdentifier)
                                
                                // Center image in container
                                containerView.addSubview(imageView)
                                
                                // Add fixed-width constraint to container
                                containerView.widthAnchor.constraint(equalToConstant: iconSize.width).isActive = true
                                
                                stackView.addArrangedSubview(containerView)
                            }
                        }
                    }
                }
            }
        }
        
        runningAppsWindow.orderFront(nil)
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
        guard let app = NSRunningApplication(processIdentifier: pid_t(self.tag)) else { return }
        _ = app.hide()
    }
}
