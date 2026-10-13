//
//  Main.swift
//  Squirrel
//
//  Created by Leo Liu on 5/10/24.
//

import Foundation
import InputMethodKit
#if SYNTHETIC_IMK_PROBE
import OSLog
#endif

@main
struct SquirrelApp {
  #if SYNTHETIC_IMK_PROBE
  static let userDir = FileManager.default.homeDirectoryForCurrentUser
    .appending(components: "Library", "Rime-Squirrel-SyntheticTest")
  static let appDir = FileManager.default.homeDirectoryForCurrentUser
    .appending(components: "Library", "Input Methods", "SquirrelSyntheticTest.app")
  static let logDir = FileManager.default.temporaryDirectory
    .appending(component: "rime.squirrel.synthetic-test", directoryHint: .isDirectory)
  #else
  static let userDir = if let pwuid = getpwuid(getuid()) {
    URL(fileURLWithFileSystemRepresentation: pwuid.pointee.pw_dir, isDirectory: true, relativeTo: nil).appending(components: "Library", "Rime")
  } else {
    try! FileManager.default.url(for: .libraryDirectory, in: .userDomainMask, appropriateFor: nil, create: false).appendingPathComponent("Rime", isDirectory: true)
  }
  static let appDir = "/Library/Input Library/Squirrel.app".withCString { dir in
    URL(fileURLWithFileSystemRepresentation: dir, isDirectory: false, relativeTo: nil)
  }
  static let logDir = FileManager.default.temporaryDirectory.appending(component: "rime.squirrel", directoryHint: .isDirectory)
  #endif

  // swiftlint:disable:next cyclomatic_complexity
  static func main() {
    #if SYNTHETIC_IMK_PROBE
    guard Bundle.main.bundleIdentifier == "im.rime.inputmethod.Squirrel.SyntheticTest",
          Bundle.main.object(forInfoDictionaryKey: "SyntheticIMKProbe") as? Bool == true,
          SquirrelApp.userDir.resolvingSymlinksInPath() == SquirrelApp.userDir.standardizedFileURL,
          SquirrelApp.appDir.resolvingSymlinksInPath() == SquirrelApp.appDir.standardizedFileURL,
          SquirrelApp.logDir.resolvingSymlinksInPath().deletingLastPathComponent() ==
            FileManager.default.temporaryDirectory.resolvingSymlinksInPath() else {
      fputs("Synthetic IMK probe identity mismatch; refusing to start\n", stderr)
      return
    }
    #endif
    let rimeAPI: RimeApi_stdbool = rime_get_api_stdbool().pointee

    let handled = autoreleasepool {
      let installer = SquirrelInstaller()
      let args = CommandLine.arguments
      if args.count > 1 {
        switch args[1] {
        case "--quit":
          let bundleId = Bundle.main.bundleIdentifier!
          let runningSquirrels = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
          runningSquirrels.forEach { $0.terminate() }
          return true
        case "--reload":
          #if SYNTHETIC_IMK_PROBE
          return true
          #else
          DistributedNotificationCenter.default().postNotificationName(.init("SquirrelReloadNotification"), object: nil)
          return true
          #endif
        case "--register-input-source", "--install":
          installer.register()
          return true
        case "--enable-input-source":
          if args.count > 2 {
            let modes = args[2...].map { SquirrelInstaller.InputMode(rawValue: $0) }.compactMap { $0 }
            if !modes.isEmpty {
              installer.enable(modes: modes)
              return true
            }
          }
          installer.enable()
          return true
        case "--disable-input-source":
          if args.count > 2 {
            let modes = args[2...].map { SquirrelInstaller.InputMode(rawValue: $0) }.compactMap { $0 }
            if !modes.isEmpty {
              installer.disable(modes: modes)
              return true
            }
          }
          installer.disable()
          return true
        case "--select-input-source":
          if args.count > 2, let mode = SquirrelInstaller.InputMode(rawValue: args[2]) {
            installer.select(mode: mode)
          } else {
            installer.select()
          }
          return true
        case "--build":
          #if SYNTHETIC_IMK_PROBE
          // Never use the production builder shortcut in the isolated variant.
          return true
          #else
          // Notification
          SquirrelApplicationDelegate.showMessage(msgText: NSLocalizedString("deploy_update", comment: ""))
          // Build all schemas in current directory
          var builderTraits = RimeTraits.rimeStructInit()
          builderTraits.setCString("rime.squirrel-builder", to: \.app_name)
          rimeAPI.setup(&builderTraits)
          rimeAPI.deployer_initialize(nil)
          _ = rimeAPI.deploy()
          return true
          #endif
        case "--sync":
          #if SYNTHETIC_IMK_PROBE
          return true
          #else
          DistributedNotificationCenter.default().postNotificationName(.init("SquirrelSyncNotification"), object: nil)
          return true
          #endif
        case "--help":
          print(helpDoc)
          return true
        default:
          break
        }
      }
      return false
    }
    if handled {
      return
    }

    autoreleasepool {
      // find the bundle identifier and then initialize the input method server
      let main = Bundle.main
      let connectionName = main.object(forInfoDictionaryKey: "InputMethodConnectionName") as! String
      _ = IMKServer(name: connectionName, bundleIdentifier: main.bundleIdentifier!)
      #if SYNTHETIC_IMK_PROBE
      Logger(subsystem: "im.rime.inputmethod.Squirrel.SyntheticTest", category: "lifecycle").notice("serverReady")
      #endif
      // load the bundle explicitly because in this case the input method is a
      // background only application
      let app = NSApplication.shared
      let delegate = SquirrelApplicationDelegate()
      app.delegate = delegate
      app.setActivationPolicy(.accessory)

      // opencc will be configured with relative dictionary paths
      FileManager.default.changeCurrentDirectoryPath(main.sharedSupportPath!)

      #if SYNTHETIC_IMK_PROBE
      NSApp.squirrelAppDelegate.setupRime()
      NSApp.squirrelAppDelegate.startRime(fullCheck: false)
      // Fresh disposable data has no compiled config yet. Do not race fixture
      // maintenance and silently start the synthetic host in the wrong mode.
      rimeAPI.join_maintenance_thread()
      NSApp.squirrelAppDelegate.loadSettings()
      #else
      if NSApp.squirrelAppDelegate.problematicLaunchDetected() {
        print("Problematic launch detected!")
        let args = ["Problematic launch detected! Squirrel may be suffering a crash due to improper configuration. Revert previous modifications to see if the problem recurs."]
        let task = Process()
        task.executableURL = "/usr/bin/say".withCString { dir in
          URL(fileURLWithFileSystemRepresentation: dir, isDirectory: false, relativeTo: nil)
        }
        task.arguments = args
        try? task.run()
      } else {
        NSApp.squirrelAppDelegate.setupRime()
        NSApp.squirrelAppDelegate.startRime(fullCheck: false)
        NSApp.squirrelAppDelegate.loadSettings()
        print("Squirrel reporting!")
      }
      #endif

      // finally run everything
      app.run()
      print("Squirrel is quitting...")
      rimeAPI.finalize()
    }
    return
  }

  static let helpDoc = """
Supported arguments:
Perform actions:
  --quit                     quit all Squirrel process
  --reload                   deploy
  --sync                     sync user data
  --build                    build all schemas in current directory
Install Squirrel:
  --install, --register-input-source    register input source
  --enable-input-source [source id...]  input source list optional
  --disable-input-source [source id...] input source list optional
  --select-input-source [source id]     input source optional
"""
}
