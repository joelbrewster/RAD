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
    var currentDockPosition: DockPosition = {
        if let savedPosition = UserDefaults.standard.string(forKey: "dockPosition"),
           let position = DockPosition(rawValue: savedPosition) {
            return position
        }
        return .center  // Default to center
    }()
    var currentIconSize: CGFloat = UserDefaults.standard.float(forKey: "iconSize") > 0 ? CGFloat(UserDefaults.standard.float(forKey: "iconSize")) : 48
    
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
        runningAppsWindow.hasShadow = false
        runningAppsWindow.ignoresMouseEvents = false
        runningAppsWindow.acceptsMouseMovedEvents = true
        runningAppsWindow.collectionBehavior = [.canJoinAllSpaces, .stationary, .transient]
        runningAppsWindow.isMovableByWindowBackground = false
        runningAppsWindow.alphaValue = 1.0
        
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
        let shadowPadding: CGFloat = 0  // FORCE ZERO
        
        // Add resize handle height
        let resizeHandleHeight: CGFloat = 8
        
        // Calculate exact sizes with NO extra space
        let contentWidth = CGFloat(runningApps.count) * (iconSize.width + spacing) - spacing + (horizontalPadding * 2)
        let contentHeight: CGFloat = iconSize.height + (verticalPadding * 2) + resizeHandleHeight
        let totalWidth = contentWidth  // NO EXTRA PADDING
        let totalHeight = contentHeight  // NO EXTRA PADDING
        
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
        blurView.blendingMode = .behindWindow
        blurView.state = .active
        blurView.material = .hudWindow  // This matches menubar better
        blurView.alphaValue = 0.8
        blurView.wantsLayer = true
        blurView.isEmphasized = true
        
        // Match system appearance
        blurView.appearance = NSApp.effectiveAppearance

        // Remove ALL border properties first
        blurView.layer?.borderWidth = 0
        blurView.layer?.borderColor = nil

        // Simple top corner radius
        blurView.layer?.cornerRadius = 12
        // First, clear all masked corners
        blurView.layer?.maskedCorners = []
        
        // Then set only the corners we want
        switch currentDockPosition {
        case .left:
            blurView.layer?.maskedCorners = [.layerMaxXMaxYCorner]  // Only TOP RIGHT corner
        case .center:
            blurView.layer?.maskedCorners = [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]  // BOTH top corners
        case .right:
            blurView.layer?.maskedCorners = [.layerMinXMaxYCorner]  // Only TOP LEFT corner
        }

        // Adjust transparency
        blurView.alphaValue = 0.7  // More transparent to better match dock
        
        // Add blur view to background
        backgroundView.addSubview(blurView)
        
        // Create stack view with proper sizing and distribution
        let stackView = NSStackView(frame: NSRect(x: horizontalPadding, y: verticalPadding, 
                                                width: contentWidth - (horizontalPadding * 2), 
                                                height: iconSize.height))
        stackView.orientation = .horizontal
        stackView.spacing = spacing
        stackView.distribution = .fillEqually  // Changed to fillEqually
        stackView.alignment = .centerY
        stackView.edgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        
        // FORCE MAIN SCREEN ONLY - IGNORE ACTIVE SCREEN
        if let mainScreen = NSScreen.screens.first {  // Use first screen instead of .main
            let xPosition: CGFloat = switch currentDockPosition {
            case .left:
                mainScreen.visibleFrame.minX
            case .center:
                (mainScreen.visibleFrame.width - totalWidth) / 2 + mainScreen.visibleFrame.minX
            case .right:
                mainScreen.visibleFrame.maxX - totalWidth
            }
            
            let yPosition = mainScreen.visibleFrame.minY
            runningAppsWindow.setFrame(NSRect(x: xPosition, y: yPosition, width: totalWidth, height: totalHeight), display: true)
        }
        
        // KILL ALL SHADOWS
        runningAppsWindow.hasShadow = false
        containerView.wantsLayer = true
        containerView.layer?.shadowOpacity = 0
        containerView.layer?.shadowRadius = 0
        containerView.layer?.shadowOffset = .zero
        
        // Set up view hierarchy
        backgroundView.addSubview(stackView)
        containerView.addSubview(backgroundView)
        runningAppsWindow.contentView = containerView
        runningAppsWindow.backgroundColor = .clear
        runningAppsWindow.isOpaque = false
        
        // Ensure container view is above blur and fully opaque
        containerView.layer?.zPosition = 1
        containerView.alphaValue = 1.0
        
        // Make sure stack view with icons is fully opaque
        stackView.alphaValue = 1.0
        
        // Add app icons
        for app in runningApps {
            if let appIcon = app.icon {
                appIcon.size = NSSize(width: currentIconSize, height: currentIconSize)
                
                // Only make hidden apps grayscale
                let finalIcon: NSImage
                if app.isHidden {
                    if let cgImage = appIcon.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                        let ciImage = CIImage(cgImage: cgImage)
                        let filter = CIFilter(name: "CIColorMonochrome")!
                        filter.setValue(ciImage, forKey: kCIInputImageKey)
                        filter.setValue(CIColor(red: 0.7, green: 0.7, blue: 0.7), forKey: kCIInputColorKey)
                        filter.setValue(1.0, forKey: kCIInputIntensityKey)
                        
                        if let output = filter.outputImage {
                            let context = CIContext(options: nil)
                            if let cgOutput = context.createCGImage(output, from: output.extent) {
                                finalIcon = NSImage(cgImage: cgOutput, size: NSSize(width: currentIconSize, height: currentIconSize))
                            } else {
                                finalIcon = appIcon
                            }
                        } else {
                            finalIcon = appIcon
                        }
                    } else {
                        finalIcon = appIcon
                    }
                } else {
                    finalIcon = appIcon
                }
                
                // Create fixed-size container
                let containerView = NSView(frame: NSRect(x: 0, y: 0, width: iconSize.width, height: iconSize.height))
                containerView.wantsLayer = true
                
                let imageView = ClickableImageView(frame: containerView.bounds)
                imageView.imageScaling = .scaleProportionallyDown
                imageView.image = finalIcon
                imageView.wantsLayer = true
                imageView.layer?.masksToBounds = true
                imageView.tag = Int(app.processIdentifier)
                
                // Remove opacity change for hidden apps
                imageView.alphaValue = 1.0  // Always fully visible
                
                // Center image in container
                containerView.addSubview(imageView)
                
                // Add fixed-width constraint to container
                containerView.widthAnchor.constraint(equalToConstant: iconSize.width).isActive = true
                
                stackView.addArrangedSubview(containerView)
            }
        }
        
        // Add edge handles with current position
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
              let app = NSRunningApplication(processIdentifier: pid_t(self.tag)),
              window != nil  // Add this check
              else { return }
        
        // Close existing popover if any
        popover?.close()
        
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
        
        // Show original colored icon and tooltip immediately
        if let app = NSRunningApplication(processIdentifier: pid_t(self.tag)),
           let appIcon = app.icon {
            appIcon.size = bounds.size
            DispatchQueue.main.async {
                self.image = appIcon
                self.showTooltipIfNeeded()  // Show tooltip immediately
            }
        }
    }
    
    override func mouseExited(with event: NSEvent) {
        isMouseInside = false
        tooltipTimer?.invalidate()
        tooltipTimer = nil
        popover?.close()
        popover = nil
        
        // Only return to grayscale if app is hidden
        if let app = NSRunningApplication(processIdentifier: pid_t(self.tag)) {
            if app.isHidden {
                if let appIcon = app.icon {
                    appIcon.size = self.bounds.size
                    
                    if let cgImage = appIcon.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                        let ciImage = CIImage(cgImage: cgImage)
                        let filter = CIFilter(name: "CIColorMonochrome")!
                        filter.setValue(ciImage, forKey: kCIInputImageKey)
                        filter.setValue(CIColor(red: 0.7, green: 0.7, blue: 0.7), forKey: kCIInputColorKey)
                        filter.setValue(1.0, forKey: kCIInputIntensityKey)
                        
                        if let output = filter.outputImage {
                            let context = CIContext(options: nil)
                            if let cgOutput = context.createCGImage(output, from: output.extent) {
                                self.image = NSImage(cgImage: cgOutput, size: self.bounds.size)
                            }
                        }
                    }
                }
            } else {
                // Non-hidden apps keep their original icon
                if let appIcon = app.icon {
                    appIcon.size = self.bounds.size
                    self.image = appIcon
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
        
        // Reset opacity since app is now active
        self.alphaValue = 1.0
        
        // Force active app to far left by moving all other apps right
        let currentApps = appDelegate.recentAppOrder.filter { $0 != bundleID }
        appDelegate.recentAppOrder = [bundleID] + currentApps
        
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
        let minIconSize: CGFloat = 38
        
        let clampedSize = min(max(newSize, minIconSize), maxIconSize)
        
        if abs(currentIconSize - clampedSize) > 0.5 {
            currentIconSize = clampedSize
            UserDefaults.standard.set(Float(clampedSize), forKey: "iconSize")
            
            // Force window to stay interactive
            runningAppsWindow.ignoresMouseEvents = false
            runningAppsWindow.acceptsMouseMovedEvents = true
            
            // Force immediate update
            updateRunningApps()
            
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
            
            // Force complete rebuild by calling updateRunningApps
            DispatchQueue.main.async {
                self.updateRunningApps()
            }
        }
    }
}

