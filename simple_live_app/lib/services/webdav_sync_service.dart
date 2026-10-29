import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:path/path.dart';
import 'package:path_provider/path_provider.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/app/utils/archive.dart';
import 'package:simple_live_app/app/utils/document.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:simple_live_app/modules/iptv/iptv_service.dart';
import 'package:simple_live_app/modules/iptv/iptv_tab_refresher.dart';
import 'package:simple_live_app/modules/iptv/models/iptv_channel.dart';
import 'package:simple_live_app/modules/iptv/models/iptv_source.dart';
import 'package:simple_live_app/modules/sync/remote_sync/webdav/webdav_client.dart';
import 'package:simple_live_app/services/bilibili_account_service.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';

/// WebDAV 同步（含自动同步）
///
/// 原来上传/恢复都只能手动点，在一台设备上改了关注、改了设置，另一台设备
/// 不点一下就不会变。这里把它做成自动的：
///
/// - **自动上传**：监听各个 Hive box 的写入事件（关注、标签、历史、直播源、
///   设置项），攒一小段时间后合并成一次上传。
/// - **自动下载**：启动后、回到前台、以及按间隔检查云端的文件修改时间，
///   比本地记录的新就自动恢复。
///
/// 判断条件集中在三处，避免来回打架：
/// 1. 云端时间戳一律用**服务器返回的 mtime**，不用本地时钟。上传成功后回读
///    一次 mtime 存下来，后续比较是「服务器 vs 服务器」，没有时钟偏差。
/// 2. 本地有未上传的改动（[_dirty]）时，即使云端更新也不自动下载，否则会把
///    本地刚改的东西冲掉。
/// 3. 恢复过程中 [_restoring] 为 true，期间自身写入触发的 box 事件不算改动，
///    否则恢复完立刻又上传，形成回环。
class WebDavSyncService extends GetxService with WidgetsBindingObserver {
  static WebDavSyncService get instance => Get.find<WebDavSyncService>();

  // ---------------- 可调参数 ----------------

  /// 最后一次改动后等多久才真正上传，把连续操作合并成一次
  static const Duration uploadDebounce = Duration(seconds: 10);

  /// 两次自动上传之间的最小间隔，防止高频改动把服务器刷爆
  static const Duration minUploadGap = Duration(seconds: 60);

  /// 启动后延迟多久检查云端，避开首屏加载
  static const Duration startupDelay = Duration(seconds: 6);

  /// 云端 mtime 要比本地记录新多少才算「有新数据」
  ///
  /// 正常情况下两者都来自服务器，只需要容忍秒级舍入；有的服务器会把 mtime
  /// 截断到分钟，所以留一点余量。
  static const Duration newerTolerance = Duration(seconds: 5);

  /// 自动检查云端的可选间隔（分钟）
  static const List<int> checkIntervalOptions = [15, 30, 60, 180, 720];

  static const int defaultCheckInterval = 60;

  /// 上传失败后的重试间隔（会逐次翻倍，最长 15 分钟）
  static const Duration _retryBase = Duration(minutes: 1);
  static const Duration _retryMax = Duration(minutes: 15);

  // ---------------- 状态 ----------------

  final RxBool notLogin = true.obs;
  final RxString user = '--'.obs;
  final RxString lastUploadTime = '--'.obs;
  final RxString lastRecoverTime = '--'.obs;

  /// 正在上传或恢复
  final RxBool syncing = false.obs;

  /// 最近一次同步结果，给界面显示
  final RxString status = ''.obs;

  final RxBool autoUpload = true.obs;
  final RxBool autoDownload = true.obs;
  final RxInt checkInterval = defaultCheckInterval.obs;

  final RxBool syncFollows = true.obs;
  final RxBool syncHistories = true.obs;
  final RxBool syncBlockWord = true.obs;
  final RxBool syncBiliAccount = true.obs;
  final RxBool syncIptv = true.obs;

  DAVClient? _client;
  String _uri = '';
  String _password = '';

