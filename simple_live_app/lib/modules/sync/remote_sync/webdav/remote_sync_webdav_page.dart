import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:remixicon/remixicon.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/modules/sync/remote_sync/webdav/remote_sync_webdav_controller.dart';
import 'package:simple_live_app/routes/route_path.dart';
import 'package:simple_live_app/services/webdav_sync_service.dart';
import 'package:simple_live_app/widgets/settings/settings_card.dart';

class RemoteSyncWebDAVPage extends GetView<RemoteSyncWebDAVController> {
  const RemoteSyncWebDAVPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("WebDAV同步"),
      ),
      body: Obx(() {
        final logged = !controller.notLogin.value;
        return ListView(
          padding: AppStyle.edgeInsetsA12,
          children: [
            SettingsCard(
              child: Column(
                children: logged
                    ? [
                        ListTile(
                          title: const Text("已登录"),
                          leading: const Icon(Icons.cloud_circle_outlined),
                          subtitle: Text(controller.user.value),
                          trailing: const Icon(Icons.logout),
                          onTap: () {
                            controller.onLogout();
                          },
                        ),
                        AppStyle.divider,
                        ListTile(
                          title: const Text("上传到云端"),
                          subtitle: Text("上次上传：${controller.lastUploadTime.value}"),
                          leading: const Icon(Icons.cloud_upload_outlined),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () {
                            controller.doWebDAVUpload();
                          },
                        ),
                        AppStyle.divider,
                        ListTile(
                          title: const Text("恢复到本地"),
                          subtitle:
                              Text("上次恢复：${controller.lastRecoverTime.value}"),
                          leading: const Icon(Icons.cloud_download_outlined),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.settings),
                                onPressed: showSetting,
                              ),
                              const Icon(Icons.chevron_right),
                            ],
                          ),
                          onTap: () {
                            controller.doWebDAVRecovery();
                          },
                          onLongPress: showSetting,
                        ),
                      ]
                    : [
                        ListTile(
                          title: const Text("点击登录"),
                          leading: const Icon(Icons.login),
                          subtitle: const Text("登录后可以同步您的所有数据"),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: () {
                            Get.toNamed(RoutePath.kRemoteSyncWebDavConfig);
                          },
                        ),
                      ],
              ),
            ),
            if (logged) ...[
              AppStyle.vGap12,
              SettingsCard(child: _autoSyncSection()),
            ],
          ],
        );
      }),
    );
  }

  /// 自动同步设置
  ///
  /// 手动点上传/恢复的问题在于：改完设置或者点了关注，另一台设备不点一下就
  /// 不会变。这里给两个开关，分别控制「改了就传」和「云端新了就拉」。
  Widget _autoSyncSection() {
    final service = WebDavSyncService.instance;
    return Column(
      children: [
        SwitchListTile(
          value: controller.autoUpload.value,
          dense: true,
          secondary: const Icon(Remix.upload_cloud_2_line),
          title: const Text("自动上传", style: TextStyle(fontSize: 15)),
          subtitle: const Text(
            "关注、标签、历史、直播源、设置改动后自动上传",
            style: TextStyle(fontSize: 11),
          ),
          onChanged: controller.changeAutoUpload,
        ),
        AppStyle.divider,
        SwitchListTile(
          value: controller.autoDownload.value,
          dense: true,
          secondary: const Icon(Remix.download_cloud_2_line),
          title: const Text("自动下载", style: TextStyle(fontSize: 15)),
          subtitle: const Text(
            "启动、回到前台和定时检查，云端有新数据时自动恢复",
            style: TextStyle(fontSize: 11),
          ),
          onChanged: controller.changeAutoDownload,
        ),
        if (controller.autoDownload.value) ...[
          AppStyle.divider,
          ListTile(
            dense: true,
            leading: const Icon(Remix.time_line),
            title: const Text("检查间隔", style: TextStyle(fontSize: 15)),
            trailing: DropdownButton<int>(
              value: WebDavSyncService.checkIntervalOptions
                      .contains(controller.checkInterval.value)
                  ? controller.checkInterval.value
                  : WebDavSyncService.defaultCheckInterval,
              underline: const SizedBox(),
              items: [
                for (final minutes in WebDavSyncService.checkIntervalOptions)
                  DropdownMenuItem(
                    value: minutes,
                    child: Text(
                      minutes < 60 ? "$minutes 分钟" : "${minutes ~/ 60} 小时",
                      style: const TextStyle(fontSize: 14),
                    ),
                  ),
              ],
              onChanged: (value) {
                if (value != null) {
                  controller.changeCheckInterval(value);
                }
              },
            ),
          ),
        ],
        AppStyle.divider,
        ListTile(
          dense: true,
          leading: const Icon(Remix.refresh_line),
          title: const Text("立即检查云端", style: TextStyle(fontSize: 15)),
          subtitle: const Text(
            "手动触发一次「云端有更新就拉下来」",
            style: TextStyle(fontSize: 11),
          ),
          trailing: controller.syncing.value
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.chevron_right, size: 20),
          onTap: controller.syncing.value
              ? null
              : () => controller.checkRemoteNow(),
        ),
        if (service.status.value.isNotEmpty) ...[
          AppStyle.divider,
          ListTile(
            dense: true,
            leading: const Icon(Remix.information_line, size: 20),
            title: Text(
              service.status.value,
              style: const TextStyle(fontSize: 12),
            ),
          ),
        ],
      ],
    );
  }

  void showSetting() {
    Utils.showBottomSheet(
      title: '同步选项',
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          AppStyle.divider,
          Obx(
            () => CheckboxListTile(
              secondary: const Icon(Remix.heart_line),
              title: const Text("同步关注列表"),
              value: controller.isSyncFollows.value,
              controlAffinity: ListTileControlAffinity.trailing,
              onChanged: (value) => controller.changeIsSyncFollows(),
            ),
          ),
          AppStyle.divider,
          Obx(
            () => CheckboxListTile(
              secondary: const Icon(Icons.history),
              title: const Text("同步播放历史记录"),
              value: controller.isSyncHistories.value,
              controlAffinity: ListTileControlAffinity.trailing,
              onChanged: (value) => controller.changeIsSyncHistories(),
            ),
          ),
          AppStyle.divider,
          Obx(
            () => CheckboxListTile(
              secondary: const Icon(Remix.shield_keyhole_line),
              title: const Text("同步屏蔽字"),
              value: controller.isSyncBlockWord.value,
              controlAffinity: ListTileControlAffinity.trailing,
              onChanged: (value) => controller.changeIsSyncBlockWord(),
            ),
          ),
          AppStyle.divider,
          Obx(
            () => CheckboxListTile(
              secondary: const Icon(Remix.account_circle_line),
              title: const Text("同步哔哩哔哩账号"),
              value: controller.isSyncBilibiliAccount.value,
              controlAffinity: ListTileControlAffinity.trailing,
              onChanged: (value) => controller.changeIsSyncBilibiliAccount(),
            ),
          ),
          AppStyle.divider,
          Obx(
            () => CheckboxListTile(
              secondary: const Icon(Icons.live_tv),
              title: const Text("同步自定义直播源"),
              value: controller.isSyncIptv.value,
              controlAffinity: ListTileControlAffinity.trailing,
              onChanged: (value) => controller.changeIsSyncIptv(),
            ),
          ),
          AppStyle.divider,
        ],
      ),
    );
  }
}
