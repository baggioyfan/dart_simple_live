import 'dart:async';

import 'package:flutter/material.dart';

import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/event_bus.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/app/tabs_ticker_provider.dart';
import 'package:simple_live_app/modules/category/category_list_controller.dart';

class CategoryController extends GetxController {
  static const TabsTickerProvider _tickerProvider = TabsTickerProvider();

  late TabController tabController;

  /// tab 结构版本号，含义同 HomeController.tabRevision
  final RxInt tabRevision = 0.obs;

  Worker? _tabWorker;

  CategoryController() {
    _buildTabs();
  }

  StreamSubscription<dynamic>? streamSubscription;

  @override
  void onInit() {
    streamSubscription = EventBus.instance.listen(
      EventBus.kBottomNavigationBarClicked,
      (index) {
        if (index == 2) {
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
      if (!Get.isRegistered<CategoryListController>(tag: site.id)) {
        Get.put(CategoryListController(site), tag: site.id);
      }
    }
  }

  /// 上一次构建 tab 时的站点顺序，用于开关变化后把选中位置落回原来那个平台
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
    // 等这一帧用新 controller 渲染完再收尾，identical 兜住连续切换的情况
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!identical(old, tabController)) {
        old.dispose();
      }
      // 旧 tab 此时已经移出控件树，销毁被隐藏站点的列表控制器才安全
      for (var id in hidden) {
        if (Get.isRegistered<CategoryListController>(tag: id)) {
          Get.delete<CategoryListController>(tag: id, force: true);
        }
      }
    });
  }

  void refreshOrScrollTop() {
    final sites = Sites.supportSites;
    if (sites.isEmpty) return;
    var tabIndex = tabController.index;
    if (tabIndex < 0 || tabIndex >= sites.length) return;
    BasePageController controller;
    controller = Get.find<CategoryListController>(tag: sites[tabIndex].id);
    controller.scrollToTopOrRefresh();
  }

  @override
  void onClose() {
    streamSubscription?.cancel();
    _tabWorker?.dispose();
    tabController.dispose();
    super.onClose();
  }
}