  Timer? _debounce;
  Timer? _periodic;
  Timer? _retry;
  Duration _retryDelay = _retryBase;

  /// 本地有还没上传出去的改动
  bool _dirty = false;

  /// 自己写存储时置位，避免把自己的写入当成用户改动
  bool _suppressChange = false;

  /// 忽略改动到什么时候
  ///
  /// Hive 的 `watch()` 是异步派发的：恢复完把 [_suppressChange] 置回 false 之后，
  /// 恢复过程中那些写入的事件才陆续到达。不额外留一个静默期的话，刚拉下来的
  /// 数据会被当成「本地有新改动」，转头又传回云端。
  DateTime? _suppressUntil;

  /// 正在恢复云端数据到本地
  bool _restoring = false;

  DateTime? _lastUploadAt;

  final List<StreamSubscription> _watchers = [];

  LocalStorageService get _storage => LocalStorageService.instance;

  bool get configured => _uri.isNotEmpty && _client != null;

  /// 应用是否在前台
  ///
  /// 自动同步可能在后台触发（定时检查），这时候弹 toast 会拿不到 overlay。
  /// lifecycleState 在第一次生命周期回调之前是 null，当作前台处理。
  bool get _isForeground {
    final state = WidgetsBinding.instance.lifecycleState;
    return state == null || state == AppLifecycleState.resumed;
  }

  /// 这些 key 的变化不算「用户数据改动」，否则上传完写个时间戳又会触发上传
  static final Set<String> _ignoredSettingKeys = {
    LocalStorageService.kWebDAVUri,
    LocalStorageService.kWebDAVUser,
    LocalStorageService.kWebDAVPassword,
    LocalStorageService.kWebDAVLastUploadTime,
    LocalStorageService.kWebDAVLastRecoverTime,
    LocalStorageService.kWebDAVSyncedTime,
    LocalStorageService.kWebDAVAutoUpload,
    LocalStorageService.kWebDAVAutoDownload,
    LocalStorageService.kWebDAVCheckInterval,
    LocalStorageService.kWebDAVSyncFollows,
    LocalStorageService.kWebDAVSyncHistories,
    LocalStorageService.kWebDAVSyncBlockWord,
    LocalStorageService.kWebDAVSyncBiliAccount,
    LocalStorageService.kWebDAVSyncIptv,
    LocalStorageService.kWebDAVPendingUpload,
  };

  // 云端备份里的文件名
  final _followJsonName = 'SimpleLive_follows.json';
  final _historiesJsonName = 'SimpleLive_histories.json';
  final _blockedWordJsonName = 'SimpleLive_blocked_word.json';
  final _bilibiliAccountJsonName = 'SimpleLive_bilibili_account.json';
  final _settingsJsonName = 'SimpleLive_Settings.json';
  final _tagsJsonName = 'SimpleLive_Tags.json';
  final _iptvSourcesJsonName = 'SimpleLive_iptv_sources.json';
  final _iptvChannelsJsonName = 'SimpleLive_iptv_channels.json';

  // ---------------- 生命周期 ----------------

  Future init() async {
    WidgetsBinding.instance.addObserver(this);
    _loadConfig();
    if (configured) {
      _checkLogin();
    }
    _startWatchers();
    _startPeriodic();
    // 云端检查放到首屏之后，别和启动时的网络请求抢
    Future.delayed(startupDelay, () {
      if (!configured) return;
      // 上次退出前没传完的改动优先补传：这时候去下载会把本地改动冲掉
      if (_dirty) {
        if (autoUpload.value) _uploadNow();
        return;
      }
      if (autoDownload.value) {
        checkRemote(silent: true);
      }
    });
  }

