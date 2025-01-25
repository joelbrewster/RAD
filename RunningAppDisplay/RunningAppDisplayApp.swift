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
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 36), // Increased height for larger icons
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
            $0.activationPolicy == .regular 
        }
        
        // Sort apps based on recent usage
        runningApps.sort { app1, app2 in
            guard let id1 = app1.bundleIdentifier,
                  let id2 = app2.bundleIdentifier else { return false }
            
            let index1 = recentAppOrder.firstIndex(of: id1) ?? Int.max
            let index2 = recentAppOrder.firstIndex(of: id2) ?? Int.max
            return index1 < index2
        }
        
        let iconSize = NSSize(width: 28, height: 28)  // Slightly smaller icons
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
        backgroundView.layer?.shadowOpacity = 0.15  // Reduced opacity
        backgroundView.layer?.shadowOffset = NSSize(width: 0, height: 0)
        backgroundView.layer?.shadowRadius = 10  // Slightly reduced radius
        backgroundView.layer?.masksToBounds = false
        
        // Create stack view
        let stackView = NSStackView(frame: NSRect(x: horizontalPadding, y: verticalPadding, 
                                                width: contentWidth - (horizontalPadding * 2), 
                                                height: iconSize.height))
        stackView.orientation = .horizontal
        stackView.spacing = spacing
        
        // Update window size and position - adjusted to account for shadow padding
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let xPosition = screen.frame.maxX - totalWidth - horizontalPadding + shadowPadding
        let yPosition: CGFloat = screen.frame.minY + horizontalPadding - shadowPadding  // Adjusted to account for shadow space
        
        runningAppsWindow.setFrame(NSRect(x: xPosition, y: yPosition, width: totalWidth, height: totalHeight), display: true)
        
        // Set up view hierarchy
        backgroundView.addSubview(stackView)
        containerView.addSubview(backgroundView)
        runningAppsWindow.contentView = containerView
        runningAppsWindow.backgroundColor = .clear
        runningAppsWindow.isOpaque = false
        runningAppsWindow.hasShadow = false
        
        // Add app icons
        for app in runningApps {
            if let appIcon = app.icon {
                let imageView = ClickableImageView(frame: NSRect(x: 0, y: 0, width: iconSize.width, height: iconSize.height))
                imageView.wantsLayer = true
                
                // Debug print original size
                print("App: \(app.localizedName ?? "unknown"), Original size: \(appIcon.size)")
                
                // Force exact size with strict constraints
                let resizedIcon = NSImage(size: iconSize)
                resizedIcon.lockFocus()
                let drawRect = NSRect(origin: .zero, size: iconSize)
                
                // Scale down the source rect if it's larger
                let sourceRect: NSRect
                if appIcon.size.width > iconSize.width || appIcon.size.height > iconSize.height {
                    let scale = min(iconSize.width / appIcon.size.width, iconSize.height / appIcon.size.height)
                    let scaledSize = NSSize(width: appIcon.size.width * scale, height: appIcon.size.height * scale)
                    sourceRect = NSRect(origin: .zero, size: scaledSize)
                } else {
                    sourceRect = NSRect(origin: .zero, size: appIcon.size)
                }
                
                appIcon.draw(in: drawRect, from: sourceRect, operation: .sourceOver, fraction: 1.0)
                resizedIcon.unlockFocus()
                
                // Debug print final size
                print("Final image size: \(resizedIcon.size)")
                
                imageView.image = resizedIcon
                imageView.wantsLayer = true
                imageView.layer?.contentsGravity = .resize
                imageView.layer?.bounds = CGRect(x: 0, y: 0, width: iconSize.width, height: iconSize.height)
                
                // Disable all automatic scaling
                resizedIcon.isTemplate = false
                resizedIcon.resizingMode = .stretch
                imageView.imageScaling = .scaleNone
                
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
    override var acceptsFirstResponder: Bool { return true }
    
    override func mouseDown(with event: NSEvent) {
        print("Mouse down received")  // Debug print
        if let app = NSRunningApplication(processIdentifier: pid_t(self.tag)) {
            print("Found app: \(app.localizedName ?? "unknown")")  // Debug print
            _ = app.activate(options: [.activateIgnoringOtherApps])
        }
    }
}
