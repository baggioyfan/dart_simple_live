import 'dart:async';

import 'package:flutter/material.dart';

import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/app/tabs_ticker_provider.dart';
import 'package:simple_live_app/modules/home/home_list_controller.dart';
import 'package:simple_live_app/routes/route_path.dart';

class HomeController extends GetxController {
  static const TabsTickerProvider _tickerProvider = TabsTickerProvider();

  late TabController tabController;

  /// tab 结构版本号
  ///
  /// TabController 的 length 在构造时就定死了，而渠道开关会改变 tab 数量，
  /// 所以只能整体重建。重建后自增这个值，页面据此重绘。
  final RxInt tabRevision = 0.obs;

  Worker? _tabWorker;

  HomeController() {
    _buildTabs();
  }

  StreamSubscription<dynamic>? streamSubscription;

  @override
  void onInit() {
    streamSubscription = EventBus.instance.listen(
      EventBus.kBottomNavigationBarClicked,
      (index) {
        if (index == 0) {
          refreshOrScrollTop();
        }
      },
    );
    // 任一渠道开关变化，tab 结构跟着重建
    _tabWorker = ever(
      AppSettingsController.instance.siteVisibilityRevision,
      (_) => _rebuildTabs(),
    );

    super.onInit();
  }

  /// 按当前设置构建 tab，并补齐各站点的列表控制器
  void _buildTabs() {
    final sites = Sites.supportSites;
    tabController = TabController(length: sites.length, vsync: _tickerProvider);
    _tabSiteIds = sites.map((e) => e.id).toList();

    for (var site in sites) {
      if (!Get.isRegistered<HomeListController>(tag: site.id)) {
        Get.put(HomeListController(site), tag: site.id);
      }
    }
  }

  /// 上一次构建 tab 时的站点顺序
  ///
  /// 开关变化后用它把选中位置落回原来那个平台，不然每次开关都会跳回第一个 tab。
  List<String> _tabSiteIds = [];

  /// 被开关关掉的站点 id（这些站点的列表控制器需要销毁）
  List<String> _hiddenSiteIds() {
    final sites = Sites.supportSites;
    return Sites.allSites.keys
        .where((id) => !sites.any((e) => e.id == id))
        .toList();
  }

  void _rebuildTabs() {
    final old = tabController;
    // 先把切换前停留的平台记下来，_buildTabs 会覆盖 _tabSiteIds
    final oldIndex = old.index;
    final focusedId = (oldIndex >= 0 && oldIndex < _tabSiteIds.length)
        ? _tabSiteIds[oldIndex]
        : null;
    final hidden = _hiddenSiteIds();
    _buildTabs();
    // 原来的平台还在就停在它上面；被关掉了就回到第一个
    final newIndex = focusedId == null ? 0 : _tabSiteIds.indexOf(focusedId);
    if (newIndex > 0) {
      tabController.index = newIndex;
    }
    tabRevision.value++;
    // 等这一帧用新 controller 渲染完再收尾，否则 TabBar / 列表控件会摸到已 dispose 的对象。
    // identical 判断兜住「连续切换两次」的情况，避免同一个 controller 被 dispose 两遍。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!identical(old, tabController)) {
        old.dispose();
      }
      // 旧 tab 此时已经移出控件树，销毁被隐藏站点的列表控制器才安全
      for (var id in hidden) {
        if (Get.isRegistered<HomeListController>(tag: id)) {
          Get.delete<HomeListController>(tag: id, force: true);
        }
      }
    });
  }

  void refreshOrScrollTop() {
    final sites = Sites.supportSites;
    if (sites.isEmpty) return;
    var tabIndex = tabController.index;
    // 开关刚切换时 index 可能还停在已消失的位置上，越界就放弃这次刷新
    if (tabIndex < 0 || tabIndex >= sites.length) return;
    BasePageController controller;
    controller = Get.find<HomeListController>(tag: sites[tabIndex].id);
    controller.scrollToTopOrRefresh();
  }

  void toSearch() {
    Get.toNamed(RoutePath.kSearch);
  }

  @override
  void onClose() {
    streamSubscription?.cancel();
    _tabWorker?.dispose();
    tabController.dispose();
    super.onClose();
  }
}
