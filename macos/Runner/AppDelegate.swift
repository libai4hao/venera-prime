import Cocoa
import FlutterMacOS

@main
class AppDelegate: FlutterAppDelegate {
  var flutterResult: FlutterResult?
  var directoryPath: URL!
  private let storageBookmarkKey = "venera.localStorageBookmark"
  private var persistentDirectoryPath: URL?
  private var pickerRequestsPersistentAccess = false

  override func applicationDidFinishLaunching(_ notification: Notification) {
      let controller: FlutterViewController = mainFlutterWindow?.contentViewController as! FlutterViewController
      let methodChannel = FlutterMethodChannel(name: "venera/method_channel", binaryMessenger: controller.engine.binaryMessenger)

      methodChannel.setMethodCallHandler { (call, result) in
        switch call.method {
        case "getProxy":
            if let proxySettings = CFNetworkCopySystemProxySettings()?.takeUnretainedValue() as NSDictionary? {
                if let httpProxy = proxySettings[kCFNetworkProxiesHTTPProxy] as? String,
                   let httpPort = proxySettings[kCFNetworkProxiesHTTPPort] as? Int {
                    let proxyConfig = "\(httpProxy):\(httpPort)"
                    result(proxyConfig)
                } else if let socksProxy = proxySettings[kCFNetworkProxiesSOCKSProxy] as? String,
                          let socksPort = proxySettings[kCFNetworkProxiesSOCKSPort] as? Int {
                    let proxyConfig = "\(socksProxy):\(socksPort)"
                    result(proxyConfig)
                } else {
                    result("")
                }
            } else {
                result("")
            }
        case "getDirectoryPath":
          let arguments = call.arguments as? [String: Any]
          self.pickerRequestsPersistentAccess = arguments?["persistent"] as? Bool ?? false
          self.flutterResult = result
          self.getDirectoryPath()
        case "stopAccessingSecurityScopedResource":
          if self.directoryPath != self.persistentDirectoryPath {
            self.directoryPath?.stopAccessingSecurityScopedResource()
          }
          self.directoryPath = nil
          result(nil)
        default:
          result(FlutterMethodNotImplemented)
        }
      }

      let clipboardChannel = FlutterMethodChannel(name: "venera/clipboard", binaryMessenger: controller.engine.binaryMessenger)

      clipboardChannel.setMethodCallHandler { (call, result) in
        switch call.method {
        case "writeImageToClipboard":
          guard let arguments = call.arguments as? [String: Any],
            let data = arguments["data"] as? FlutterStandardTypedData else {
            result(FlutterError(code: "INVALID_ARGUMENTS", message: "Invalid arguments", details: nil))
            return
          }

          guard let image = NSImage(data: data.data) else {
            result(FlutterError(code: "INVALID_IMAGE", message: "Could not create image from data", details: nil))
            return
          }

          let pasteboard = NSPasteboard.general
          pasteboard.clearContents()
          pasteboard.writeObjects([image])
          result(true)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
    }

    restorePersistentDirectoryBookmark()
  }

  private func persistDirectoryBookmark(_ url: URL) {
    do {
      let bookmark = try url.bookmarkData(
        options: .withSecurityScope,
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
      UserDefaults.standard.set(bookmark, forKey: storageBookmarkKey)
      if let current = persistentDirectoryPath, current != url {
        current.stopAccessingSecurityScopedResource()
      }
      persistentDirectoryPath = url
    } catch {
      // Access remains valid for this session; a later pick can retry.
    }
  }

  private func restorePersistentDirectoryBookmark() {
    guard let bookmark = UserDefaults.standard.data(forKey: storageBookmarkKey) else {
      return
    }
    var isStale = false
    do {
      let url = try URL(
        resolvingBookmarkData: bookmark,
        options: .withSecurityScope,
        relativeTo: nil,
        bookmarkDataIsStale: &isStale
      )
      guard url.startAccessingSecurityScopedResource() else { return }
      persistentDirectoryPath = url
      if isStale {
        persistDirectoryBookmark(url)
      }
    } catch {
      UserDefaults.standard.removeObject(forKey: storageBookmarkKey)
    }
  }

  func getDirectoryPath() {
      let openPanel = NSOpenPanel()
      openPanel.canChooseDirectories = true
      openPanel.canChooseFiles = false
      openPanel.allowsMultipleSelection = false

      openPanel.begin { (result) in
          if result == .OK {
              self.directoryPath = openPanel.urls.first
              if let directoryPath = self.directoryPath, !directoryPath.startAccessingSecurityScopedResource() {
                  self.flutterResult?(nil)
                  return
              }
              if self.pickerRequestsPersistentAccess, let directoryPath = self.directoryPath {
                  self.persistDirectoryBookmark(directoryPath)
              }
              self.flutterResult?(self.directoryPath?.path)
          } else {
              self.flutterResult?(nil)
          }
      }
  }

  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }
}
