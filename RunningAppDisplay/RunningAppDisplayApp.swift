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
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 40),  // Increased height to accommodate larger icons
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
        
        let iconSize = NSSize(width: 32, height: 32)  // Standard macOS icon size
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
        
        // Add subtle border like macOS Dock (the real one)
        containerView.wantsLayer = true
        containerView.layer?.borderWidth = 0.5
        containerView.layer?.borderColor = NSColor(white: 1.0, alpha: 0.1).cgColor  // Even more subtle, like the real Dock
        
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
                print("App: \(app.localizedName ?? "unknown")")
                print("  Original size: \(appIcon.size)")
                print("  Representations: \(appIcon.representations.map { "\($0.size)" }.joined(separator: ", "))")
                print("  Has template: \(appIcon.isTemplate)")
                
                let imageView = ClickableImageView(frame: NSRect(x: 0, y: 0, width: iconSize.width, height: iconSize.height))
                imageView.wantsLayer = true
                
                // Create new image with exact size
                let resizedIcon = NSImage(size: iconSize)
                resizedIcon.lockFocus()
                
                // Clear the background first
                NSColor.clear.set()
                NSRect(origin: .zero, size: iconSize).fill()
                
                // Calculate scaling to fit exactly
                let scale = min(iconSize.width / appIcon.size.width, iconSize.height / appIcon.size.height)
                let scaledSize = NSSize(
                    width: appIcon.size.width * scale,
                    height: appIcon.size.height * scale
                )
                
                // Center the icon
                let x = (iconSize.width - scaledSize.width) / 2
                let y = (iconSize.height - scaledSize.height) / 2
                
                // Draw scaled and centered
                let drawRect = NSRect(x: x, y: y, width: scaledSize.width, height: scaledSize.height)
                appIcon.draw(in: drawRect, from: NSRect(origin: .zero, size: appIcon.size), 
                            operation: .sourceOver, fraction: 1.0)
                
                resizedIcon.unlockFocus()
                
                // Ensure no further scaling
                imageView.imageScaling = .scaleNone
                imageView.image = resizedIcon
                
                // Store the app reference for click handling
                imageView.tag = Int(app.processIdentifier)
                
                // Apply grayscale filter with adaptive brightness
                if let cgImage = appIcon.cgImage(forProposedRect: nil, context: nil, hints: nil),
                   let filter = CIFilter(name: "CIColorControls") {
                    let ciImage = CIImage(cgImage: cgImage)
                    filter.setValue(ciImage, forKey: kCIInputImageKey)
                    filter.setValue(0.0, forKey: kCIInputSaturationKey)
                    
                    if isDarkMode {
                        filter.setValue(1.4, forKey: kCIInputContrastKey)
                        filter.setValue(0.2, forKey: kCIInputBrightnessKey)
                    } else {
                        filter.setValue(1.2, forKey: kCIInputContrastKey)
                        filter.setValue(0.1, forKey: kCIInputBrightnessKey)
                    }
                    
                    if let outputImage = filter.outputImage {
                        let context = CIContext()
                        if let resultCGImage = context.createCGImage(outputImage, from: outputImage.extent) {
                            let resizedImage = NSImage(cgImage: resultCGImage, size: iconSize)
                            imageView.image = resizedImage
                        } else {
                            let resizedIcon = NSImage(size: iconSize)
                            resizedIcon.lockFocus()
                            appIcon.draw(in: NSRect(origin: .zero, size: iconSize))
                            resizedIcon.unlockFocus()
                            imageView.image = resizedIcon
                        }
                    }
                }
                
                // Add shadow
                imageView.layer?.shadowColor = NSColor.black.withAlphaComponent(0.2).cgColor
                imageView.layer?.shadowOffset = NSSize(width: 0, height: 0)
                imageView.layer?.shadowOpacity = 1.0
                imageView.layer?.shadowRadius = 1.0
                
                stackView.addArrangedSubview(imageView)
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
    
    override var acceptsFirstResponder: Bool { return true }
    
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .enabledDuringMouseDrag],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
    }
    
    override func mouseEntered(with event: NSEvent) {
        isMouseInside = true
        
        // Slight delay to avoid showing tooltip on quick movements
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self = self,
                  self.isMouseInside,
                  let app = NSRunningApplication(processIdentifier: pid_t(self.tag)) else { return }
            
            let popover = NSPopover()
            popover.behavior = .semitransient // Less aggressive than transient
            popover.animates = false // Faster appearance
            
            let label = NSTextField(labelWithString: app.localizedName ?? "Unknown")
            label.translatesAutoresizingMaskIntoConstraints = false
            
            let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
            contentView.addSubview(label)
            
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor)
            ])
            
            popover.contentViewController = NSViewController()
            popover.contentViewController?.view = contentView
            
            popover.show(relativeTo: self.bounds, of: self, preferredEdge: .maxY)
            self.popover = popover
        }
    }
    
    override func mouseExited(with event: NSEvent) {
        isMouseInside = false
        popover?.close()
        popover = nil
    }
    
    override func mouseDown(with event: NSEvent) {
        if let app = NSRunningApplication(processIdentifier: pid_t(self.tag)) {
            popover?.close() // Ensure popover is closed on click
            _ = app.activate(options: [.activateIgnoringOtherApps])
        }
    }
}
