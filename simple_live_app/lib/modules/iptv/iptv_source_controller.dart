import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/modules/iptv/iptv_auto_refresh_service.dart';
import 'package:simple_live_app/modules/iptv/iptv_probe.dart';
import 'package:simple_live_app/modules/iptv/iptv_service.dart';
import 'package:simple_live_app/modules/iptv/iptv_tab_refresher.dart';
import 'package:simple_live_app/modules/iptv/models/iptv_channel.dart';
import 'package:simple_live_app/modules/iptv/models/iptv_source.dart';
import 'package:simple_live_app/modules/iptv/models/iptv_source_health.dart';

class IptvSourceController extends GetxController {
  IptvService get _service => IptvService.instance;

  IptvAutoRefreshService get _autoRefresh => IptvAutoRefreshService.instance;

  final RxList<IptvSource> sources = <IptvSource>[].obs;
  final RxBool busy = false.obs;

  /// 每个源的采样可用性，key 是源 id
  final RxMap<String, IptvSourceHealth> health =
      <String, IptvSourceHealth>{}.obs;

  /// 正在跑可用性检测
  final RxBool probing = false.obs;

  /// 定期更新开关与间隔，镜像自 [IptvAutoRefreshService]，供界面响应式绑定
  final RxBool autoRefreshEnabled = true.obs;
  final RxInt autoRefreshHours = 6.obs;

  /// 可选间隔（小时）
  static const List<int> intervalOptions = [1, 3, 6, 12, 24];

  /// 「自定义源」这个渠道当前是否显示
  ///
  /// 和其他平台共用同一份开关配置（`AppSettingsController.hiddenSiteIds`），
  /// 这里只是把状态镜像成可以绑定的形式。真正的隐藏动作由
  /// `Sites.supportSites` 过滤 + 首页 / 分类页重建 tab 完成。
  final RxBool tabVisible = true.obs;

  @override
  void onInit() {
    super.onInit();
    reload();
    reloadAutoRefresh();
    reloadTabVisible();
  }

  void reload() {
    sources.value = _service.getSources();
  }

  /// 通知首页 / 分类页的自定义源 tab 重新拉一次数据
  void _reloadLiveTabs() => IptvTabRefresher.refreshAll();

  void reloadAutoRefresh() {
    autoRefreshEnabled.value = _autoRefresh.enabled;
    autoRefreshHours.value = _autoRefresh.intervalHours;
  }

  void reloadTabVisible() {
    tabVisible.value =
        AppSettingsController.instance.isSiteVisible(Constant.kIptv);
  }

  /// 切换「在首页与分类页显示」
  ///
  /// 写的是全局渠道开关，和「主页设置 → 平台显示与排序」里那一排开关是同一个值，
  /// 两边永远同步。
  void setTabVisible(bool value) {
    final ok = AppSettingsController.instance
        .setSiteVisible(Constant.kIptv, value);
    if (!ok) {
      SmartDialog.showToast("至少保留一个平台");
      reloadTabVisible();
      return;
    }
    tabVisible.value = value;
    // 重新挂回来时 tab 是新建的，顺手把频道数据也刷一遍
    if (value) _reloadLiveTabs();
  }

  /// 导入新源，成功返回 true
  Future<bool> importSource({required String url, String name = ''}) async {
    if (busy.value) return false;
    busy.value = true;
    SmartDialog.showLoading(msg: "正在拉取播放列表");
    try {
      final source = await _service.importFromUrl(url: url, name: name);
      reload();
      _reloadLiveTabs();
      SmartDialog.showToast("导入成功，${source.channelCount} 个频道");
      return true;
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("导入失败：${_message(e)}");
      return false;
    } finally {
      SmartDialog.dismiss(status: SmartStatus.loading);
      busy.value = false;
    }
  }

