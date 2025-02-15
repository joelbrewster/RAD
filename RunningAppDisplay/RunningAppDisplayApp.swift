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
    var currentIconSize: CGFloat = 48  // Add this new property
    
    static func main() {
        let app = NSApplication.shared
        let delegate = RunningAppDisplayApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        let workspace = NSWorkspace.shared
        
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
        runningAppsWindow.hasShadow = true    // Enable shadow for dock-like appearance
        runningAppsWindow.ignoresMouseEvents = false
        runningAppsWindow.acceptsMouseMovedEvents = true
        runningAppsWindow.collectionBehavior = [.canJoinAllSpaces, .transient]
        runningAppsWindow.alphaValue = 1.0  // Keep window fully opaque
        
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
        updateRunningApps()
        
        // Add appearance change observer
        appearanceObserver = NSApp.observe(\.effectiveAppearance) { [weak self] _, _ in
            self?.updateRunningApps()  // Refresh UI when appearance changes
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
        updateRunningApps()
    }
    
    func updateRunningApps() {
        let workspace = NSWorkspace.shared
        var runningApps = workspace.runningApplications.filter { 
            $0.activationPolicy == .regular && 
            $0.bundleIdentifier != Bundle.main.bundleIdentifier
        }
        
        // FORCE THE SORT ORDER - HIGHER INDEX = RIGHT SIDE
        runningApps.sort { app1, app2 in
            guard let id1 = app1.bundleIdentifier,
                  let id2 = app2.bundleIdentifier else { return false }
            
            let index1 = recentAppOrder.firstIndex(of: id1) ?? Int.max
            let index2 = recentAppOrder.firstIndex(of: id2) ?? Int.max
            
            return index1 > index2  // This makes higher indexes go RIGHT
        }
        
        let iconSize = NSSize(width: currentIconSize, height: currentIconSize)  // Use dynamic size
        let spacing: CGFloat = 6
        let horizontalPadding: CGFloat = 6
        let verticalPadding: CGFloat = 6
        let shadowPadding: CGFloat = 15
        
        // Add resize handle height
        let resizeHandleHeight: CGFloat = 8
        
        // Adjust content height to include resize handle
        let contentWidth = CGFloat(runningApps.count) * (iconSize.width + spacing) - spacing + (horizontalPadding * 2)
        let contentHeight: CGFloat = iconSize.height + (verticalPadding * 2) + resizeHandleHeight
        let totalWidth = contentWidth + (shadowPadding * 2)
        let totalHeight = contentHeight + (shadowPadding * 2)
        
        // Create container view with extra space for shadow
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: totalWidth, height: totalHeight))
        
        // Create and add resize handle
        let resizeHandle = ResizeHandleView(frame: NSRect(x: shadowPadding, 
                                                        y: totalHeight - resizeHandleHeight - shadowPadding,
                                                        width: contentWidth,
                                                        height: resizeHandleHeight))
        resizeHandle.delegate = self
        containerView.addSubview(resizeHandle)
        
        // Adjust background view position to account for resize handle
        let backgroundView = NSView(frame: NSRect(x: shadowPadding, 
                                                y: shadowPadding,
                                                width: contentWidth, 
                                                height: contentHeight - resizeHandleHeight))
        backgroundView.wantsLayer = true
        
        // Create visual effect view for blur
        let blurView = NSVisualEffectView(frame: backgroundView.bounds)
        blurView.blendingMode = .withinWindow
        blurView.state = .active
        blurView.material = .hudWindow  // Changed to hudWindow for better color match
        blurView.wantsLayer = true
        blurView.isEmphasized = true
        
        // Match system appearance
        blurView.appearance = NSApp.effectiveAppearance
        
        // More transparent border
        blurView.layer?.borderWidth = 0.5
        blurView.layer?.borderColor = NSColor.white.withAlphaComponent(0.1).cgColor
        
        // Simple top left corner radius
        blurView.layer?.cornerRadius = 12
        blurView.layer?.maskedCorners = [.layerMinXMaxYCorner]  // TOP LEFT
        
        // Adjust transparency
        blurView.alphaValue = 0.7  // More transparent to better match dock
        
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
                    let finalIcon: NSImage
                    
                    // Check if this is the active app (will be at the FIRST position due to reversed sort)
                    if app == runningApps.first {
                        finalIcon = NSImage(cgImage: cgImage, size: iconSize)
                    } else {
                        // Apply filter to non-active apps
                        if let filter = CIFilter(name: "CIColorControls") {
                            filter.setValue(ciImage, forKey: kCIInputImageKey)
                            filter.setValue(0, forKey: kCIInputSaturationKey) // Remove color
                            
                            // Adjust brightness and contrast based on appearance
                            let isDarkMode = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                            if isDarkMode {
                                filter.setValue(1.4, forKey: kCIInputContrastKey)   // Increase contrast in dark mode
                                filter.setValue(0.2, forKey: kCIInputBrightnessKey) // Lighter in dark mode
                            } else {
                                filter.setValue(1.2, forKey: kCIInputContrastKey)   // Keep original contrast in light mode
                                filter.setValue(0.1, forKey: kCIInputBrightnessKey) // Very slightly darker in light mode
                            }
                            
                            if let outputImage = filter.outputImage,
                               let context = CIContext(options: nil).createCGImage(outputImage, from: outputImage.extent) {
                                finalIcon = NSImage(cgImage: context, size: iconSize)
                            } else {
                                finalIcon = NSImage(cgImage: cgImage, size: iconSize)
                            }
                        } else {
                            finalIcon = NSImage(cgImage: cgImage, size: iconSize)
                        }
                    }
                    
                    // Create fixed-size container
                    let containerView = NSView(frame: NSRect(x: 0, y: 0, width: iconSize.width, height: iconSize.height))
                    containerView.wantsLayer = true
                    
                    // Configure image view to fit within container
                    let imageView = ClickableImageView(frame: containerView.bounds)
                    imageView.imageScaling = .scaleProportionallyDown
                    imageView.image = finalIcon
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
        
        // Recolor the icon if it's not the active app
        if let app = NSRunningApplication(processIdentifier: pid_t(self.tag)),
           app != NSWorkspace.shared.frontmostApplication,
           let appIcon = app.icon {
            appIcon.size = bounds.size
            DispatchQueue.main.async {
                self.image = appIcon  // Just use the original icon, no filter
            }
        }

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
        
        // Restore the desaturated state if it's not the active app
        if let app = NSRunningApplication(processIdentifier: pid_t(self.tag)),
           app != NSWorkspace.shared.frontmostApplication,
           let cgImage = image?.cgImage(forProposedRect: nil, context: nil, hints: nil) {
            let ciImage = CIImage(cgImage: cgImage)
            if let filter = CIFilter(name: "CIColorControls") {
                filter.setValue(ciImage, forKey: kCIInputImageKey)
                filter.setValue(0, forKey: kCIInputSaturationKey) // Remove color again
                
                let isDarkMode = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                if isDarkMode {
                    filter.setValue(1.4, forKey: kCIInputContrastKey)
                    filter.setValue(0.2, forKey: kCIInputBrightnessKey)
                } else {
                    filter.setValue(1.2, forKey: kCIInputContrastKey)
                    filter.setValue(0.1, forKey: kCIInputBrightnessKey)
                }
                
                if let outputImage = filter.outputImage,
                   let context = CIContext(options: nil).createCGImage(outputImage, from: outputImage.extent) {
                    self.image = NSImage(cgImage: context, size: self.bounds.size)
                }
            }
        }
    }
    
    override func mouseDown(with event: NSEvent) {
        guard let app = NSRunningApplication(processIdentifier: pid_t(self.tag)),
              let bundleID = app.bundleIdentifier,
              let appDelegate = NSApplication.shared.delegate as? RunningAppDisplayApp else { return }
        
        print("Left click - Before order: \(appDelegate.recentAppOrder)")
        
        // Activate the app first
        _ = app.activate(options: [.activateIgnoringOtherApps])
        
        // Force active app to far left by moving all other apps right
        let currentApps = appDelegate.recentAppOrder.filter { $0 != bundleID }
        appDelegate.recentAppOrder = [bundleID] + currentApps
        
        print("Left click - After order: \(appDelegate.recentAppOrder)")
        
        // Force immediate UI update
        DispatchQueue.main.async {
            appDelegate.updateRunningApps()
        }
    }
    
    override func rightMouseDown(with event: NSEvent) {
        guard let app = NSRunningApplication(processIdentifier: pid_t(self.tag)),
              let bundleID = app.bundleIdentifier,
              let appDelegate = NSApplication.shared.delegate as? RunningAppDisplayApp else { return }
        
        print("Right click - Before order: \(appDelegate.recentAppOrder)")
        
        // Hide the app
        _ = app.hide()
        
        // FORCE IT TO THE RIGHT - PERIOD.
        appDelegate.recentAppOrder.removeAll { $0 == bundleID }
        appDelegate.recentAppOrder.insert(bundleID, at: 0)  // This puts it far right because of reversed sort
        
        print("Right click - After order: \(appDelegate.recentAppOrder)")
        
        // FORCE UPDATE NOW
        appDelegate.updateRunningApps()
        DispatchQueue.main.async {
            appDelegate.updateRunningApps()  // Double-tap the update to make sure
        }
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
        let minIconSize: CGFloat = 24
        
        let clampedSize = min(max(newSize, minIconSize), maxIconSize)
        
        print("Resize - Raw New Size: \(newSize), Clamped Size: \(clampedSize), Current Size: \(currentIconSize), Max Size: \(maxIconSize)")
        
        if abs(currentIconSize - clampedSize) > 0.5 {
            currentIconSize = clampedSize
            updateRunningApps()
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
        let deltaY = currentY - lastY
        
        // Reduced threshold for more sensitive movement
        if abs(deltaY) > 3 {  // Changed from 10 to 3
            lastY = currentY
            
            if let appDelegate = NSApplication.shared.delegate as? RunningAppDisplayApp {
                // Increase size when moving up, decrease when moving down
                let newSize = appDelegate.currentIconSize + (deltaY > 0 ? sizeIncrement : -sizeIncrement)
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

