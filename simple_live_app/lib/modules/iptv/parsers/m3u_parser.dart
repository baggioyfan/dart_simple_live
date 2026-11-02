import 'package:simple_live_app/modules/iptv/models/iptv_channel.dart';

/// m3u 解析结果
class M3uPlaylist {
  M3uPlaylist({
    required this.channels,
    this.epgUrl = '',
    this.catchupMode = '',
    this.catchupSource = '',
    this.mergedCount = 0,
    List<String>? errors,
  }) : errors = errors ?? <String>[];

  /// 头部 x-tvg-url / url-tvg 指向的 XMLTV 节目单地址
  final String epgUrl;

  /// 头部 catchup 模式
  final String catchupMode;

  /// 头部 catchup-source 模板
  final String catchupSource;

  final List<IptvChannel> channels;

  /// 被合并掉的重复条目数（同一个台的多条线路）
  ///
  /// 导入/刷新时用来告诉用户「N 条合并成一条」，否则频道数变少会让人以为丢台了。
  final int mergedCount;

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

  /// 单个频道最多保留多少条线路
  ///
  /// 有的列表把一个台挂了几十条 CDN，全留下来线路面板会长得没法看，
  /// 而且真到要手动切的地步，前 20 条和全部也没什么区别。
  static const int maxLines = 20;

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
    // 判重索引：一个 tvg-id 可能被多个台共用（列表填错时），所以是一对多
    final byTvgId = <String, List<IptvChannel>>{};
    final byName = <String, IptvChannel>{};
    var merged = 0;

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
      final logo = (attrs['tvg-logo'] ?? '').trim();
      final channelNumber = int.tryParse((attrs['tvg-chno'] ?? '').trim());
      final channelCatchupMode = (attrs['catchup'] ?? catchupMode).trim();
      final channelCatchupSource =
          (attrs['catchup-source'] ?? catchupSource).trim();

      // 同一个台在播放列表里经常出现多次（不同 CDN 的地址），合并成一条记录，
      // 多出来的地址进 altUrls 当备用线路。
      // 先按 tvg-id 认，再按归一化后的频道名认 —— 有些列表同一个台第一次
      // 没写 tvg-id，只靠 tvg-id 会漏合并。
      final idKey = _normalize(tvgId);
      final nameKey = _normalize(name);

      IptvChannel? existing;
      if (idKey.isNotEmpty) {
        // tvg-id 命中还要看名字像不像。不少列表把一堆不相干的台都填成同一个
        // 占位值（"0"、"none"），只认 id 会把整个列表合并成一个频道。
        for (final candidate in byTvgId[idKey] ?? const <IptvChannel>[]) {
          if (_looksSameChannel(nameKey, _normalize(candidate.name))) {
            existing = candidate;
            break;
          }
        }
      }
      existing ??= nameKey.isEmpty ? null : byName[nameKey];

      if (existing != null) {
        merged++;
        // 只补首次出现时缺失的字段，已有的不覆盖，保证顺序和名称以第一次为准
        if (existing.logo.isEmpty && logo.isNotEmpty) {
          existing.logo = logo;
        }
        if (existing.channelNumber == null && channelNumber != null) {
          existing.channelNumber = channelNumber;
        }
        if (existing.catchupMode.isEmpty && channelCatchupMode.isNotEmpty) {
          existing.catchupMode = channelCatchupMode;
        }
        if (existing.catchupSource.isEmpty &&
            channelCatchupSource.isNotEmpty) {
          existing.catchupSource = channelCatchupSource;
        }
        if (existing.tvgId.isEmpty && tvgId.isNotEmpty) {
          existing.tvgId = tvgId;
          if (idKey.isNotEmpty) {
            final list = byTvgId[idKey] ??= <IptvChannel>[];
            if (!list.contains(existing)) list.add(existing);
          }
        }
        // 线路数封顶：见过一个台挂几十条 CDN 的列表，全留着线路面板没法看
        if (existing.altUrls.length < maxLines - 1 &&
            !existing.allUrls.contains(line)) {
          existing.altUrls.add(line);
        }
        continue;
      }

      // 频道ID优先用 tvg-id（与 EPG 对应），退化到频道名，重名时加序号
      var baseKey = tvgId.isNotEmpty ? tvgId : name;
      var channelId = '$sourceId|$baseKey';
      var seq = 2;
      while (usedIds.contains(channelId)) {
        channelId = '$sourceId|$baseKey#$seq';
        seq++;
      }
      usedIds.add(channelId);

      final channel = IptvChannel(
        id: channelId,
        sourceId: sourceId,
        name: name,
        streamUrl: line,
        groupTitle: group.isEmpty ? '未分组' : group,
        logo: logo,
        tvgId: tvgId,
        // 只存不参与 id 生成（改 id 会让已存的关注/历史对不上），
        // 用于在 tvg-id 缺失时按台名匹配 EPG
        tvgName: (attrs['tvg-name'] ?? '').trim(),
        channelNumber: channelNumber,
        catchupMode: channelCatchupMode,
        catchupSource: channelCatchupSource,
        // 记住它在播放列表里的位置，后续排序全靠这个
        order: channels.length,
      );
      channels.add(channel);
      if (idKey.isNotEmpty) {
        (byTvgId[idKey] ??= <IptvChannel>[]).add(channel);
      }
      if (nameKey.isNotEmpty) byName[nameKey] = channel;
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
      mergedCount: merged,
      errors: errors,
    );
  }

  /// 归一化后用于判重：小写、全角转半角、去掉空格和常见分隔符
  ///
  /// 只为了让「CCTV-1」「CCTV1」「ＣＣＴＶ－１」认成同一个台。
  /// 特意不去掉「高清」「HD」这类后缀 —— 那是不同的频道，合了反而错。
  String _normalize(String value) {
    final buffer = StringBuffer();
    for (final raw in value.toLowerCase().runes) {
      // 全角 ASCII 段整体平移到半角
      final rune = (raw >= 0xFF01 && raw <= 0xFF5E) ? raw - 0xFEE0 : raw;
      final ch = String.fromCharCode(rune);
      if (ch.trim().isEmpty) continue;
      if (_ignoredSeparators.contains(ch)) continue;
      buffer.write(ch);
    }
    return buffer.toString();
  }

  /// 判重时忽略的分隔符
  static const Set<String> _ignoredSeparators = {
    '-',
    '_',
    '.',
    '·',
    '•',
    ':',
    '|',
  };

  /// 两个归一化后的频道名是不是同一个台
  ///
  /// 相等，或者一个是另一个的子串（「cctv1」/「cctv1高清」）。名字缺失时没法比，
  /// 只能信 tvg-id，直接返回 true。
  bool _looksSameChannel(String a, String b) {
    if (a.isEmpty || b.isEmpty) return true;
    return a == b || a.contains(b) || b.contains(a);
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
