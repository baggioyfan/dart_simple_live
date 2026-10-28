import 'dart:async';

import 'package:simple_live_app/app/constant.dart';
import 'package:simple_live_app/modules/iptv/iptv_service.dart';
import 'package:simple_live_app/modules/iptv/models/iptv_channel.dart';
import 'package:simple_live_app/modules/iptv/parsers/xmltv_parser.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// IPTV 自定义直播源站点适配
///
/// 把本地存的 m3u 频道包装成 core 认识的 [LiveSite]：
/// - 一级分类 = 源（一个播放列表）
/// - 二级分类 = 该源内的 group-title 分组
/// - 房间 = 频道，播放地址直接交给播放器（media_kit/libmpv 能吃 m3u8）
class IptvSite extends LiveSite {
  IptvSite() {
    // 直接赋值而不是用字段覆盖，避免 overridden_fields 提示
    id = Constant.kIptv;
    name = "自定义源";
  }

  IptvService get _service => IptvService.instance;

  @override
  Future<List<LiveCategory>> getCategores() async {
    final result = <LiveCategory>[];
    for (final source in _service.getEnabledSources()) {
      final groups = _service.getGroups(source.id);
      if (groups.isEmpty) continue;
      result.add(
        LiveCategory(
          id: source.id,
          name: source.name,
          children: [
            for (final group in groups)
              LiveSubCategory(
                id: _subCategoryId(source.id, group),
                name: group,
                parentId: source.id,
              ),
          ],
        ),
      );
    }
    return result;
  }

  @override
  Future<LiveCategoryResult> getCategoryRooms(
    LiveSubCategory category, {
    int page = 1,
  }) async {
    // 频道一次性全取，没有分页
    if (page > 1) {
      return LiveCategoryResult(hasMore: false, items: <LiveRoomItem>[]);
    }
    final parsed = _parseSubCategoryId(category.id);
    if (parsed == null) {
      return LiveCategoryResult(hasMore: false, items: <LiveRoomItem>[]);
    }
    final channels = _service.getChannelsByGroup(parsed.$1, parsed.$2);

    // 节目单在后台预热，不阻塞列表；已经有缓存就直接拿来当副标题
    unawaited(_service.loadEpg(parsed.$1));
    final guide = _service.cachedEpg(parsed.$1);
    final now = DateTime.now();

    return LiveCategoryResult(
      hasMore: false,
      items: channels
          .map((e) => _toRoomItem(e, guide?.currentAt(e.tvgId, now)))
          .toList(),
    );
  }

  @override
  Future<LiveCategoryResult> getRecommendRooms({int page = 1}) async {
    // 父类默认返回空列表，不重写的话首页的「自定义源」tab 永远是空白。
    // 这里把所有启用源的频道按「分组顺序 + 组内顺序」摊平，顺序与分类页一致。
    final channels = <IptvChannel>[];
    for (final source in _service.getEnabledSources()) {
      for (final group in _service.getGroups(source.id)) {
        channels.addAll(_service.getChannelsByGroup(source.id, group));
      }
    }

    const pageSize = 60;
    final start = (page - 1) * pageSize;
    if (start >= channels.length) {
      return LiveCategoryResult(hasMore: false, items: <LiveRoomItem>[]);
    }
    final end = start + pageSize;
    final slice = channels.sublist(
      start,
      end > channels.length ? channels.length : end,
    );
    return LiveCategoryResult(
      hasMore: end < channels.length,
      items: slice.map((e) => _toRoomItem(e)).toList(),
    );
  }

  @override
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) async {
    final channel = _service.getChannel(roomId);
    if (channel == null) {
      return LiveRoomDetail(
        roomId: roomId,
        title: '',
        cover: '',
        userName: '',
        userAvatar: '',
        online: 0,
        status: false,
        url: '',
      );
    }
    return LiveRoomDetail(
      roomId: channel.id,
      title: channel.name,
      cover: channel.logo,
      userName: channel.groupTitle,
      userAvatar: channel.logo,
      online: 0,
      status: true,
      url: channel.streamUrl,
      // 播放地址就是频道里存的那一条，直接透传
      data: channel,
    );
  }

  @override
  Future<List<LivePlayQuality>> getPlayQualites(
      {required LiveRoomDetail detail}) async {
    final url = detail.url.trim();
    if (url.isEmpty) return <LivePlayQuality>[];
    // 自定义源没有多清晰度，只给一个默认档
    return [
      LivePlayQuality(quality: "默认", data: url, sort: 0),
    ];
  }

  @override
  Future<LivePlayUrl> getPlayUrls({
    required LiveRoomDetail detail,
    required LivePlayQuality quality,
  }) async {
    final data = quality.data;
    final url = data is String && data.trim().isNotEmpty
        ? data.trim()
        : detail.url.trim();
    if (url.isEmpty) {
      return LivePlayUrl(urls: <String>[]);
    }
    // headers 暂时留空：当前源没有 #EXTVLCOPT，需要时在这里返回
    return LivePlayUrl(urls: [url]);
  }

  @override
  Future<bool> getLiveStatus({required String roomId}) async {
    // 自定义源无法探测，一律当作可播
    return true;
  }

  @override
  Future<LiveSearchRoomResult> searchRooms(String keyword, {int page = 1}) async {
    final key = keyword.trim().toLowerCase();
    if (key.isEmpty || page > 1) {
      return LiveSearchRoomResult(hasMore: false, items: <LiveRoomItem>[]);
    }
    final items = <LiveRoomItem>[];
    for (final source in _service.getEnabledSources()) {
      for (final channel in _service.getChannels(source.id)) {
        if (channel.name.toLowerCase().contains(key)) {
          items.add(_toRoomItem(channel));
        }
      }
    }
    return LiveSearchRoomResult(hasMore: false, items: items);
  }

  LiveRoomItem _toRoomItem(IptvChannel channel, [EpgProgramme? current]) {
    return LiveRoomItem(
      roomId: channel.id,
      title: channel.name,
      cover: channel.logo,
      // 有节目单时副标题显示正在播的节目，否则退回分组名
      userName: current?.title ?? channel.groupTitle,
      online: 0,
    );
  }

  String _subCategoryId(String sourceId, String group) => '$sourceId|$group';

  (String, String)? _parseSubCategoryId(String id) {
    final index = id.indexOf('|');
    if (index <= 0 || index == id.length - 1) return null;
    return (id.substring(0, index), id.substring(index + 1));
  }
}
