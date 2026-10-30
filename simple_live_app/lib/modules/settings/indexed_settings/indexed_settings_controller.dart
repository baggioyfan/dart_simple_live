import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';

class IndexedSettingsController extends GetxController {
  RxList<String> siteSort = RxList<String>();
  RxList<String> homeSort = RxList<String>();
  @override
  void onInit() {
    siteSort = AppSettingsController.instance.siteSort;
    homeSort = AppSettingsController.instance.homeSort;
    super.onInit();
  }

  void updateSiteSort(int oldIndex, int newIndex) {
    if (oldIndex < newIndex) {
      newIndex -= 1;
    }
    final String item = siteSort.removeAt(oldIndex);
    siteSort.insert(newIndex, item);
    // ignore: invalid_use_of_protected_member
    AppSettingsController.instance.setSiteSort(siteSort.value);
  }

  void updateHomeSort(int oldIndex, int newIndex) {
    if (oldIndex < newIndex) {
      newIndex -= 1;
    }
    final String item = homeSort.removeAt(oldIndex);
    homeSort.insert(newIndex, item);
    // ignore: invalid_use_of_protected_member
    AppSettingsController.instance.setHomeSort(homeSort.value);
  }

  /// 某个渠道当前是否显示（在 Obx 里调用才会跟随开关刷新）
  bool isSiteVisible(String id) =>
      AppSettingsController.instance.isSiteVisible(id);

  /// 渠道开关版本号，在 `Obx` 里读一下就能保证开关变化后界面重建
  int get visibilityRevision =>
      AppSettingsController.instance.siteVisibilityRevision.value;

  /// 切换渠道显示开关
  ///
  /// 拒绝的情况只有一种：这是最后一个还开着的渠道，全部关掉首页就没 tab 了。
  void setSiteVisible(String id, bool visible) {
    final ok = AppSettingsController.instance.setSiteVisible(id, visible);
    if (!ok) {
      SmartDialog.showToast("至少保留一个平台");
    }
  }
}
