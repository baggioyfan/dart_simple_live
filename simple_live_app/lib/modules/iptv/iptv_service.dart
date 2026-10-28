import 'package:dio/dio.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/modules/iptv/models/iptv_channel.dart';
import 'package:simple_live_app/modules/iptv/models/iptv_source.dart';
import 'package:simple_live_app/modules/iptv/parsers/iptv_catchup.dart';
import 'package:simple_live_app/modules/iptv/parsers/m3u_parser.dart';
import 'package:simple_live_app/modules/iptv/parsers/xmltv_parser.dart';
import 'package:uuid/uuid.dart';

/// IPTV 源的抓取、解析、存储
///
/// 独立于 [DBService]，避免和上游的关注/历史表混在一起，
/// 后续同步上游改动时冲突面更小。
class IptvService extends GetxService {
  static IptvService get instance => Get.find<IptvService>();

  late Box<IptvSource> sourceBox;
  late Box<IptvChannel> channelBox;

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 60),
      headers: {
        'user-agent':
            'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36',
      },
    ),
  );

  /// EPG 内存缓存：sourceId -> 节目单
  final Map<String, XmltvGuide> _epgCache = {};
  final Map<String, DateTime> _epgCacheTime = {};
  static const Duration _epgTtl = Duration(minutes: 30);

  Future init() async {
    sourceBox = await Hive.openBox('IptvSource');
    channelBox = await Hive.openBox('IptvChannel');
    await _migrateLegacyOrder();
  }

  // ---------------- 源 ----------------

  List<IptvSource> getSources() {
    final list = sourceBox.values.toList();
    list.sort((a, b) => a.name.compareTo(b.name));
    return list;
  }

  List<IptvSource> getEnabledSources() =>
      getSources().where((e) => e.enabled).toList();

  IptvSource? getSource(String id) =>
      sourceBox.containsKey(id) ? sourceBox.get(id) : null;

  Future<void> updateSource(IptvSource source) async {
    await sourceBox.put(source.id, source);
  }

  Future<void> deleteSource(String id) async {
    await _removeChannelsOf(id);
    await sourceBox.delete(id);
    _epgCache.remove(id);
    _epgCacheTime.remove(id);
  }

  // ---------------- 频道 ----------------

  /// 某个源下的全部频道，按播放列表里的原始顺序
  ///
  /// 不能直接用 `channelBox.values`：Hive 不保证按写入顺序迭代，
  /// 重启后分组和组内顺序都会跟导入时看到的不一样，所以统一按 [IptvChannel.order] 排。
  List<IptvChannel> getChannels(String sourceId) {
    final list =
        channelBox.values.where((e) => e.sourceId == sourceId).toList();
    list.sort((a, b) => a.order.compareTo(b.order));
    return list;
  }

  IptvChannel? getChannel(String channelId) =>
      channelBox.containsKey(channelId) ? channelBox.get(channelId) : null;

  /// 取某个源下出现过的分组，保持播放列表中的原始顺序
  List<String> getGroups(String sourceId) {
    final seen = <String>{};
    final result = <String>[];
    for (final channel in getChannels(sourceId)) {
      if (seen.add(channel.groupTitle)) {
        result.add(channel.groupTitle);
      }
    }
    return result;
  }

  List<IptvChannel> getChannelsByGroup(String sourceId, String group) {
    return getChannels(sourceId)
        .where((e) => e.groupTitle == group)
        .toList();
  }

  Future<void> _removeChannelsOf(String sourceId) async {
    final keys = channelBox.keys
        .where((k) => channelBox.get(k)?.sourceId == sourceId)
        .toList();
    if (keys.isNotEmpty) {
      await channelBox.deleteAll(keys);
    }
  }

  // ---------------- 导入 / 刷新 ----------------

  /// 从地址导入一个新源，并立刻拉取频道
  Future<IptvSource> importFromUrl({
    required String url,
    String? name,
  }) async {
    final trimmed = url.trim();
    if (trimmed.isEmpty) {
      throw Exception('请填写播放列表地址');
    }
    final source = IptvSource(
      id: const Uuid().v4(),
      name: (name == null || name.trim().isEmpty)
          ? _guessName(trimmed)
          : name.trim(),
      url: trimmed,
    );
    await sourceBox.put(source.id, source);
    try {
      await refreshSource(source.id);
    } catch (e) {
      // 首次拉取失败就把空源删掉，避免列表里留一条没用的记录
      await sourceBox.delete(source.id);
      rethrow;
    }
    return getSource(source.id)!;
  }

  /// 重新拉取指定源的播放列表，整体替换其频道
  Future<void> refreshSource(String sourceId) async {
    final source = getSource(sourceId);
    if (source == null) {
      throw Exception('源不存在');
    }

    final content = await _fetchText(source.url);
    final playlist = M3uParser().parse(content, sourceId: sourceId);
    if (playlist.channels.isEmpty) {
      throw Exception(playlist.errors.isEmpty
          ? '未解析到频道'
          : playlist.errors.first);
    }

    await _removeChannelsOf(sourceId);
    await channelBox.putAll(
      {for (final channel in playlist.channels) channel.id: channel},
    );

    source
      ..channelCount = playlist.channels.length
      ..lastUpdate = DateTime.now()
      ..catchupMode = playlist.catchupMode
      ..catchupSource = playlist.catchupSource;
    // m3u 头部没带 EPG 时保留用户手填的地址
    if (playlist.epgUrl.isNotEmpty) {
      source.epgUrl = playlist.epgUrl;
    }
    await sourceBox.put(source.id, source);

    // 频道变了，旧节目单作废
    _epgCache.remove(sourceId);
    _epgCacheTime.remove(sourceId);
  }

  Future<void> refreshAll() async {
    for (final source in getEnabledSources()) {
      try {
        await refreshSource(source.id);
      } catch (e) {
        Log.logPrint(e);
      }
    }
  }

  /// 只刷新"该更新了"的源，返回实际刷新的数量
  ///
  /// 判定条件是「超过 [maxAge] **或** 跨了自然日」：
  /// 赛事类分组直接叫「体育-今天10-28」，播放列表每天都换一份，
  /// 所以哪怕间隔没到，只要日历翻页了就必须重拉。
  Future<int> refreshIfStale({required Duration maxAge}) async {
    var count = 0;
    final now = DateTime.now();
    for (final source in getEnabledSources()) {
      final last = source.lastUpdate;
      final fresh = last != null &&
          now.difference(last) < maxAge &&
          _isSameDay(last, now);
      if (fresh) continue;
      try {
        await refreshSource(source.id);
        count++;
      } catch (e) {
        Log.logPrint(e);
      }
    }
    return count;
  }

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  // ---------------- EPG ----------------

  /// 只读缓存，不触发网络请求
  ///
  /// 频道列表这类不该被网络拖慢的地方用它，拿不到就当没有节目单。
  XmltvGuide? cachedEpg(String sourceId) => _epgCache[sourceId];

  /// 读取节目单，内存缓存 [IptvService._epgTtl]
  Future<XmltvGuide?> loadEpg(String sourceId, {bool force = false}) async {
    final source = getSource(sourceId);
    if (source == null || source.epgUrl.isEmpty) return null;

    final cached = _epgCache[sourceId];
    final cachedAt = _epgCacheTime[sourceId];
    if (!force &&
        cached != null &&
        cachedAt != null &&
        DateTime.now().difference(cachedAt) < _epgTtl) {
      return cached;
    }

    try {
      final content = await _fetchText(source.epgUrl);
      final guide = XmltvParser().parse(content);
      _epgCache[sourceId] = guide;
      _epgCacheTime[sourceId] = DateTime.now();
      return guide;
    } catch (e) {
      Log.logPrint(e);
      // 拉取失败时退回旧缓存，有总比没有好
      return cached;
    }
  }

  // ---------------- 回看 ----------------

  /// 回看模板：频道级优先，退回源级（m3u 头部那条）
  String catchupTemplateOf(IptvChannel channel) {
    if (channel.catchupSource.trim().isNotEmpty) return channel.catchupSource;
    return getSource(channel.sourceId)?.catchupSource ?? '';
  }

  String catchupModeOf(IptvChannel channel) {
    if (channel.catchupMode.trim().isNotEmpty) return channel.catchupMode;
    return getSource(channel.sourceId)?.catchupMode ?? '';
  }

  /// 该频道是否支持回看
  bool supportsCatchup(IptvChannel channel) =>
      IptvCatchup.isSupported(catchupModeOf(channel), catchupTemplateOf(channel));

  /// 把某档节目拼成回看地址，不支持时返回 null
  String? buildCatchupUrl(IptvChannel channel, EpgProgramme programme) {
    if (!supportsCatchup(channel)) return null;
    return IptvCatchup.buildUrl(
      streamUrl: channel.streamUrl,
      template: catchupTemplateOf(channel),
      start: programme.start,
      stop: programme.stop,
    );
  }

  // ---------------- 内部 ----------------

  /// 给早期版本存的频道补顺序
  ///
  /// 那时候还没存 [IptvChannel.order]，一个源下的频道全是 0，排序等于没排。
  /// 没法凭空还原原始位置，只能把这类源标成「待更新」，交给定期更新服务重拉一次。
  /// 重拉之后 order 变成 0..n-1，这段逻辑就不会再命中。
  Future<void> _migrateLegacyOrder() async {
    for (final source in sourceBox.values.toList()) {
      final channels =
          channelBox.values.where((e) => e.sourceId == source.id).toList();
      if (channels.length < 2) continue;
      if (!channels.every((e) => e.order == 0)) continue;
      source.lastUpdate = null;
      await sourceBox.put(source.id, source);
    }
  }

  Future<String> _fetchText(String url) async {
    try {
      final response = await _dio.get<String>(
        url,
        options: Options(responseType: ResponseType.plain),
      );
      final data = response.data;
      if (data == null || data.isEmpty) {
        throw Exception('返回内容为空');
      }
      return data;
    } on DioException catch (e) {
      throw Exception('请求失败：${e.message ?? e.type.name}');
    }
  }

  String _guessName(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return '自定义源';
    final segments = uri.pathSegments.where((e) => e.isNotEmpty).toList();
    if (segments.isNotEmpty) {
      return segments.last;
    }
    return uri.host.isEmpty ? '自定义源' : uri.host;
  }
}
