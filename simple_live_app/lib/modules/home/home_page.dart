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
          title: TabBar(
            key: ValueKey("homeTabBar$revision"),
            controller: controller.tabController,
            labelPadding: AppStyle.edgeInsetsH20,
            isScrollable: true,
            indicatorSize: TabBarIndicatorSize.label,
            tabAlignment: TabAlignment.center,
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
