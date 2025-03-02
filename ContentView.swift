// ... existing code ...
@AppStorage("windowWidth") private var windowWidth: Double = 800
@AppStorage("windowHeight") private var windowHeight: Double = 600

var body: some View {
    NavigationView {
        // ... existing code ...
    }
    .frame(width: windowWidth, height: windowHeight)
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResizeNotification)) { _ in
        if let window = NSApplication.shared.windows.first {
            windowWidth = window.frame.width
            windowHeight = window.frame.height
        }
    }
}