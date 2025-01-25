# RunningAppDisplay

  Built with Swift and native macOS frameworks.

## Features

- Shows icons of all currently running applications
- Apps are sorted based on most recent usage
- Docks neatly in the bottom-right corner

## System Integration: 
  - Adapts to Light/Dark mode
  - Spans across all desktop spaces

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

This is a hobby project built for learning purposes and from boredom. Contributions and suggestions are welcome! I'm not a Swift developer by any means so if there's a better way to do something, please let me know.