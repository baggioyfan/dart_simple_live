import 'dart:async';

import 'package:simple_live_core/src/common/core_error.dart';
import 'package:simple_live_core/src/common/http_client.dart';
import 'package:simple_live_core/src/interface/live_danmaku.dart';
import 'package:simple_live_core/src/interface/live_site.dart';
import 'package:simple_live_core/src/model/live_anchor_item.dart';
import 'package:simple_live_core/src/model/live_category.dart';
import 'package:simple_live_core/src/model/live_category_result.dart';
import 'package:simple_live_core/src/model/live_message.dart';
import 'package:simple_live_core/src/model/live_play_quality.dart';
import 'package:simple_live_core/src/model/live_play_url.dart';
import 'package:simple_live_core/src/model/live_room_detail.dart';
import 'package:simple_live_core/src/model/live_room_item.dart';
import 'package:simple_live_core/src/model/live_search_result.dart';

/// PandaTV（pandalive.co.kr）站点适配
///
/// 接口说明（2026-10 实测）：
/// - 列表/搜索统一走 `POST /v1/live/index`，参数为 offset / limit / orderBy，
///   搜索时追加 searchVal 并把 orderBy 换成 user。
/// - 房间详情走 `POST /v1/member/bj`，返回 bjInfo（主播资料）与 media（当前直播）。
///   未开播时 media 为 null，非存在用户返回 result=false。
/// - 播放地址走 `POST /v1/live/play`，**必须带 action=watch**，否则接口只回
///   一个通用错误，看不出是参数问题。返回 PlayList.hls3/hls2/hls 三档，
///   实际内容相同，均为 AWS IVS 的主 playlist 地址。
///
/// 播放链路有两个坑（2026-10 实测）：
/// 1. 主 playlist 的 token 里 `aws:strict-origin-enforcement` 为 true，
///    请求必须带 `Origin: https://www.pandalive.co.kr`，否则 403。
/// 2. 主 playlist 的 token 是一次性的，第二次请求返回 duplicate token。
///    所以这里先解析出子 playlist 再交给播放器，子 playlist 可以重复请求。
class PandaLiveSite implements LiveSite {
  @override
  String id = "pandalive";

  @override
  String name = "PandaTV";

  static const String _api = "https://api.pandalive.co.kr";
  static const String _origin = "https://www.pandalive.co.kr";
  static const String _ua =
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
      "(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36";

  /// 单页数量，接口上限为 50
  static const int _pageSize = 30;

  @override
  LiveDanmaku getDanmaku() => LiveDanmaku();

  Map<String, String> _headers(String referer) => {
        "referer": referer,
        "origin": _origin,
        "user-agent": _ua,
      };

  /// 统一的 POST 封装。接口在业务失败时也会返回 400，
  /// 这里吞掉异常返回 null，由调用方按 null 处理。
  Future<Map<String, dynamic>?> _post(
    String path,
    Map<String, String> form,
    String referer,
  ) async {
    try {
      var result = await HttpClient.instance.postJson(
        "$_api$path",
        data: form,
        formUrlEncoded: true,
        header: _headers(referer),
      );
      if (result is Map) {
        return Map<String, dynamic>.from(result);
      }
      return null;
    } on CoreError {
      return null;
    }
  }

  String _roomUrl(String userId) => "$_origin/channel/$userId";

  /// 安全取列表，字段类型异常时返回空列表
  List _rows(dynamic value) => value is List ? value : const [];

  /// 解析 `/v1/live/index` 的列表行
  LiveRoomItem _parseCard(Map item) {
    return LiveRoomItem(
      roomId: (item["userId"] ?? "").toString(),
      title: (item["title"] ?? "").toString(),
      cover: (item["thumbUrl"] ?? "").toString(),
      userName: (item["userNick"] ?? "").toString(),
      online: int.tryParse((item["user"] ?? 0).toString()) ?? 0,
    );
  }

