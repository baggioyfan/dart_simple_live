import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/modules/iptv/iptv_service.dart';
import 'package:simple_live_app/modules/iptv/models/iptv_source.dart';

class IptvSourceController extends GetxController {
  IptvService get _service => IptvService.instance;

  final RxList<IptvSource> sources = <IptvSource>[].obs;
  final RxBool busy = false.obs;

  @override
  void onInit() {
    super.onInit();
    reload();
  }

  void reload() {
    sources.value = _service.getSources();
  }

  /// 导入新源，成功返回 true
  Future<bool> importSource({required String url, String name = ''}) async {
    if (busy.value) return false;
    busy.value = true;
    SmartDialog.showLoading(msg: "正在拉取播放列表");
    try {
      await _service.importFromUrl(url: url, name: name);
      reload();
      SmartDialog.showToast("导入成功");
      return true;
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("导入失败：${_message(e)}");
      return false;
    } finally {
      SmartDialog.dismiss(status: SmartStatus.loading);
      busy.value = false;
    }
  }

  Future<void> refreshSource(IptvSource source) async {
    if (busy.value) return;
    busy.value = true;
    SmartDialog.showLoading(msg: "正在刷新");
    try {
      await _service.refreshSource(source.id);
      reload();
      SmartDialog.showToast("已更新 ${_service.getChannels(source.id).length} 个频道");
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("刷新失败：${_message(e)}");
    } finally {
      SmartDialog.dismiss(status: SmartStatus.loading);
      busy.value = false;
    }
  }

  Future<void> toggleEnabled(IptvSource source) async {
    source.enabled = !source.enabled;
    await _service.updateSource(source);
    reload();
  }

  Future<void> rename(IptvSource source, String name) async {
    final value = name.trim();
    if (value.isEmpty) return;
    source.name = value;
    await _service.updateSource(source);
    reload();
  }

  Future<void> remove(IptvSource source) async {
    await _service.deleteSource(source.id);
    reload();
    SmartDialog.showToast("已删除");
  }

  String _message(Object e) {
    final text = e.toString();
    return text.startsWith('Exception: ') ? text.substring(11) : text;
  }
}
