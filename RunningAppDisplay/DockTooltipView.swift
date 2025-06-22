import Cocoa

class DockTooltipView: NSView {
    private let label: NSTextField
    private let backgroundView: NSVisualEffectView
    private let cornerRadius: CGFloat = 6
    private let padding: CGFloat = 8
    
    init(text: String) {
        // Create the background blur view
        backgroundView = NSVisualEffectView()
        backgroundView.material = .hudWindow
        backgroundView.state = .active
        backgroundView.blendingMode = .behindWindow
        
        // Create the label
        label = NSTextField(labelWithString: text)
        label.font = .menuBarFont(ofSize: 15)  // Standard menu bar font size
        label.textColor = .labelColor
        label.backgroundColor = .clear
        label.alignment = .center
        label.lineBreakMode = .byTruncatingTail
        
        // Calculate frame based on text (no arrow needed)
        let labelSize = label.sizeThatFits(NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude))
        let width = labelSize.width + (padding * 2)
        let height = labelSize.height + (padding * 2)
        
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: height))
        
        // Add and position subviews
        addSubview(backgroundView)
        addSubview(label)
        
        // Configure view
        wantsLayer = true
        layer?.masksToBounds = false
        
        // Position subviews
        backgroundView.frame = bounds
        label.frame = NSRect(
            x: padding,
            y: padding,
            width: width - (padding * 2),
            height: labelSize.height
        )
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func updateText(_ text: String) {
        label.stringValue = text
        
        // Recalculate size (no arrow)
        let labelSize = label.sizeThatFits(NSSize(width: 300, height: CGFloat.greatestFiniteMagnitude))
        let width = labelSize.width + (padding * 2)
        let height = labelSize.height + (padding * 2)
        
        // Update frames
        frame = NSRect(x: frame.minX, y: frame.minY, width: width, height: height)
        backgroundView.frame = bounds
        label.frame = NSRect(
            x: padding,
            y: padding,
            width: width - (padding * 2),
            height: labelSize.height
        )
        
        // Force redraw of the background shape
        setNeedsDisplay(bounds)
    }
    
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        
        // Create simple rounded rectangle path
        let path = NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius)
        
        // Set the path as the mask for the background view
        let maskLayer = CAShapeLayer()
        maskLayer.path = path.cgPath
        backgroundView.layer?.mask = maskLayer
    }
}

// Window to host the tooltip view
class DockTooltipWindow: NSWindow {
    private var tooltipView: DockTooltipView
    private static var sharedWindow: DockTooltipWindow?
    
    static func getSharedWindow() -> DockTooltipWindow {
        if let window = sharedWindow {
            return window
        }
        let window = DockTooltipWindow(text: "")
        window.orderFront(nil)  // Make sure window is in front
        window.alphaValue = 0   // But invisible initially
        sharedWindow = window
        return window
    }
    
    init(text: String) {
        tooltipView = DockTooltipView(text: text)
        
        super.init(
            contentRect: tooltipView.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        // Configure window
        contentView = tooltipView
        backgroundColor = .clear
        isOpaque = false
        hasShadow = true
        level = .floating + 1  // Make sure it's above other UI elements
        isReleasedWhenClosed = false
        ignoresMouseEvents = true  // Let mouse events pass through
    }
    
    func updateText(_ text: String) {
        tooltipView.updateText(text)
        setFrame(tooltipView.frame, display: true)
        // Make sure window is front after text update
        orderFront(nil)
    }
    
    deinit {
        if self === DockTooltipWindow.sharedWindow {
            DockTooltipWindow.sharedWindow = nil
        }
    }
} 
