import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/category/category_controller.dart';
import 'package:simple_live_app/modules/category/category_list_view.dart';

class CategoryPage extends GetView<CategoryController> {
  const CategoryPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    // 依赖 tabRevision：自定义源开关切换后 tab 数量会变，这里跟着整体重建
    return Obx(() {
      final revision = controller.tabRevision.value;
      final sites = Sites.supportSites;
      return Scaffold(
        appBar: AppBar(
          titleSpacing: 8,
          // 同首页：不设 centerTitle 时 iOS / macOS 会把 TabBar 收窄成内容宽度，
          // 站点一多就滑不动。
          centerTitle: false,
          title: TabBar(
            key: ValueKey("categoryTabBar$revision"),
            controller: controller.tabController,
            padding: EdgeInsets.zero,
            tabs: sites
                .map(
                  (e) => Tab(
                    child: Row(
                      children: [
                        Image.asset(
                          e.logo,
                          width: 24,
                        ),
                        AppStyle.hGap8,
                        Text(e.name),
                      ],
                    ),
                  ),
                )
                .toList(),
            labelPadding: AppStyle.edgeInsetsH20,
            isScrollable: true,
            indicatorSize: TabBarIndicatorSize.label,
          ),
        ),
        body: TabBarView(
          key: ValueKey("categoryTabView$revision"),
          controller: controller.tabController,
          children: sites
              .map(
                (e) => CategoryListView(
                  e.id,
                ),
              )
              .toList(),
        ),
      );
    });
  }
}