  @override
  void onClose() {
    WidgetsBinding.instance.removeObserver(this);
    _debounce?.cancel();
    _periodic?.cancel();
    _retry?.cancel();
    for (final sub in _watchers) {
      sub.cancel();
    }
    _watchers.clear();
    super.onClose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!configured) return;
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.detached:
        // 切后台 / 退出前把攒着的改动刷出去，否则下一次启动前改动就丢了
        if (_dirty && autoUpload.value) {
          _debounce?.cancel();
          _uploadNow();
        }
        break;
      case AppLifecycleState.resumed:
        // 回到前台顺手问一下云端有没有新数据
        if (autoDownload.value) {
          checkRemote(silent: true);
        }
        break;
      default:
        break;
    }
  }

  // ---------------- 配置 ----------------

  void _loadConfig() {
    _uri = _storage.getValue(LocalStorageService.kWebDAVUri, '');
    user.value = _storage.getValue(LocalStorageService.kWebDAVUser, '--');
    _password = _storage.getValue(LocalStorageService.kWebDAVPassword, '');

    autoUpload.value =
        _storage.getValue(LocalStorageService.kWebDAVAutoUpload, true);
    autoDownload.value =
        _storage.getValue(LocalStorageService.kWebDAVAutoDownload, true);
    final interval =
        _storage.getValue(LocalStorageService.kWebDAVCheckInterval,
            defaultCheckInterval);
    checkInterval.value =
        interval < 1 ? defaultCheckInterval : interval;

    syncFollows.value =
        _storage.getValue(LocalStorageService.kWebDAVSyncFollows, true);
    syncHistories.value =
        _storage.getValue(LocalStorageService.kWebDAVSyncHistories, true);
    syncBlockWord.value =
        _storage.getValue(LocalStorageService.kWebDAVSyncBlockWord, true);
    syncBiliAccount.value =
        _storage.getValue(LocalStorageService.kWebDAVSyncBiliAccount, true);
    syncIptv.value =
        _storage.getValue(LocalStorageService.kWebDAVSyncIptv, true);

    if (_uri.isEmpty) {
      notLogin.value = true;
    } else {
      _client = DAVClient(_uri, user.value, _password);
      // 先当已登录，ping 失败再翻过来，免得页面打开瞬间闪一下「点击登录」
      notLogin.value = false;
    }

    lastUploadTime.value = _formatStamp(
      _storage.getValue(LocalStorageService.kWebDAVLastUploadTime, 0),
    );
    lastRecoverTime.value = _formatStamp(
      _storage.getValue(LocalStorageService.kWebDAVLastRecoverTime, 0),
    );

    // 上次退出前还有没传出去的改动
    _dirty =
        _storage.getValue(LocalStorageService.kWebDAVPendingUpload, false);
  }

  String _formatStamp(int milliseconds) {
    if (milliseconds <= 0) return '--';
    return Utils.parseTime(DateTime.fromMillisecondsSinceEpoch(milliseconds));
  }

  Future<void> _checkLogin() async {
    try {
      final ok = await _client?.pingCompleter.future ?? false;
      notLogin.value = !ok;
    } catch (e) {
      Log.e('$e', StackTrace.current);
      notLogin.value = true;
    }
  }

  Future<bool> login(String uri, String userName, String password) async {
    final client = DAVClient(uri, userName, password);
    bool ok = false;
    try {
      ok = await client.pingCompleter.future;
    } catch (e) {
      Log.logPrint(e);
    }
    if (!ok) return false;

    _client = client;
    _uri = uri;
    _password = password;

    await _storage.setValue(LocalStorageService.kWebDAVUri, uri);
    await _storage.setValue(LocalStorageService.kWebDAVUser, userName);
    await _storage.setValue(LocalStorageService.kWebDAVPassword, password);

    user.value = userName;
    notLogin.value = false;
    _startPeriodic();
    return true;
  }

  Future<void> logout() async {
    await _storage.setValue(LocalStorageService.kWebDAVUri, '');
    await _storage.setValue(LocalStorageService.kWebDAVUser, '');
    await _storage.setValue(LocalStorageService.kWebDAVPassword, '');
    // 换了账号，之前那个账号的同步基准就没意义了，清掉重新判断
    await _storage.setValue(LocalStorageService.kWebDAVSyncedTime, 0);
    await _storage.setValue(LocalStorageService.kWebDAVLastUploadTime, 0);
    await _storage.setValue(LocalStorageService.kWebDAVLastRecoverTime, 0);
    await _storage.setValue(LocalStorageService.kWebDAVPendingUpload, false);

    _client = null;
    _uri = '';
    _password = '';
    _dirty = false;
    notLogin.value = true;
    user.value = '--';
    lastUploadTime.value = '--';
    lastRecoverTime.value = '--';
    status.value = '';
    _debounce?.cancel();
    _periodic?.cancel();
    _retry?.cancel();
  }

  Future<void> setAutoUpload(bool value) async {
    autoUpload.value = value;
    await _storage.setValue(LocalStorageService.kWebDAVAutoUpload, value);
    if (value && _dirty) _scheduleUpload();
  }

  Future<void> setAutoDownload(bool value) async {
    autoDownload.value = value;
    await _storage.setValue(LocalStorageService.kWebDAVAutoDownload, value);
    _startPeriodic();
  }

  Future<void> setCheckInterval(int minutes) async {
    checkInterval.value = minutes;
    await _storage.setValue(LocalStorageService.kWebDAVCheckInterval, minutes);
    _startPeriodic();
  }

  Future<void> setSyncFollows(bool value) async {
    syncFollows.value = value;
    await _storage.setValue(LocalStorageService.kWebDAVSyncFollows, value);
  }

  Future<void> setSyncHistories(bool value) async {
    syncHistories.value = value;
    await _storage.setValue(LocalStorageService.kWebDAVSyncHistories, value);
  }

  Future<void> setSyncBlockWord(bool value) async {
    syncBlockWord.value = value;
    await _storage.setValue(LocalStorageService.kWebDAVSyncBlockWord, value);
  }

  Future<void> setSyncBiliAccount(bool value) async {
    syncBiliAccount.value = value;
    await _storage.setValue(LocalStorageService.kWebDAVSyncBiliAccount, value);
  }

  Future<void> setSyncIptv(bool value) async {
    syncIptv.value = value;
    await _storage.setValue(LocalStorageService.kWebDAVSyncIptv, value);
  }

  // ---------------- 改动监听 ----------------

  void _startWatchers() {
    if (_watchers.isNotEmpty) return;
    final db = DBService.instance;
    final iptv = IptvService.instance;

    _watch(db.followBox.watch(), '关注列表');
    _watch(db.tagBox.watch(), '关注标签');
    _watch(db.historyBox.watch(), '观看记录');
    _watch(iptv.sourceBox.watch(), '直播源');
    _watch(iptv.channelBox.watch(), '直播频道');

    // 设置项都在同一个 box 里，要把 WebDAV 自己的 key 排除掉
    _watchers.add(
      _storage.settingsBox.watch().listen((event) {
        if (_ignoredSettingKeys.contains(event.key)) return;
        _onLocalChange('设置项');
      }),
    );
  }

  void _watch(Stream<BoxEvent> stream, String label) {
    _watchers.add(stream.listen((_) => _onLocalChange(label)));
  }

  void _onLocalChange(String label) {
    if (_suppressChange || _restoring) return;
    final until = _suppressUntil;
    if (until != null && DateTime.now().isBefore(until)) return;
    if (!configured) return;
    _markDirty();
    if (!autoUpload.value) return;
    Log.d('WebDAV：$label 有改动，等待自动上传');
    _scheduleUpload();
  }

  /// 标记有未上传的改动，并落盘
  ///
  /// 只记在内存里的话，改完立刻把 App 划掉，标记就没了，这次改动要等到下次
  /// 改动才被带上去。落盘之后下次启动能补传。
  void _markDirty() {
    if (_dirty) return;
    _dirty = true;
    _storage.setValue(LocalStorageService.kWebDAVPendingUpload, true);
  }

  void _clearDirty() {
    if (!_dirty) return;
    _dirty = false;
    _storage.setValue(LocalStorageService.kWebDAVPendingUpload, false);
  }

  void _scheduleUpload() {
    _debounce?.cancel();
    _debounce = Timer(uploadDebounce, _uploadNow);
  }

  Future<void> _uploadNow() async {
    if (!configured || !autoUpload.value) return;
    if (!_dirty) return;

    // 正在同步就等它结束再说，不要并发
    if (syncing.value) {
      _scheduleUpload();
      return;
    }

    // 两次自动上传之间留个最小间隔
    final last = _lastUploadAt;
    if (last != null) {
      final elapsed = DateTime.now().difference(last);
      if (elapsed < minUploadGap) {
        _debounce?.cancel();
        _debounce = Timer(minUploadGap - elapsed, _uploadNow);
        return;
      }
    }

    if (!await _hasNetwork()) {
      Log.logPrint('WebDAV：当前无网络，等下次再传');
      _scheduleRetry();
      return;
    }

    final ok = await upload(silent: true);
    if (!ok) _scheduleRetry();
  }

  void _scheduleRetry() {
    _retry?.cancel();
    _retry = Timer(_retryDelay, _uploadNow);
    // 逐次翻倍，避免断网时频繁打服务器
    final next = _retryDelay * 2;
    _retryDelay = next > _retryMax ? _retryMax : next;
  }

  void _startPeriodic() {
    _periodic?.cancel();
    if (!configured || !autoDownload.value) return;
    _periodic = Timer.periodic(
      Duration(minutes: checkInterval.value),
      (_) {
        if (_dirty) {
          _uploadNow();
        } else {
          checkRemote(silent: true);
        }
      },
    );
  }

  Future<bool> _hasNetwork() async {
    try {
      final result = await Connectivity().checkConnectivity();
      return result.any((e) => e != ConnectivityResult.none);
    } catch (_) {
      // 拿不到就当有网，交给请求本身去失败
      return true;
    }
  }

  // ---------------- 上传 ----------------

  /// 上传到云端
  ///
  /// [silent] 为 true 时不弹任何界面提示（自动同步用），失败只写日志和 [status]。
  Future<bool> upload({bool silent = false}) async {
    if (!configured) {
      if (!silent) SmartDialog.showToast('请先登录 WebDAV');
      return false;
    }
    if (syncing.value) {
      if (!silent) SmartDialog.showToast('正在同步，请稍候');
      return false;
    }

    syncing.value = true;
    if (!silent) SmartDialog.showLoading(msg: '正在上传到云端');
    try {
      final bytes = await packBackup();
      if (bytes.isEmpty) throw Exception('本地数据打包失败');

      await _client!.backup(Uint8List.fromList(bytes));

      final now = DateTime.now();
      // 回读服务器上的 mtime 作为「已同步」基准，这样后续比较不受本机时钟影响
      final remoteTime = await _client!.remoteModified();

      await _storage.setValue(
        LocalStorageService.kWebDAVLastUploadTime,
        now.millisecondsSinceEpoch,
      );
      await _storage.setValue(
        LocalStorageService.kWebDAVSyncedTime,
        (remoteTime ?? now).millisecondsSinceEpoch,
      );

      lastUploadTime.value = Utils.parseTime(now);
      _clearDirty();
      _lastUploadAt = now;
      _retryDelay = _retryBase;
      _retry?.cancel();
      status.value = '已上传（${Utils.parseTime(now)}）';

      if (!silent) SmartDialog.showToast('上传成功');
      return true;
    } catch (e) {
      Log.e('WebDAV 上传失败：$e', StackTrace.current);
      status.value = '上传失败：$e';
      if (!silent) SmartDialog.showToast('上传失败');
      return false;
    } finally {
      if (!silent) SmartDialog.dismiss(status: SmartStatus.loading);
      syncing.value = false;
    }
  }

  /// 打包本地数据成 zip
  Future<List<int>> packBackup() async {
    final archive = Archive();
    List<int> zipBytes = [];
    final dir = (await getApplicationSupportDirectory()).path;
    final profile = Directory(join(dir, 'backup'));
    if (!profile.existsSync()) {
      profile.createSync();
    }
    try {
      // archive.add(filepath, data_map) 会导致文件损坏
      final userFollowList = DBService.instance.getFollowList();
      await File(join(profile.path, _followJsonName)).writeAsString(
        jsonEncode({'data': userFollowList.map((e) => e.toJson()).toList()}),
      );

      final userTagsList = DBService.instance.getFollowTagList();
      await File(join(profile.path, _tagsJsonName)).writeAsString(
        jsonEncode({'data': userTagsList.map((e) => e.toJson()).toList()}),
      );

      final userHistoriesList = DBService.instance.getHistores();
      await File(join(profile.path, _historiesJsonName)).writeAsString(
        jsonEncode({'data': userHistoriesList.map((e) => e.toJson()).toList()}),
      );

      final shieldList = AppSettingsController.instance.shieldList;
      await File(join(profile.path, _blockedWordJsonName)).writeAsString(
        jsonEncode({'data': shieldList.toList()}),
      );

      await File(join(profile.path, _bilibiliAccountJsonName)).writeAsString(
        jsonEncode({
          'data': {'cookie': BiliBiliAccountService.instance.cookie}
        }),
      );

      await File(join(profile.path, _settingsJsonName)).writeAsString(
        jsonEncode({'data': _storage.settingsBox.toMap()}),
      );

      // 频道也一起存：只还原源的话，新设备上得等下次自动更新才有频道列表，
      // 而且播放列表里的顺序（order）也会丢。
      await File(join(profile.path, _iptvSourcesJsonName)).writeAsString(
        jsonEncode({
          'data': IptvService.instance.getSources().map((e) => e.toJson()).toList()
        }),
      );

      await File(join(profile.path, _iptvChannelsJsonName)).writeAsString(
        jsonEncode({
          'data':
              IptvService.instance.getAllChannels().map((e) => e.toJson()).toList()
        }),
      );

      await archive.addDirectoryToArchive(profile.path, profile.path);
      zipBytes = ZipEncoder().encode(archive);
      profile.clearSync();
    } catch (e) {
      Log.logPrint(e);
      throw Exception('打包本地数据失败：$e');
    }
    return zipBytes;
  }

  // ---------------- 下载（恢复） ----------------

  /// 检查云端有没有比本地新的数据，有就恢复
  ///
  /// [silent] 为 true 时不弹提示，只在确实恢复了数据时提示一句。
  /// [force] 为 true 时忽略「自动下载」开关（界面上的「立即检查云端」用）。
  Future<bool> checkRemote({bool silent = false, bool force = false}) async {
    if (!configured) return false;
    if (!force && !autoDownload.value) return false;
    if (syncing.value) return false;

    try {
      final remoteTime = await _client!.remoteModified();
      if (remoteTime == null) {
        // 云端还没有备份，第一次上传之后才会有
        return false;
      }

      final synced = _syncedTime();
      if (!remoteTime.isAfter(synced.add(newerTolerance))) {
        Log.d('WebDAV：云端没有新数据（${remoteTime.toIso8601String()}）');
        return false;
      }

      // 本地有没传出去的改动，云端也更新了 —— 谁都不覆盖，等用户手动处理
      if (_dirty) {
        status.value = '云端有新数据，但本地有未上传的改动';
        Log.w('WebDAV：云端有新数据但本地有未上传改动，跳过自动下载');
        if (!silent) {
          SmartDialog.showToast('本地有未上传的改动，已跳过自动下载');
        }
        return false;
      }

      Log.i('WebDAV：云端有新数据，开始自动下载');
      return await restore(silent: true);
    } catch (e) {
      Log.e('WebDAV 检查云端失败：$e', StackTrace.current);
      status.value = '检查云端失败：$e';
      return false;
    }
  }

  /// 从云端恢复到本地
  Future<bool> restore({bool silent = false}) async {
    if (!configured) {
      if (!silent) SmartDialog.showToast('请先登录 WebDAV');
      return false;
    }
    if (syncing.value) {
      if (!silent) SmartDialog.showToast('正在同步，请稍候');
      return false;
    }

    syncing.value = true;
    _restoring = true;
    if (!silent) SmartDialog.showLoading(msg: '正在恢复到本地');
    try {
      final remoteTime = await _client!.remoteModified();
      final data = await _client!.recovery();
      final archive = await Isolate.run<Archive>(() {
        return ZipDecoder().decodeBytes(data);
      });

      _suppressChange = true;
      for (final file in archive) {
        await _applyFile(file);
      }
      _suppressChange = false;

      final now = DateTime.now();
      // 恢复完把基准对齐到云端时间，否则下次检查还会认为云端更新
      await _storage.setValue(
        LocalStorageService.kWebDAVSyncedTime,
        (remoteTime ?? now).millisecondsSinceEpoch,
      );
      await _storage.setValue(
        LocalStorageService.kWebDAVLastRecoverTime,
        now.millisecondsSinceEpoch,
      );

      lastRecoverTime.value = Utils.parseTime(now);
      _clearDirty();
      status.value = '已下载（${Utils.parseTime(now)}）';

      // 数据被换了一批，正在看的页面要跟着刷新
      EventBus.instance.emit(Constant.kUpdateFollow, 0);
      EventBus.instance.emit(Constant.kUpdateHistory, 0);
      if (syncIptv.value) {
        IptvService.instance.clearEpgCache();
        IptvTabRefresher.refreshAll();
      }

      if (_isForeground) {
        SmartDialog.showToast(silent ? '已从云端自动同步' : '同步完成');
      }
      return true;
    } catch (e) {
      Log.e('WebDAV 恢复失败：$e', StackTrace.current);
      status.value = '恢复失败：$e';
      if (!silent) SmartDialog.showToast('恢复失败');
      return false;
    } finally {
      _suppressChange = false;
      // 留 3 秒静默期，等恢复过程中那批 box 事件派发完
      _suppressUntil = DateTime.now().add(const Duration(seconds: 3));
      _restoring = false;
      if (!silent) SmartDialog.dismiss(status: SmartStatus.loading);
      syncing.value = false;
    }
  }

  /// 本地数据与云端一致的时间点
  ///
  /// 正常情况下直接取 [LocalStorageService.kWebDAVSyncedTime]，它存的是服务器
  /// 返回的 mtime。没记录过要分两种情况：
  ///
  /// - **全新设备 / 刚登录**：从没传过也从没恢复过，云端只要存在备份就该拉下来，
  ///   基准给 0（epoch）。
  /// - **老版本升级上来**：以前只有手动同步，本地可能在上次上传之后又改过东西。
  ///   这时云端和本地谁新其实无从判断，所以基准给「现在」，即默认不覆盖本地，
  ///   等下一次上传或恢复把基准补上。
  DateTime _syncedTime() {
    final synced = _storage.getValue(LocalStorageService.kWebDAVSyncedTime, 0);
    if (synced > 0) return DateTime.fromMillisecondsSinceEpoch(synced);

    final lastUpload =
        _storage.getValue(LocalStorageService.kWebDAVLastUploadTime, 0);
    final lastRecover =
        _storage.getValue(LocalStorageService.kWebDAVLastRecoverTime, 0);
    if (lastUpload == 0 && lastRecover == 0) {
      return DateTime.fromMillisecondsSinceEpoch(0);
    }
    return DateTime.now();
  }

  Future<void> _applyFile(ArchiveFile file) async {
    if (!file.isFile || !file.name.endsWith('.json')) return;

    final jsonData = json.decode(utf8.decode(file.content))['data'];

    if (file.name == _followJsonName && syncFollows.value) {
      try {
        await DBService.instance.followBox.clear();
        for (final item in jsonData) {
          final user = FollowUser.fromJson(item);
          await DBService.instance.followBox.put(user.id, user);
        }
        Log.i('已同步关注用户列表');
      } catch (e) {
        Log.e('同步关注用户列表失败：$e', StackTrace.current);
      }
    } else if (file.name == _tagsJsonName && syncFollows.value) {
      try {
        // 标签和关注有依赖关系，必须一起同步
        await DBService.instance.tagBox.clear();
        for (final item in jsonData) {
          final tag = FollowUserTag.fromJson(item);
          await DBService.instance.tagBox.put(tag.id, tag);
        }
        Log.i('已同步用户自定义标签');
      } catch (e) {
        Log.e('同步用户自定义标签失败：$e', StackTrace.current);
      }
    } else if (file.name == _historiesJsonName && syncHistories.value) {
      try {
        for (final item in jsonData) {
          final history = History.fromJson(item);
          if (DBService.instance.historyBox.containsKey(history.id)) {
            final old = DBService.instance.historyBox.get(history.id);
            // 本地更新时间比较新就不覆盖
            if (old!.updateTime.isAfter(history.updateTime)) continue;
          }
          await DBService.instance.addOrUpdateHistory(history);
        }
        Log.i('已同步观看记录');
      } catch (e) {
        Log.e('同步观看记录失败：$e', StackTrace.current);
      }
    } else if (file.name == _blockedWordJsonName && syncBlockWord.value) {
      try {
        for (final keyword in jsonData) {
          AppSettingsController.instance.addShieldList(keyword.trim());
        }
        Log.i('已同步弹幕屏蔽词');
      } catch (e) {
        Log.e('同步弹幕屏蔽词失败：$e', StackTrace.current);
      }
    } else if (file.name == _bilibiliAccountJsonName && syncBiliAccount.value) {
      try {
        BiliBiliAccountService.instance.setCookie(jsonData['cookie']);
        BiliBiliAccountService.instance.loadUserInfo();
        Log.i('已同步哔哩哔哩账号');
      } catch (e) {
        Log.e('同步哔哩哔哩账号失败：$e', StackTrace.current);
      }
    } else if (file.name == _settingsJsonName) {
      try {
        await _applySettings(jsonData as Map);
        Log.i('已同步用户设置');
      } catch (e) {
        Log.e('同步用户设置失败：$e', StackTrace.current);
      }
    } else if (file.name == _iptvSourcesJsonName && syncIptv.value) {
      try {
        await IptvService.instance.sourceBox.clear();
        for (final item in jsonData) {
          final source = IptvSource.fromJson(item as Map<String, dynamic>);
          await IptvService.instance.sourceBox.put(source.id, source);
        }
        Log.i('已同步自定义直播源');
      } catch (e) {
        Log.e('同步自定义直播源失败：$e', StackTrace.current);
      }
    } else if (file.name == _iptvChannelsJsonName && syncIptv.value) {
      try {
        await IptvService.instance.channelBox.clear();
        for (final item in jsonData) {
          final channel = IptvChannel.fromJson(item as Map<String, dynamic>);
          await IptvService.instance.channelBox.put(channel.id, channel);
        }
        Log.i('已同步自定义直播源频道');
      } catch (e) {
        Log.e('同步自定义直播源频道失败：$e', StackTrace.current);
      }
    }
  }

  /// 恢复设置项
  ///
  /// 备份里的 settings 是整个 box，直接 putAll 会把 WebDAV 自己的账号密码、
  /// 自动同步开关一起冲掉（旧备份里甚至没有这些 key）。这些是本机行为配置，
  /// 不属于要同步的数据，先捞出来再写回去。
  Future<void> _applySettings(Map jsonData) async {
    final box = _storage.settingsBox;
    final preserved = <String, dynamic>{};
    for (final key in _ignoredSettingKeys) {
      if (box.containsKey(key)) {
        preserved[key] = box.get(key);
      }
    }

    await box.clear();
    box.putAll(jsonData);
    box.putAll(preserved);
  }
}