  Future<void> refreshSource(IptvSource source) async {
    if (busy.value) return;
    busy.value = true;
    SmartDialog.showLoading(msg: "正在刷新");
    try {
      final merged = await _service.refreshSource(source.id);
      reload();
      // 频道换了，旧的可用性结果作废
      health.remove(source.id);
      _reloadLiveTabs();
      final count = _service.getChannels(source.id).length;
      SmartDialog.showToast(
        merged > 0
            ? "已更新 $count 个频道（合并 $merged 条重复线路）"
            : "已更新 $count 个频道",
      );
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("刷新失败：${_message(e)}");
    } finally {
      SmartDialog.dismiss(status: SmartStatus.loading);
      busy.value = false;
    }
  }

  Future<void> toggleEnabled(IptvSource source) async {
    source.enabled = !source.enabled;
    await _service.updateSource(source);
    reload();
    _reloadLiveTabs();
  }

  /// 修改源名称
  ///
  /// 分类页一级标题就是源名，改完要通知首页/分类页重建 tab。
  Future<void> rename(IptvSource source, String name) async {
    final value = name.trim();
    if (value.isEmpty) return;
    source.name = value;
    await _service.updateSource(source);
    reload();
    _reloadLiveTabs();
  }

  /// 修改播放列表地址
  ///
  /// 地址变了必须重新拉一次播放列表，否则频道还是旧地址下的。
  /// 新地址拉不动就回滚 —— 不然源会停在「地址是新的、频道是旧的」这种
  /// 半坏状态，用户看着像是更新成功了其实什么都没变。
  ///
  /// 返回是否真的换了地址。
  Future<bool> updateSourceUrl(IptvSource source, String url) async {
    if (busy.value) return false;
    final newUrl = url.trim();
    if (newUrl.isEmpty) {
      SmartDialog.showToast("请填写播放列表地址");
      return false;
    }

    final oldUrl = source.url;
    if (newUrl == oldUrl.trim()) return false;

    source.url = newUrl;
    await _service.updateSource(source);
    reload();

    busy.value = true;
    SmartDialog.showLoading(msg: "正在拉取新的播放列表");
    try {
      final merged = await _service.refreshSource(source.id);
      reload();
      health.remove(source.id);
      _reloadLiveTabs();
      final count = _service.getChannels(source.id).length;
      SmartDialog.showToast(
        merged > 0
            ? "地址已更新，$count 个频道（合并 $merged 条重复线路）"
            : "地址已更新，$count 个频道",
      );
      return true;
    } catch (e) {
      Log.logPrint(e);
      source.url = oldUrl;
      await _service.updateSource(source);
      reload();
      SmartDialog.showToast("新地址不可用：${_message(e)}");
      return false;
    } finally {
      SmartDialog.dismiss(status: SmartStatus.loading);
      busy.value = false;
    }
  }

  /// 修改源的名称和地址（同一个入口）
  ///
  /// 先改地址再改名：地址那步可能失败，失败就整体不动，避免出现
  /// 「名字改了、地址还是旧的」这种半截状态。
  Future<void> editSource(
    IptvSource source, {
    required String url,
    required String name,
  }) async {
    if (busy.value) return;

    final newUrl = url.trim();
    final newName = name.trim();
    if (newUrl.isEmpty) {
      SmartDialog.showToast("请填写播放列表地址");
      return;
    }

    final urlChanged = newUrl != source.url.trim();
    final nameChanged = newName.isNotEmpty && newName != source.name;

    if (!urlChanged && !nameChanged) {
      SmartDialog.showToast("没有变化");
      return;
    }

    if (urlChanged) {
      final ok = await updateSourceUrl(source, newUrl);
      if (!ok) return;
    }
    if (nameChanged) {
      await rename(source, newName);
    }
  }

  Future<void> remove(IptvSource source) async {
    await _service.deleteSource(source.id);
    health.remove(source.id);
    reload();
    _reloadLiveTabs();
    SmartDialog.showToast("已删除");
  }

  // ---------------- 定期更新 ----------------

