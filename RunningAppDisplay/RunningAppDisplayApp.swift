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
        
        runningAppsWindow.level = .statusBar
        runningAppsWindow.backgroundColor = .clear
        runningAppsWindow.isOpaque = false
        runningAppsWindow.hasShadow = false
        runningAppsWindow.ignoresMouseEvents = true
        runningAppsWindow.collectionBehavior = [.canJoinAllSpaces, .transient]
        
        // Calculate position for bottom right
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let padding: CGFloat = 8  // Reduced padding to be closer to bottom
        let runningAppsWidth: CGFloat = 300
        let xPosition = screen.frame.maxX - runningAppsWidth - padding
        let yPosition: CGFloat = screen.frame.minY + padding
        
        runningAppsWindow.setFrameOrigin(NSPoint(x: xPosition, y: yPosition))
        
        // Initialize with current running apps
        if let frontApp = workspace.frontmostApplication?.bundleIdentifier {
            updateRecentApps(frontApp)
        }
        updateRunningApps()
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
        
        let iconSize = NSSize(width: 36, height: 36)
        let spacing: CGFloat = 8
        let padding: CGFloat = 8
        
        // Calculate total width needed
        let totalWidth = CGFloat(runningApps.count) * (iconSize.width + spacing) - spacing + (padding * 2)
        
        // Create background view
        let backgroundView = NSView(frame: NSRect(x: 0, y: 0, width: totalWidth, height: 36))
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = 8
        
        // Set background color based on appearance - more opaque, menu bar style
        let isDarkMode = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if isDarkMode {
            backgroundView.layer?.backgroundColor = NSColor(white: 0.2, alpha: 0.95).cgColor
        } else {
            backgroundView.layer?.backgroundColor = NSColor(white: 0.95, alpha: 0.95).cgColor
        }
        
        let stackView = NSStackView(frame: NSRect(x: 0, y: 0, width: totalWidth, height: 36))
        stackView.orientation = .horizontal
        stackView.spacing = spacing
        stackView.edgeInsets = NSEdgeInsets(top: 0, left: padding, bottom: 0, right: padding)
        
        // Update window size and position
        let screen = NSScreen.main ?? NSScreen.screens[0]
        let xPosition = screen.frame.maxX - totalWidth - padding
        let yPosition: CGFloat = screen.frame.minY + padding
        
        runningAppsWindow.setFrame(NSRect(x: xPosition, y: yPosition, width: totalWidth, height: 36), display: true)
        
        // Add background and stack view to window
        backgroundView.addSubview(stackView)
        runningAppsWindow.contentView = backgroundView
        
        for app in runningApps {
            if let appIcon = app.icon {
                let imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: iconSize.width, height: iconSize.height))
                imageView.imageScaling = .scaleProportionallyDown
                imageView.wantsLayer = true
                
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
}
