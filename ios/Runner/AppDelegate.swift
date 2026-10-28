import Flutter
import UIKit
import UniformTypeIdentifiers
import Foundation // 添加此行

@main
@objc class AppDelegate: FlutterAppDelegate, UIDocumentPickerDelegate {
  var flutterResult: FlutterResult?
  var directoryPath: URL!
  private let storageBookmarkKey = "venera.localStorageBookmark"
  private var persistentDirectoryPath: URL?
  private var pickerRequestsPersistentAccess = false

  // 定义插件通道名称
  private var directoryPicker: DirectoryPicker?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    GeneratedPluginRegistrant.register(with: self)

    guard let controller = window?.rootViewController as? FlutterViewController else {
          fatalError("rootViewController is not of type FlutterViewController")
    }

    let methodChannel = FlutterMethodChannel(name: "venera/method_channel", binaryMessenger: controller.binaryMessenger)
    methodChannel.setMethodCallHandler { (call, result) in
      if call.method == "getProxy" {
        if let proxySettings = CFNetworkCopySystemProxySettings()?.takeUnretainedValue() as NSDictionary?,
          let dict = proxySettings.object(forKey: kCFNetworkProxiesHTTPProxy) as? NSDictionary,
          let host = dict.object(forKey: kCFNetworkProxiesHTTPProxy) as? String,
          let port = dict.object(forKey: kCFNetworkProxiesHTTPPort) as? Int {
          let proxyConfig = "\(host):\(port)"
          result(proxyConfig)
        } else {
          result("")
        }
      } else if call.method == "setScreenOn" {
        if let arguments = call.arguments as? Bool {
          let screenOn = arguments
          UIApplication.shared.isIdleTimerDisabled = screenOn
        }
        result(nil)
      } else if call.method == "getDirectoryPath" {
        let arguments = call.arguments as? [String: Any]
        self.pickerRequestsPersistentAccess = arguments?["persistent"] as? Bool ?? false
        self.flutterResult = result
        self.getDirectoryPath()
      } else if call.method == "stopAccessingSecurityScopedResource" {
        if self.directoryPath != self.persistentDirectoryPath {
          self.directoryPath?.stopAccessingSecurityScopedResource()
        }
        self.directoryPath = nil
        result(nil)
      } else if call.method == "selectDirectory" {
        self.directoryPicker = DirectoryPicker()
        self.directoryPicker?.selectDirectory(result: result)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }

    restorePersistentDirectoryBookmark()

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func getDirectoryPath() {
    let documentPicker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.folder], asCopy: false)
    documentPicker.delegate = self
    documentPicker.allowsMultipleSelection = false
    documentPicker.directoryURL = nil
    documentPicker.modalPresentationStyle = .formSheet

    if let rootViewController = window?.rootViewController {
      rootViewController.present(documentPicker, animated: true, completion: nil)
    }
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    self.directoryPath = urls.first
    if self.directoryPath == nil {
      flutterResult?(nil)
      return
    }

    let success = self.directoryPath.startAccessingSecurityScopedResource()

    if success {
      if self.pickerRequestsPersistentAccess {
        self.persistDirectoryBookmark(self.directoryPath)
      }
      flutterResult?(self.directoryPath.path)
    } else {
      flutterResult?(nil)
    }
  }

  private func persistDirectoryBookmark(_ url: URL) {
    do {
      let bookmark = try url.bookmarkData(
        options: .minimalBookmark,
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
        options: [],
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

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    flutterResult?(nil)
  }
}
