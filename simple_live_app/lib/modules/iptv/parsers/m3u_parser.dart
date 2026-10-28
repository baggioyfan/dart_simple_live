import 'package:simple_live_app/modules/iptv/models/iptv_channel.dart';

/// m3u 解析结果
class M3uPlaylist {
  M3uPlaylist({
    required this.channels,
    this.epgUrl = '',
    this.catchupMode = '',
    this.catchupSource = '',
    List<String>? errors,
  }) : errors = errors ?? <String>[];

  /// 头部 x-tvg-url / url-tvg 指向的 XMLTV 节目单地址
  final String epgUrl;

  /// 头部 catchup 模式
  final String catchupMode;

  /// 头部 catchup-source 模板
  final String catchupSource;

  final List<IptvChannel> channels;

  /// 解析过程中的非致命问题，用于导入后提示
  final List<String> errors;
}

/// M3U / M3U Plus 播放列表解析器
///
/// 只覆盖 IPTV 实际会用到的部分：
/// - `#EXTM3U` 头部的 x-tvg-url / url-tvg / catchup / catchup-source
/// - `#EXTINF` 的 tvg-id / tvg-name / tvg-logo / tvg-chno / group-title
/// - `#EXTGRP` 分组继承
/// - 直接跟 `#EXTINF` 之后的播放地址
///
/// 不处理 `#EXTVLCOPT` / `#EXTHTTP` / `#KODIPROP`（当前源不需要，
/// 需要时再加，数据结构已经留好位置）。
class M3uParser {
  static const String _extInf = '#EXTINF:';
  static const String _extGrp = '#EXTGRP:';
  static const String _extM3u = '#EXTM3U';

  static final RegExp _attrRegex = RegExp(r'([\w-]+)="([^"]*)"');
  static final RegExp _schemeRegex = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.\-]*://');
  static const Set<String> _allowedSchemes = {
    'http',
    'https',
    'rtmp',
    'rtsp',
    'rtp',
    'udp',
    'mms',
  };

  /// 解析播放列表
  ///
  /// [sourceId] 会拼进频道ID前缀，保证不同源的频道ID不冲突。
  M3uPlaylist parse(String content, {required String sourceId}) {
    final lines = content.split(RegExp(r'\r\n?|\n'));
    final channels = <IptvChannel>[];
    final errors = <String>[];

    String epgUrl = '';
    String catchupMode = '';
    String catchupSource = '';

    // 待配对的下一个地址：EXTINF 解析出的属性
    Map<String, String>? pendingAttrs;
    String pendingName = '';
    int pendingLine = 0;
    // EXTGRP 设置的分组，EXTINF 自带 group-title 时以 EXTINF 为准
    String? directiveGroup;

    final usedIds = <String>{};

    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;

      if (line.startsWith(_extM3u)) {
        final attrs = _parseAttrs(line.substring(_extM3u.length));
        epgUrl = attrs['x-tvg-url'] ?? attrs['url-tvg'] ?? epgUrl;
        catchupMode = attrs['catchup'] ?? catchupMode;
        catchupSource = attrs['catchup-source'] ?? catchupSource;
        continue;
      }

      if (line.startsWith(_extInf)) {
        if (pendingAttrs != null) {
          errors.add('第 $pendingLine 行：缺少播放地址');
        }
        final body = line.substring(_extInf.length);
        // EXTINF 的格式是「时长 属性...,频道名」，频道名在最后一个未被引号包裹的逗号之后
        final split = _splitAtLastComma(body);
        pendingAttrs = _parseAttrs(split.$1);
        pendingName = split.$2.trim();
        pendingLine = i + 1;
        // EXTINF 自己带 group-title 时，EXTGRP 继承到此为止
        if (pendingAttrs.containsKey('group-title')) {
          directiveGroup = null;
        }
        continue;
      }

      if (line.startsWith(_extGrp)) {
        final g = line.substring(_extGrp.length).trim();
        directiveGroup = g.isEmpty ? null : g;
        continue;
      }

      // 其它 # 开头的指令直接跳过
      if (line.startsWith('#')) continue;

      if (pendingAttrs == null) {
        // 没有 EXTINF 的裸地址，忽略
        continue;
      }

      final attrs = pendingAttrs;
      final name = pendingName.isNotEmpty
          ? pendingName
          : (attrs['tvg-name'] ?? '').trim();
      pendingAttrs = null;
      pendingName = '';

      if (name.isEmpty) {
        errors.add('第 ${i + 1} 行：缺少频道名');
        continue;
      }
      if (!_isSupportedUrl(line)) {
        errors.add('第 ${i + 1} 行：不支持的播放地址 $line');
        continue;
      }

      final tvgId = (attrs['tvg-id'] ?? '').trim();
      final group = (attrs['group-title'] ?? directiveGroup ?? '').trim();

      // 频道ID优先用 tvg-id（与 EPG 对应），退化到频道名，重名时加序号
      var baseKey = tvgId.isNotEmpty ? tvgId : name;
      var channelId = '$sourceId|$baseKey';
      var seq = 2;
      while (usedIds.contains(channelId)) {
        channelId = '$sourceId|$baseKey#$seq';
        seq++;
      }
      usedIds.add(channelId);

      channels.add(
        IptvChannel(
          id: channelId,
          sourceId: sourceId,
          name: name,
          streamUrl: line,
          groupTitle: group.isEmpty ? '未分组' : group,
          logo: (attrs['tvg-logo'] ?? '').trim(),
          tvgId: tvgId,
          channelNumber: int.tryParse((attrs['tvg-chno'] ?? '').trim()),
          catchupMode: (attrs['catchup'] ?? catchupMode).trim(),
          catchupSource: (attrs['catchup-source'] ?? catchupSource).trim(),
        ),
      );
    }

    if (pendingAttrs != null) {
      errors.add('第 $pendingLine 行：缺少播放地址');
    }
    if (channels.isEmpty) {
      errors.add('未解析到任何频道，请确认这是 m3u 播放列表');
    }

    return M3uPlaylist(
      channels: channels,
      epgUrl: epgUrl,
      catchupMode: catchupMode,
      catchupSource: catchupSource,
      errors: errors,
    );
  }

  /// 解析 `key="value" key2="value2"` 形式的属性
  Map<String, String> _parseAttrs(String source) {
    final result = <String, String>{};
    for (final m in _attrRegex.allMatches(source)) {
      final key = m.group(1);
      final value = m.group(2);
      if (key != null && value != null) {
        result[key.toLowerCase()] = value;
      }
    }
    return result;
  }

  /// 在最后一个「不在引号内」的逗号处切分
  ///
  /// tvg-logo 这类属性值里可能带逗号，不能简单用 lastIndexOf。
  (String, String) _splitAtLastComma(String source) {
    var inQuote = false;
    var splitIndex = -1;
    for (var i = 0; i < source.length; i++) {
      final ch = source[i];
      if (ch == '"') {
        inQuote = !inQuote;
      } else if (ch == ',' && !inQuote) {
        splitIndex = i;
      }
    }
    if (splitIndex < 0) return (source, '');
    return (
      source.substring(0, splitIndex),
      source.substring(splitIndex + 1),
    );
  }

  bool _isSupportedUrl(String url) {
    if (!_schemeRegex.hasMatch(url)) return false;
    final scheme = url.substring(0, url.indexOf('://')).toLowerCase();
    return _allowedSchemes.contains(scheme);
  }
}
