import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/settings/indexed_settings/indexed_settings_controller.dart';
import 'package:simple_live_app/widgets/settings/settings_card.dart';

class IndexedSettingsPage extends GetView<IndexedSettingsController> {
  const IndexedSettingsPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("主页设置"),
      ),
      body: ListView(
        padding: AppStyle.edgeInsetsA12,
        children: [
          Padding(
            padding: AppStyle.edgeInsetsA12.copyWith(top: 0),
            child: Text(
              "主页排序 (长按拖动排序，重启后生效)",
              style: Get.textTheme.titleSmall,
            ),
          ),
          SettingsCard(
            child: Obx(
              () => ReorderableListView(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                onReorder: controller.updateHomeSort,
                children: controller.homeSort.map(
                  (key) {
                    var e = Constant.allHomePages[key]!;
                    return ListTile(
                      key: ValueKey(e.title),
                      title: Text(e.title),
                      visualDensity: VisualDensity.compact,
                      leading: Icon(e.iconData),
                      trailing: const Icon(Icons.drag_handle),
                    );
                  },
                ).toList(),
              ),
            ),
          ),
          Padding(
            padding: AppStyle.edgeInsetsA12.copyWith(top: 24),
            child: Text(
              "平台显示与排序",
              style: Get.textTheme.titleSmall,
            ),
          ),
          Padding(
            padding: AppStyle.edgeInsetsH12,
            child: Text(
              "关掉开关后，该平台不再出现在主页、分类页与搜索页；"
              "登录状态和关注列表都会保留，随时可以再打开。"
              "长按可拖动排序，重启后生效。",
              style: Get.textTheme.bodySmall?.copyWith(
                color: Get.textTheme.bodySmall?.color?.withAlpha(140),
              ),
            ),
          ),
          AppStyle.vGap8,
          SettingsCard(
            child: Obx(() {
              // 读一下版本号：任何一个渠道的开关变化都会让整段重建
              final revision = controller.visibilityRevision;
              return ReorderableListView(
                key: ValueKey("siteSort$revision"),
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                onReorder: controller.updateSiteSort,
                children: controller.siteSort.map(
                  (key) {
                    var e = Sites.allSites[key]!;
                    final visible = controller.isSiteVisible(e.id);
                    return ListTile(
                      key: ValueKey(e.id),
                      visualDensity: VisualDensity.compact,
                      enabled: visible,
                      title: Text(e.name),
                      leading: Opacity(
                        opacity: visible ? 1 : 0.35,
                        child: Image.asset(
                          e.logo,
                          width: 24,
                          height: 24,
                        ),
                      ),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Switch(
                            value: visible,
                            onChanged: (v) =>
                                controller.setSiteVisible(e.id, v),
                          ),
                          const Icon(Icons.drag_handle),
                        ],
                      ),
                    );
                  },
                ).toList(),
              );
            }),
          ),
        ],
      ),
    );
  }
}
