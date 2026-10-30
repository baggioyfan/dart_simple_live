import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    // 必须在 Flutter 引擎启动之前执行，原因见 redirectTempDirectory 的注释。
    MainFlutterWindow.redirectTempDirectory()

    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }

  /// 把 TMPDIR 指到一个确定可写的位置。
  ///
  /// media_kit 打开播放列表时会用 `Directory.systemTemp` 建一个临时文件，把各条
  /// 线路的地址写进去，再让 mpv 执行 `loadlist <文件>`。而 Dart 的
  /// `Directory.systemTemp` 在 macOS 上就是直接读 `getenv("TMPDIR")`，取不到才
  /// 兜底 `/tmp`（见 runtime/bin/directory_macos.cc 的 Directory::SystemTemp）。
  ///
  /// 沙盒应用（app-sandbox=true）对 `/tmp` 没有写权限，media_kit 内部用的
  /// safe_local_storage 又会把写入失败静默吞掉，于是 mpv 收到一个根本不存在的
  /// 路径，报 `No such file or directory` —— 表现就是每个直播间都播不了。
  /// 同一个 App 在新系统上能播，只是那边 TMPDIR 恰好落在容器内的可写目录。
  ///
  /// 这里在 Dart 起来之前把 TMPDIR 换掉，不需要任何沙盒例外权限。
  private static func redirectTempDirectory() {
    let fm = FileManager.default

    // 优先容器临时目录，退到 Caches；都做一次写入探测，谁能写用谁。
    var candidates: [String] = [NSTemporaryDirectory()]
    if let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first?.path {
      candidates.append(caches)
    }

    for base in candidates {
      let dir = (base as NSString).appendingPathComponent("simple_live_tmp")
      try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true)

      let probe = (dir as NSString).appendingPathComponent(".write_probe")
      if fm.createFile(atPath: probe, contents: Data([0x00])) {
        try? fm.removeItem(atPath: probe)
        setenv("TMPDIR", dir, 1)
        NSLog("[SimpleLive] TMPDIR -> %@", dir)
        return
      }
    }

    NSLog("[SimpleLive] 找不到可写的临时目录，media_kit 的播放列表可能写入失败")
  }
}