  /// 解析 `/v1/live/index` 返回体，兼容 offset/limit 分页
  LiveCategoryResult _parseDirectory(Map? root, {required int page}) {
    if (root == null || root["result"] == false) {
      return LiveCategoryResult(hasMore: false, items: []);
    }
    var items = <LiveRoomItem>[];
    for (var item in _rows(root["list"])) {
      if (item is! Map) continue;
      var card = _parseCard(item);
      if (card.roomId.isEmpty) continue;
      items.add(card);
    }
    var total = 0;
    var paging = root["page"];
    if (paging is Map) {
      total = int.tryParse((paging["total"] ?? 0).toString()) ?? 0;
    }
    var offset = (page - 1) * _pageSize;
    return LiveCategoryResult(
      hasMore: items.isNotEmpty && offset + items.length < total,
      items: items,
    );
  }

  Future<LiveCategoryResult> _directory(int page) async {
    var root = await _post(
      "/v1/live/index",
      {
        "offset": "${(page - 1) * _pageSize}",
        "limit": "$_pageSize",
        "orderBy": "hot",
      },
      "$_origin/live",
    );
    return _parseDirectory(root, page: page);
  }

  @override
  Future<List<LiveCategory>> getCategores() async {
    // PandaTV 网页端只有一个总榜，没有分区体系
    return [
      LiveCategory(
        id: id,
        name: name,
        children: [
          LiveSubCategory(
            id: "all",
            parentId: id,
            name: "全部直播",
          ),
        ],
      ),
    ];
  }

  @override
  Future<LiveCategoryResult> getRecommendRooms({int page = 1}) {
    return _directory(page);
  }

  @override
  Future<LiveCategoryResult> getCategoryRooms(
    LiveSubCategory category, {
    int page = 1,
  }) {
    return _directory(page);
  }

  @override
  Future<LiveSearchRoomResult> searchRooms(String keyword, {int page = 1}) async {
    var query = keyword.trim();
    if (query.length < 2) {
      return LiveSearchRoomResult(hasMore: false, items: []);
    }
    var root = await _post(
      "/v1/live/index",
      {
        "offset": "${(page - 1) * _pageSize}",
        "limit": "$_pageSize",
        "orderBy": "user",
        "searchVal": query,
      },
      "$_origin/search/live?text=${Uri.encodeQueryComponent(query)}",
    );
    var result = _parseDirectory(root, page: page);
    return LiveSearchRoomResult(hasMore: result.hasMore, items: result.items);
  }

  @override
  Future<LiveSearchAnchorResult> searchAnchors(String keyword, {int page = 1}) async {
    var query = keyword.trim();
    if (query.length < 2) {
      return LiveSearchAnchorResult(hasMore: false, items: []);
    }
    var root = await _post(
      "/v1/live/bj_list",
      {
        "offset": "${(page - 1) * _pageSize}",
        "limit": "$_pageSize",
        "searchVal": query,
      },
      "$_origin/search/bj?text=${Uri.encodeQueryComponent(query)}",
    );
    if (root == null || root["result"] == false) {
      return LiveSearchAnchorResult(hasMore: false, items: []);
    }
    var items = <LiveAnchorItem>[];
    for (var item in _rows(root["list"])) {
      if (item is! Map) continue;
      var userId = (item["userId"] ?? item["id"] ?? "").toString();
      if (userId.isEmpty) continue;
      var media = item["media"];
      items.add(
        LiveAnchorItem(
          roomId: userId,
          userName: (item["userNick"] ?? item["nick"] ?? "").toString(),
          avatar: (item["userImg"] ?? item["thumbUrl"] ?? "").toString(),
          liveStatus: media is Map && media["isLive"] == true,
        ),
      );
    }
    var total = 0;
    var paging = root["page"];
    if (paging is Map) {
      total = int.tryParse((paging["total"] ?? 0).toString()) ?? 0;
    }
    var offset = (page - 1) * _pageSize;
    return LiveSearchAnchorResult(
      hasMore: items.isNotEmpty && offset + items.length < total,
      items: items,
    );
  }

