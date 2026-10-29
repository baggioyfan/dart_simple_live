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
///   实际内容相同，均为 AWS IVS 的 HLS 地址。
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

  @override
  Future<List<LivePlayQuality>> getPlayQualites({
    required LiveRoomDetail detail,
  }) async {
    var data = detail.data;
    var play = data is Map ? data["play"] : null;
    var streams = _streams(play is Map ? play : null);

    if (streams.isEmpty) {
      // 没有播放信息时给一个占位清晰度，getPlayUrls 会再尝试一次
      return [
        LivePlayQuality(quality: "自动", data: {"sort": 1}, sort: 1),
      ];
    }

    var qualities = <LivePlayQuality>[];
    var seen = <int>{};
    for (var item in streams) {
      var sort = int.tryParse((item["sort"] ?? 1).toString()) ?? 1;
      if (!seen.add(sort)) continue;
      var name = (item["name"] ?? "").toString();
      qualities.add(
        LivePlayQuality(
          quality: name.isEmpty ? "自动" : name,
          data: {"sort": sort, "url": (item["url"] ?? "").toString()},
          sort: sort,
        ),
      );
    }
    qualities.sort((a, b) => b.sort.compareTo(a.sort));
    return qualities;
  }

  @override
  Future<LivePlayUrl> getPlayUrls({
    required LiveRoomDetail detail,
    required LivePlayQuality quality,
  }) async {
    var data = detail.data;
    var userId = data is Map ? (data["userId"] ?? detail.roomId).toString() : detail.roomId;
    var referer = _roomUrl(userId);

    // 重新取一次，避免详情页停留过久后 token 过期
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

    var qualityData = quality.data;
    var wantSort = 1;
    if (qualityData is Map && qualityData["sort"] != null) {
      wantSort = int.tryParse(qualityData["sort"].toString()) ?? 1;
    }

    var streams = _streams(play);
    String url = "";
    for (var item in streams) {
      var sort = int.tryParse((item["sort"] ?? 1).toString()) ?? 1;
      if (sort == wantSort) {
        url = (item["url"] ?? "").toString();
        break;
      }
    }
    if (url.isEmpty && streams.isNotEmpty) {
      url = (streams.first["url"] ?? "").toString();
    }
    if (url.isEmpty && qualityData is Map) {
      url = (qualityData["url"] ?? "").toString();
    }

    return LivePlayUrl(
      urls: url.isEmpty ? [] : [url],
      headers: {
        "referer": referer,
        "user-agent": _ua,
      },
    );
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