  Future<void> setAutoRefreshEnabled(bool value) async {
    await _autoRefresh.setEnabled(value);
    reloadAutoRefresh();
  }

  Future<void> setAutoRefreshInterval(int hours) async {
    await _autoRefresh.setIntervalHours(hours);
    reloadAutoRefresh();
  }

  /// 立即把所有源重拉一遍
  Future<void> refreshAllNow() async {
    if (busy.value) return;
    if (sources.isEmpty) {
      SmartDialog.showToast("还没有直播源");
      return;
    }
    busy.value = true;
    SmartDialog.showLoading(msg: "正在更新全部直播源");
    try {
      await _service.refreshAll();
      reload();
      // 所有源都重拉过，可用性结果全部作废
      health.clear();
      _reloadLiveTabs();
      SmartDialog.showToast("已更新 ${sources.length} 个源");
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("更新失败：${_message(e)}");
    } finally {
      SmartDialog.dismiss(status: SmartStatus.loading);
      busy.value = false;
    }
  }

  // ---------------- 可用性检测 ----------------

  /// 每个源探几个频道当样本
  ///
  /// 探得太少没有代表性，探得太多既慢又容易被源站当爬虫。
  /// 3 个样本足够区分「全通 / 部分通 / 全挂」这三种情况。
  static const int sampleSize = 3;

  /// 检测一个源的可用性
  ///
  /// [silent] 为 true 时不弹 loading、不弹结果 —— 批量检测时由外层统一处理，
  /// 否则每个源都要闪一次弹窗。
  Future<void> probeSource(IptvSource source, {bool silent = false}) async {
    if (!silent) SmartDialog.showLoading(msg: "正在检测线路");
    try {
      final channels = _service.getChannels(source.id);
      if (channels.isEmpty) {
        health[source.id] = const IptvSourceHealth(alive: 0, total: 0);
        return;
      }
      final samples = _sampleChannels(channels);
      final results = await IptvProbe.probeAll(
        [for (final channel in samples) channel.streamUrl],
      );
      health[source.id] = IptvSourceHealth(
        alive: results.where((alive) => alive).length,
        total: results.length,
      );
    } catch (e) {
      // 单个源探挂了不该让整批检测中断
      Log.logPrint(e);
    } finally {
      if (!silent) {
        SmartDialog.dismiss(status: SmartStatus.loading);
        SmartDialog.showToast(
          "「${source.name}」${health[source.id]?.text ?? "检测失败"}",
        );
      }
    }
  }

  /// 检测全部源
  ///
  /// 串行跑，不并发 —— 几个源同时铺开探测会把家里的带宽打满，
  /// 本来能用的源反而被探成不可用。
  Future<void> probeAllSources() async {
    if (probing.value || sources.isEmpty) return;
    probing.value = true;
    SmartDialog.showLoading(msg: "正在检测线路");
    try {
      for (final source in sources) {
        await probeSource(source, silent: true);
      }
      final dead = sources
          .where((source) => health[source.id]?.allDead ?? false)
          .length;
      SmartDialog.showToast(
        dead > 0 ? "检测完成，$dead 个源完全不可用" : "检测完成，全部源都有响应",
      );
    } finally {
      SmartDialog.dismiss(status: SmartStatus.loading);
      probing.value = false;
    }
  }

  /// 均匀取几个频道
  ///
  /// 不取开头那几个：不少源的前几个台是专门留着测试的，永远是好的，
  /// 拿它们当样本会高估整个源的健康度。
  List<IptvChannel> _sampleChannels(List<IptvChannel> channels) {
    if (channels.length <= sampleSize) return channels;
    final step = channels.length / sampleSize;
    return [
      for (var i = 0; i < sampleSize; i++) channels[(i * step).floor()],
    ];
  }

  String _message(Object e) {
    final text = e.toString();
    return text.startsWith('Exception: ') ? text.substring(11) : text;
  }
}
