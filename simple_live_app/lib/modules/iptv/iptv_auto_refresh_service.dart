import 'dart:async';

import 'package:get/get.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/modules/iptv/iptv_service.dart';
import 'package:simple_live_app/services/local_storage_service.dart';

/// IPTV 直播源自动更新
///
/// 赛事类频道会按日期滚动（体育-今天 / 昨天 / 明天），播放列表每天都不一样，
/// 所以不能只在导入时拉一次。这里做两件事：
/// 1. 启动后检查一次，把超过间隔没更新的源补上
/// 2. 之后按间隔周期性地刷新
class IptvAutoRefreshService extends GetxService {
  static IptvAutoRefreshService get instance =>
      Get.find<IptvAutoRefreshService>();

  static const int _defaultIntervalHours = 6;
  static const int _minIntervalHours = 1;

  Timer? _timer;
  final RxBool refreshing = false.obs;

  LocalStorageService get _storage => LocalStorageService.instance;

  bool get enabled => _storage.getValue(
        LocalStorageService.kIptvAutoRefreshEnable,
        true,
      );

  int get intervalHours {
    final value = _storage.getValue(
      LocalStorageService.kIptvAutoRefreshInterval,
      _defaultIntervalHours,
    );
    return value < _minIntervalHours ? _minIntervalHours : value;
  }

  Future init() async {
    // 延迟一点再跑，避免和首屏加载抢网络
    Future.delayed(const Duration(seconds: 8), _tick);
    initTimer();
  }

  void initTimer() {
    _timer?.cancel();
    if (!enabled) {
      Log.logPrint("IPTV 自动更新已关闭");
      return;
    }
    _timer = Timer.periodic(
      Duration(hours: intervalHours),
      (_) => _tick(),
    );
  }

  Future<void> setEnabled(bool value) async {
    await _storage.setValue(LocalStorageService.kIptvAutoRefreshEnable, value);
    initTimer();
  }

  Future<void> setIntervalHours(int hours) async {
    final value = hours < _minIntervalHours ? _minIntervalHours : hours;
    await _storage.setValue(
      LocalStorageService.kIptvAutoRefreshInterval,
      value,
    );
    initTimer();
  }

  /// 立即检查一次
  Future<int> refreshNow() => _tick();

  Future<int> _tick() async {
    if (!enabled || refreshing.value) return 0;
    refreshing.value = true;
    try {
      final count = await IptvService.instance.refreshIfStale(
        maxAge: Duration(hours: intervalHours),
      );
      if (count > 0) {
        Log.logPrint("IPTV 自动更新了 $count 个源");
      }
      return count;
    } catch (e) {
      Log.logPrint(e);
      return 0;
    } finally {
      refreshing.value = false;
    }
  }
}
