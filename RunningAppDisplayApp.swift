private let workspaceCacheLifetime: TimeInterval = 2.0 // Cache valid for 2 seconds
private var workspaceListCache: [String]?
private var workspaceListCacheTimestamp: Date?
private var windowInfoCache: [String: [(pid: Int32, title: String, name: String)]] = [:]
private var windowInfoCacheTimestamp: [String: Date] = [:]
private var workspaceViews: [String: NSView] = [:]
private var appImageViews: [Int32: ClickableImageView] = [:]

private func getWorkspaces() -> [String] {
    // Check cache first
    if let timestamp = workspaceListCacheTimestamp,
       Date().timeIntervalSince(timestamp) < workspaceCacheLifetime,
       let cached = workspaceListCache {
        return cached
    }

    guard let workspaceOutput = runAerospaceCommand(args: ["list-workspaces", "--all"]) else {
        return []
    }
    
    let allWorkspaces = workspaceOutput.components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
        
    // Only return workspaces that have windows in them
    let activeWorkspaces = allWorkspaces.filter { workspace in
        if let windowOutput = runAerospaceCommand(args: ["list-windows", "--workspace", workspace]) {
            let windows = windowOutput.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return !windows.isEmpty
        }
        return false
    }

    // Update cache
    workspaceListCache = activeWorkspaces
    workspaceListCacheTimestamp = Date()
    
    return activeWorkspaces
}

private func getWindowsForWorkspace(_ workspace: String) -> [(pid: Int32, title: String, name: String)] {
    // Check cache first
    if let timestamp = windowInfoCacheTimestamp[workspace],
       Date().timeIntervalSince(timestamp) < workspaceCacheLifetime,
       let cached = windowInfoCache[workspace] {
        return cached
    }

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
                }
            }
        }
    }
    
    guard let windowOutput = runAerospaceCommand(args: ["list-windows", "--workspace", workspace]) else {
        return []
    }
    
    let windows = windowOutput.components(separatedBy: .newlines)
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

    // Update cache
    windowInfoCache[workspace] = windows
    windowInfoCacheTimestamp[workspace] = Date()
    
    return windows
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
    
    // Use shorter interval for space changes
    let interval = source == .spaceChange ? 0.1 : 0.3
    
    // Schedule new update
    updateWorkDebounceTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
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
        
        // Pre-fetch adjacent workspaces after a space change
        if source == .spaceChange {
            self.preFetchAdjacentWorkspaces()
        }
        
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

