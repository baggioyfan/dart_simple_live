import 'package:flutter/material.dart';
import 'package:remixicon/remixicon.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/routes/app_navigation.dart';
import 'package:simple_live_app/widgets/net_image.dart';
import 'package:simple_live_app/widgets/shadow_card.dart';
import 'package:simple_live_core/simple_live_core.dart';

class LiveRoomCard extends StatelessWidget {
  final Site site;
  final LiveRoomItem item;
  const LiveRoomCard(this.site, this.item, {Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    // 自定义源的「封面」是台标，比例五花八门（16:9、4:3、1:1 都有），
    // 用 cover 会按卡片形状裁掉一部分，所以改成 contain 完整显示。
    // 其它平台是视频截图，本来就该铺满，保持 cover。
    final isIptv = site.id == Constant.kIptv;
    return ShadowCard(
      onTap: () {
        AppNavigator.toLiveRoomDetail(site: site, roomId: item.roomId);
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Stack(
            children: [
              ClipRRect(
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(8),
                  topRight: Radius.circular(8),
                ),
                child: NetImage(
                  item.cover,
                  fit: isIptv ? BoxFit.contain : BoxFit.cover,
                  height: 110,
                  width: double.infinity,
                  // 自定义源的台标是各种自建图床，不少会按 UA 拦非浏览器请求
                  headers: isIptv ? NetImage.iptvHeaders : null,
                ),
              ),
              Positioned(
                right: 0,
                left: 0,
                bottom: 0,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 8,
                  ),
                  decoration: const BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.bottomCenter,
                      end: Alignment.topCenter,
                      colors: [
                        Colors.black87,
                        Colors.transparent,
                      ],
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      const Icon(
                        Remix.fire_fill,
                        color: Colors.white,
                        size: 14,
                      ),
                      AppStyle.hGap4,
                      Text(
                        Utils.onlineToString(item.online),
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.white,
                        ),
                      )
                    ],
                  ),
                ),
              ),
            ],
          ),
          Padding(
            padding: AppStyle.edgeInsetsA8.copyWith(bottom: 4),
            child: Text(
              item.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Padding(
            padding: AppStyle.edgeInsetsH8.copyWith(bottom: 8),
            child: Text(
              item.userName,
              maxLines: 1,
              style: const TextStyle(
                  height: 1.4, fontSize: 12, color: Colors.grey),
            ),
          )
        ],
      ),
    );
  }
}
