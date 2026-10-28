import 'package:get/get.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/modules/category/category_list_controller.dart';
import 'package:simple_live_app/modules/home/home_list_controller.dart';

/// 让首页 / 分类页的「自定义源」tab 重新拉一次数据
///
/// 这两个页面都是懒建的，只在第一次切过去时 `firstRefresh` 一次，之后再切回来
/// 不会重新请求 —— `IndexedController.setIndex` 只在重复点击**当前** tab 时
/// 才发刷新事件。所以频道数据一变就必须主动通知，否则会一直停在旧列表上。
class IptvTabRefresher {
  static void refreshAll() {
    _refresh<CategoryListController>();
    _refresh<HomeListController>();
  }

  static void _refresh<T extends BasePageController>({int attempt = 0}) {
    if (!Get.isRegistered<T>(tag: Constant.kIptv)) {
      // 页面还没被打开过，下次打开会自己加载，不用管
      return;
    }
    final controller = Get.find<T>(tag: Constant.kIptv);
    // refreshData 会先清空 list；如果正好有请求在飞，loadData 会被 loadding
    // 挡住直接返回，结果就是页面被清空且不再加载 —— 等一下再试。
    if (controller.loadding && attempt < 5) {
      Future.delayed(
        const Duration(milliseconds: 300),
        () => _refresh<T>(attempt: attempt + 1),
      );
      return;
    }
    controller.refreshData();
  }
}