  @override
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) async {
    var userId = roomId.trim();
    var referer = _roomUrl(userId);
    var member = await _post(
      "/v1/member/bj",
      {"userId": userId, "info": "media fanGrade"},
      referer,
    );

    if (member == null || member["result"] != true) {
      // 用户不存在或接口异常，返回一个离线的空房间，避免上层直接抛错
      return LiveRoomDetail(
        roomId: userId,
        title: "",
        cover: "",
        userName: "",
        userAvatar: "",
        online: 0,
        status: false,
        url: referer,
        data: {"userId": userId, "play": null},
      );
    }

    var bjInfo = member["bjInfo"] is Map ? Map.from(member["bjInfo"]) : {};
    var media = member["media"] is Map ? Map.from(member["media"]) : null;
    var isLive = media != null && media["isLive"] == true;

    // 开播时才去取播放信息，PlayList 里带清晰度与地址
    Map? play;
    if (isLive) {
      play = await _post(
        "/v1/live/play",
        {
          "action": "watch",
          "userId": userId,
          "password": "",
          "shareLinkType": "",
        },
        referer,
      );
      if (play != null && play["result"] != true) {
        play = null;
      }
    }

    return LiveRoomDetail(
      roomId: userId,
      title: (media?["title"] ?? bjInfo["channelTitle"] ?? "").toString(),
      cover: (media?["thumbUrl"] ?? bjInfo["thumbUrl"] ?? "").toString(),
      userName: (media?["userNick"] ?? bjInfo["nick"] ?? "").toString(),
      userAvatar: (media?["userImg"] ?? bjInfo["thumbUrl"] ?? "").toString(),
      online: int.tryParse((media?["user"] ?? 0).toString()) ?? 0,
      introduction: (bjInfo["channelDesc"] ?? "").toString(),
      notice: "",
      status: isLive,
      url: referer,
      isRecord: false,
      danmakuData: null,
      data: {"userId": userId, "play": play},
    );
  }

  /// 从 play 返回体里取出可用的清晰度列表
  List<Map> _streams(Map? play) {
    var playList = play?["PlayList"];
    if (playList is! Map) return [];
    for (var key in ["hls3", "hls2", "hls"]) {
      var list = playList[key];
      if (list is List && list.isNotEmpty) {
        return list.whereType<Map>().toList();
      }
    }
    return [];
  }

  /// 请求 IVS 主 playlist，解析出各档子 playlist
  ///
  /// 主 playlist 的地址带一次性 token（JWT 里是 aws:single-use-uuid），
  /// 第二次请求会返回 duplicate token / invalid_token；而它列出的子 playlist
  /// 可以重复请求。所以把子 playlist 交给播放器，重连、拖动都不会再撞上
  /// 一次性 token。
  ///
  /// 请求本身必须带 `Origin: https://www.pandalive.co.kr`——token 里
  /// aws:strict-origin-enforcement 为 true，缺这个头或填别的来源都会 403。
  Future<List<_PandaVariant>> _variants(
    String masterUrl,
    String referer,
  ) async {
    String text;
    try {
      text = await HttpClient.instance.getText(
        masterUrl,
        header: _headers(referer),
      );
    } on CoreError {
      return [];
    }

    var byHeight = <int, _PandaVariant>{};
    int? pendingHeight;
    for (var raw in text.split("\n")) {
      var line = raw.trim();
      if (line.isEmpty) continue;
      if (line.startsWith("#EXT-X-STREAM-INF:")) {
        var match = RegExp(r"RESOLUTION=\d+x(\d+)").firstMatch(line);
        pendingHeight = match == null ? null : int.tryParse(match.group(1)!);
        continue;
      }
      if (line.startsWith("#")) continue;
      var height = pendingHeight;
      if (height == null) continue;
      pendingHeight = null;
      byHeight.putIfAbsent(
        height,
        () => _PandaVariant(_qualityName(height), height, line),
      );
    }

    var result = byHeight.values.toList();
    result.sort((a, b) => b.height.compareTo(a.height));
    return result;
  }

  String _qualityName(int height) {
    if (height >= 2160) return "4K";
    if (height >= 1440) return "2K";
    if (height >= 1080) return "1080P";
    if (height >= 720) return "720P";
    if (height >= 480) return "480P";
    if (height >= 360) return "360P";
    return "${height}P";
  }

  @override
  Future<List<LivePlayQuality>> getPlayQualites({
    required LiveRoomDetail detail,
  }) async {
    var data = detail.data;
    var userId = data is Map
        ? (data["userId"] ?? detail.roomId).toString()
        : detail.roomId;
    var referer = _roomUrl(userId);
    var play = data is Map ? data["play"] : null;
    var streams = _streams(play is Map ? play : null);

    var masterUrl =
        streams.isEmpty ? "" : (streams.first["url"] ?? "").toString();
    if (masterUrl.isNotEmpty) {
      var variants = await _variants(masterUrl, referer);
      if (variants.isNotEmpty) {
        return [
          for (var item in variants)
            LivePlayQuality(
              quality: item.name,
              data: {"url": item.url, "height": item.height},
              sort: item.height,
            ),
        ];
      }
    }

    // 主 playlist 解析失败时退回单档，getPlayUrls 会重新取一次 play
    return [
      LivePlayQuality(quality: "自动", data: {"sort": 1}, sort: 1),
    ];
  }

  @override
  Future<LivePlayUrl> getPlayUrls({
    required LiveRoomDetail detail,
    required LivePlayQuality quality,
  }) async {
    var data = detail.data;
    var userId = data is Map
        ? (data["userId"] ?? detail.roomId).toString()
        : detail.roomId;
    var referer = _roomUrl(userId);
    // 必须带 origin，否则 IVS 直接 403
    var headers = _headers(referer);

    var qualityData = quality.data;
    var url = qualityData is Map ? (qualityData["url"] ?? "").toString() : "";

    if (url.isEmpty) {
      // 占位清晰度：重新取一次 play，再解析主 playlist
      var play = await _post(
        "/v1/live/play",
        {
          "action": "watch",
          "userId": userId,
          "password": "",
          "shareLinkType": "",
        },
        referer,
      );
      var streams = _streams(play);
      var masterUrl =
          streams.isEmpty ? "" : (streams.first["url"] ?? "").toString();
      if (masterUrl.isEmpty) {
        return LivePlayUrl(urls: [], headers: headers);
      }

      var variants = await _variants(masterUrl, referer);
      if (variants.isEmpty) {
        // 解析不出来只能退回主 playlist（一次性 token，重连会失败）
        url = masterUrl;
      } else {
        var wantHeight = qualityData is Map
            ? int.tryParse((qualityData["height"] ?? 0).toString()) ?? 0
            : 0;
        var picked = variants.first;
        for (var item in variants) {
          if (item.height == wantHeight) {
            picked = item;
            break;
          }
        }
        url = picked.url;
      }
    }

    return LivePlayUrl(urls: [url], headers: headers);
  }

  @override
  Future<bool> getLiveStatus({required String roomId}) async {
    var member = await _post(
      "/v1/member/bj",
      {"userId": roomId.trim(), "info": "media"},
      _roomUrl(roomId.trim()),
    );
    if (member == null || member["result"] != true) return false;
    var media = member["media"];
    return media is Map && media["isLive"] == true;
  }

  @override
  Future<List<LiveSuperChatMessage>> getSuperChatMessage({
    required String roomId,
  }) async {
    // PandaTV 没有公开的醒目留言接口
    return [];
  }
}

/// IVS 主 playlist 里的一档清晰度
class _PandaVariant {
  final String name;
  final int height;
  final String url;

  _PandaVariant(this.name, this.height, this.url);
}
