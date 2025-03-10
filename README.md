# RunningAppDisplay

  Built with Swift and native macOS frameworks.

## Features

- Shows icons of all currently running applications
- Apps are sorted based on most recent usage
- Docks neatly in the bottom-right corner

## System Integration: 
  - Adapts to Light/Dark mode
  - Spans across all desktop spaces
  - Works best with System Settings > Motion > "Reduce motion" disabled

## Interactive Elements:
  - Click to switch to an app
  - Hover for app name tooltip
  - Right-click to force quit (still working on this - not sure how to set up permissions in xcode yet)

## Usage

Simply launch the application and it will display a floating bar containing icons of your running applications. The bar automatically updates as you:
- Launch new applications
- Switch between apps
- Toggle system appearance light/dark

## Technical Details

- Built with Swift and Cocoa frameworks
- Uses NSWindow for the floating display
- Implements workspace notifications for real-time updates
- Applies custom image processing for consistent icon appearance

## License

This project is licensed under the GNU General Public License (GPL). See [LICENSE](https://www.gnu.org/licenses/gpl-3.0.html) for details.

## Note

I use this dock with an increase with the dock's auto-hide feature:
```
defaults write com.apple.dock autohide-delay -float 100 && killall Dock
```
To reset it back to default:
```
defaults delete com.apple.dock autohide-delay && killall Dock
```
Make sure Dock auto-hide is enabled in System Settings for this to work. You can toggle the dock with cmd+option+d if needed.

## Contributing

Contributions are welcome! Please feel free to submit a PR. Please note, this is a hobby project built for learning purposes and from boredom. Contributions and suggestions are welcome! I'm not a Swift developer by any means so if there's a better way to do something, please let me know.