private func preFetchAdjacentWorkspaces() {
    // Get current workspace
    guard let currentWorkspace = lastActiveWorkspace else { return }
    
    // Get all workspaces
    let workspaces = getWorkspaces()
    guard let currentIndex = workspaces.firstIndex(of: currentWorkspace) else { return }
    
    // Pre-fetch adjacent workspaces in background
    DispatchQueue.global(qos: .utility).async { [weak self] in
        // Pre-fetch previous workspace
        if currentIndex > 0 {
            let prevWorkspace = workspaces[currentIndex - 1]
            _ = self?.getWindowsForWorkspace(prevWorkspace)
        }
        
        // Pre-fetch next workspace
        if currentIndex < workspaces.count - 1 {
            let nextWorkspace = workspaces[currentIndex + 1]
            _ = self?.getWindowsForWorkspace(nextWorkspace)
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
    
    // Create or reuse container view
    let containerView = runningAppsWindow.contentView?.subviews.first as? DockContainerView ?? {
        let view = DockContainerView(frame: .zero)
        view.appDelegate = self
        view.wantsLayer = true
        runningAppsWindow.contentView?.subviews.forEach { $0.removeFromSuperview() }
        runningAppsWindow.contentView?.addSubview(view)
        return view
    }()
    
    // Create or reuse background view
    let backgroundView = containerView.subviews.first as? NSView ?? {
        let view = NSView(frame: .zero)
        view.wantsLayer = true
        containerView.addSubview(view)
        return view
    }()
    
    // Create or reuse blur view
    let blurView = backgroundView.subviews.first as? NSVisualEffectView ?? {
        let view = NSVisualEffectView(frame: .zero)
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = .hudWindow
        view.wantsLayer = true
        view.isEmphasized = false
        view.layer?.borderWidth = 0
        view.layer?.cornerRadius = 8
        backgroundView.addSubview(view)
        return view
    }()
    
    blurView.appearance = NSApp.effectiveAppearance
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
    
    // Create or reuse main stack view
    let mainStackView = blurView.subviews.first as? NSStackView ?? {
        let view = NSStackView(frame: .zero)
        view.orientation = .horizontal
        view.spacing = groupSpacing
        view.distribution = .gravityAreas
        view.alignment = .centerY
        blurView.addSubview(view)
        return view
    }()
    
    // Track used views to remove unused ones later
    var usedWorkspaceViews: Set<String> = []
    var usedAppViews: Set<Int32> = []
    
    // Update workspace groups
    for group in groups {
        let workspaceContainer = workspaceViews[group.workspace] ?? {
            let container = NSStackView(frame: .zero)
            container.orientation = .horizontal
            container.spacing = currentIconSize * 0.0625
            container.distribution = .fill
            container.alignment = .centerY
            workspaceViews[group.workspace] = container
            return container
        }()
        
        usedWorkspaceViews.insert(group.workspace)
        
        // Create or reuse visual container
        let visualContainer = workspaceContainer.superview ?? {
            let container = NSView(frame: .zero)
            container.wantsLayer = true
            container.layer?.cornerRadius = 6
            container.addSubview(workspaceContainer)
            return container
        }()
        
        // Set background color based on active state
        let isActive = group.workspace == focusedWorkspace
        let isDarkMode = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let whiteColor = NSColor(srgbRed: 1.0, green: 1.0, blue: 1.0, alpha: 1.0)
        let opacity: CGFloat = isActive ? (isDarkMode ? 0.4 : 0.8) : (isDarkMode ? 0.1 : 0.4)
        visualContainer.layer?.backgroundColor = whiteColor.withAlphaComponent(opacity).cgColor
        
        // Create or reuse group stack
        let groupStack = workspaceContainer.arrangedSubviews.first as? NSStackView ?? {
            let stack = NSStackView(frame: .zero)
            stack.orientation = .horizontal
            stack.spacing = 4
            stack.distribution = .fillEqually
            stack.alignment = .centerY
            workspaceContainer.addArrangedSubview(stack)
            return stack
        }()
        
        // Update apps
        for window in group.windows {
            if let app = NSRunningApplication(processIdentifier: pid_t(window.pid)) {
                let imageView = appImageViews[window.pid] ?? {
                    let view = ClickableImageView(frame: NSRect(x: 0, y: 0, width: currentIconSize, height: currentIconSize))
                    view.imageScaling = .scaleProportionallyUpOrDown
                    view.wantsLayer = true
                    view.layer?.cornerRadius = currentIconSize * 0.1875
                    view.layer?.masksToBounds = true
                    view.tag = Int(window.pid)
                    
                    // Add click handler
                    view.onClick = { [weak self] imageView in
                        guard let workspace = imageView.workspace else { return }
                        self?.switchToWorkspace(workspace)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            if let app = NSRunningApplication(processIdentifier: pid_t(imageView.tag)) {
                                app.activate()
                            }
                        }
                    }
                    
                    appImageViews[window.pid] = view
                    return view
                }()
                
                usedAppViews.insert(window.pid)
                
                // Update image view properties
                imageView.image = app.icon
                imageView.workspace = group.workspace
                imageView.appName = window.appName
                imageView.updateTooltipText()
                
                // Add to group if needed
                if imageView.superview != groupStack {
                    groupStack.addArrangedSubview(imageView)
                }
                
                // Update constraints if needed
                if imageView.constraints.isEmpty {
                    imageView.translatesAutoresizingMaskIntoConstraints = false
                    NSLayoutConstraint.activate([
                        imageView.widthAnchor.constraint(equalToConstant: currentIconSize),
                        imageView.heightAnchor.constraint(equalToConstant: currentIconSize)
                    ])
                }
            }
        }
        
        // Add to main stack if needed
        if visualContainer.superview != mainStackView {
            mainStackView.addArrangedSubview(visualContainer)
        }
        
        // Update workspace container constraints
        workspaceContainer.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            workspaceContainer.topAnchor.constraint(equalTo: visualContainer.topAnchor, constant: 6),
            workspaceContainer.bottomAnchor.constraint(equalTo: visualContainer.bottomAnchor, constant: -6),
            workspaceContainer.leadingAnchor.constraint(equalTo: visualContainer.leadingAnchor, constant: 6),
            workspaceContainer.trailingAnchor.constraint(equalTo: visualContainer.trailingAnchor, constant: -6)
        ])
    }
    
    // Remove unused views
    for (workspace, view) in workspaceViews {
        if !usedWorkspaceViews.contains(workspace) {
            view.removeFromSuperview()
            workspaceViews.removeValue(forKey: workspace)
        }
    }
    
    for (pid, view) in appImageViews {
        if !usedAppViews.contains(pid) {
            view.removeFromSuperview()
            appImageViews.removeValue(forKey: pid)
        }
    }
    
    // Update layout constraints
    mainStackView.translatesAutoresizingMaskIntoConstraints = false
    backgroundView.translatesAutoresizingMaskIntoConstraints = false
    blurView.translatesAutoresizingMaskIntoConstraints = false
    containerView.translatesAutoresizingMaskIntoConstraints = false
    
    NSLayoutConstraint.activate([
        // Main stack view constraints
        mainStackView.leadingAnchor.constraint(equalTo: blurView.leadingAnchor, constant: horizontalPadding),
        mainStackView.trailingAnchor.constraint(equalTo: blurView.trailingAnchor, constant: -horizontalPadding),
        mainStackView.topAnchor.constraint(equalTo: blurView.topAnchor, constant: verticalPadding),
        mainStackView.bottomAnchor.constraint(equalTo: blurView.bottomAnchor, constant: -verticalPadding),
        
        // Background view constraints
        backgroundView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
        backgroundView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
        backgroundView.topAnchor.constraint(equalTo: containerView.topAnchor),
        backgroundView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        
        // Blur view constraints
        blurView.leadingAnchor.constraint(equalTo: backgroundView.leadingAnchor),
        blurView.trailingAnchor.constraint(equalTo: backgroundView.trailingAnchor),
        blurView.topAnchor.constraint(equalTo: backgroundView.topAnchor),
        blurView.bottomAnchor.constraint(equalTo: backgroundView.bottomAnchor),
        
        // Container constraints
        containerView.widthAnchor.constraint(equalTo: mainStackView.widthAnchor, constant: horizontalPadding * 2),
        containerView.heightAnchor.constraint(equalTo: mainStackView.heightAnchor, constant: verticalPadding * 2)
    ])
    
    // Force layout and update window size
    containerView.layoutSubtreeIfNeeded()
    let stackSize = mainStackView.fittingSize
    let totalWidth = stackSize.width + (horizontalPadding * 2)
    let totalHeight = stackSize.height + (verticalPadding * 2)
    
    // Update window position
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
} 