import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/services/webdav_sync_service.dart';

/// WebDAV 同步页的控制器
///
/// 真正的同步逻辑（打包、上传、恢复、自动同步的调度）都在
/// [WebDavSyncService] 里，这里只做两件事：
/// 1. 把服务的状态转出去给页面绑定
/// 2. 处理需要界面的动作（登录弹窗、退出确认、加载提示）
///
/// 之所以要拆开：自动同步在后台跑，没有页面；以前逻辑挂在页面控制器上，
/// 页面一关就没了。
class RemoteSyncWebDAVController extends GetxController {
  WebDavSyncService get _sync => WebDavSyncService.instance;

  /// 密码是否可见
  var passwordVisible = true.obs;

  // ---- 状态转发 ----
  RxBool get notLogin => _sync.notLogin;
  RxString get user => _sync.user;
  RxString get lastUploadTime => _sync.lastUploadTime;
  RxString get lastRecoverTime => _sync.lastRecoverTime;
  RxBool get syncing => _sync.syncing;
  RxString get status => _sync.status;

  RxBool get autoUpload => _sync.autoUpload;
  RxBool get autoDownload => _sync.autoDownload;
  RxInt get checkInterval => _sync.checkInterval;

  RxBool get isSyncFollows => _sync.syncFollows;
  RxBool get isSyncHistories => _sync.syncHistories;
  RxBool get isSyncBlockWord => _sync.syncBlockWord;
  RxBool get isSyncBilibiliAccount => _sync.syncBiliAccount;
  RxBool get isSyncIptv => _sync.syncIptv;

  // ---- 界面动作 ----

  void changePasswordVisible() {
    passwordVisible.value = !passwordVisible.value;
  }

  Future<void> doWebDAVLogin(
    String webDAVUri,
    String webDAVUser,
    String webDAVPassword,
  ) async {
    SmartDialog.showLoading(msg: "正在验证");
    final ok = await _sync.login(webDAVUri, webDAVUser, webDAVPassword);
    SmartDialog.dismiss(status: SmartStatus.loading);
    if (ok) {
      Get.back();
      SmartDialog.showToast("登录成功！");
    } else {
      SmartDialog.showToast("WebDAV账号密码验证失败，请重新输入！");
    }
  }

  Future<void> onLogout() async {
    final result = await Utils.showAlertDialog("确定要登出WebDAV账号？", title: "退出登录");
    if (result) {
      await _sync.logout();
    }
  }

  /// 手动上传
  Future<void> doWebDAVUpload() => _sync.upload();

  /// 手动恢复到本地
  Future<void> doWebDAVRecovery() => _sync.restore();

  /// 立即检查云端有没有新数据
  ///
  /// force：即使「自动下载」关着也执行一次，这是用户主动点的
  Future<void> checkRemoteNow() => _sync.checkRemote(force: true);

  void changeAutoUpload(bool value) => _sync.setAutoUpload(value);

  void changeAutoDownload(bool value) => _sync.setAutoDownload(value);

  void changeCheckInterval(int minutes) => _sync.setCheckInterval(minutes);

  void changeIsSyncFollows() =>
      _sync.setSyncFollows(!_sync.syncFollows.value);

  void changeIsSyncHistories() =>
      _sync.setSyncHistories(!_sync.syncHistories.value);

  void changeIsSyncBlockWord() =>
      _sync.setSyncBlockWord(!_sync.syncBlockWord.value);

  void changeIsSyncBilibiliAccount() =>
      _sync.setSyncBiliAccount(!_sync.syncBiliAccount.value);

  void changeIsSyncIptv() => _sync.setSyncIptv(!_sync.syncIptv.value);
}
