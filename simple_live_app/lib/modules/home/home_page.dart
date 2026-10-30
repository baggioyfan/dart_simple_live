import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/home/home_controller.dart';
import 'package:simple_live_app/modules/home/home_list_view.dart';

class HomePage extends GetView<HomeController> {
  const HomePage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    // 依赖 tabRevision：自定义源开关切换后 tab 数量会变，这里跟着整体重建
    return Obx(() {
      final revision = controller.tabRevision.value;
      final sites = Sites.supportSites;
      return Scaffold(
        appBar: AppBar(
          titleSpacing: 8,
          // iOS / macOS 下 centerTitle 默认为 true，会把 title 里的 TabBar
          // 收窄成内容宽度，isScrollable 随之失效：站点多了只会溢出屏幕，
          // 滑不动也点不到后面的站。
          centerTitle: false,
          title: TabBar(
            key: ValueKey("homeTabBar$revision"),
            controller: controller.tabController,
            labelPadding: AppStyle.edgeInsetsH20,
            isScrollable: true,
            indicatorSize: TabBarIndicatorSize.label,
            // 不用 TabAlignment.center：可滚动时它按视口宽度居中锚定，
            // 内容超宽后两端滚不到位。
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
          ),
          actions: [
            IconButton(
              onPressed: controller.toSearch,
              icon: const Icon(Icons.search),
            )
          ],
        ),
        body: TabBarView(
          key: ValueKey("homeTabView$revision"),
          controller: controller.tabController,
          children: sites
              .map(
                (e) => HomeListView(
                  e.id,
                ),
              )
              .toList(),
        ),
      );
    });
  }
}
