/// 单条节目
class EpgProgramme {
  EpgProgramme({
    required this.channelId,
    required this.title,
    required this.start,
    required this.stop,
  });

  final String channelId;
  final String title;
  final DateTime start;
  final DateTime stop;

  bool contains(DateTime time) =>
      !time.isBefore(start) && time.isBefore(stop);
}

/// XMLTV 节目单
///
/// 只做 regex 解析，不引入 xml 包：XMLTV 由 EPG 生成器批量产出，
/// 结构高度规整，regex 足够且省掉一个依赖。
class XmltvGuide {
  XmltvGuide({
    required this.programmes,
    required this.channelNames,
  });

  /// 频道ID -> 按开始时间升序的节目列表
  final Map<String, List<EpgProgramme>> programmes;

  /// 频道ID -> display-name
  final Map<String, String> channelNames;

  bool get isEmpty => programmes.isEmpty;

  List<EpgProgramme> programmesOf(String channelId) =>
      programmes[channelId] ?? const <EpgProgramme>[];

  /// 取指定时刻正在播出的节目
  EpgProgramme? currentAt(String channelId, DateTime at) {
    for (final p in programmesOf(channelId)) {
      if (p.contains(at)) return p;
    }
    return null;
  }

  /// 取指定时刻之后最近的一档节目
  EpgProgramme? nextAfter(String channelId, DateTime at) {
    for (final p in programmesOf(channelId)) {
      if (p.start.isAfter(at)) return p;
    }
    return null;
  }
}

class XmltvParser {
  static final RegExp _programmeRegex = RegExp(
    r'<programme\b([^>]*)>([\s\S]*?)</programme>',
  );
  static final RegExp _channelRegex = RegExp(
    r'<channel\b([^>]*)>([\s\S]*?)</channel>',
  );
  static final RegExp _titleRegex = RegExp(r'<title\b[^>]*>([\s\S]*?)</title>');
  static final RegExp _displayNameRegex = RegExp(
    r'<display-name\b[^>]*>([\s\S]*?)</display-name>',
  );
  static final RegExp _attrRegex = RegExp(r'([\w-]+)="([^"]*)"');
  static final RegExp _timeRegex = RegExp(r'^(\d{14})\s*([+-]\d{4})?');

  /// 解析 XMLTV 文本
  XmltvGuide parse(String content) {
    final channelNames = <String, String>{};
    for (final m in _channelRegex.allMatches(content)) {
      final attrs = _parseAttrs(m.group(1) ?? '');
      final id = attrs['id']?.trim() ?? '';
      if (id.isEmpty) continue;
      final nameMatch = _displayNameRegex.firstMatch(m.group(2) ?? '');
      final name = nameMatch == null ? id : _unescape(nameMatch.group(1) ?? id).trim();
      channelNames[id] = name.isEmpty ? id : name;
    }

    final programmes = <String, List<EpgProgramme>>{};
    for (final m in _programmeRegex.allMatches(content)) {
      final attrs = _parseAttrs(m.group(1) ?? '');
      final channelId = attrs['channel']?.trim() ?? '';
      if (channelId.isEmpty) continue;
      final start = _parseTime(attrs['start'] ?? '');
      if (start == null) continue;
      final stop = _parseTime(attrs['stop'] ?? '');
      if (stop == null || !stop.isAfter(start)) continue;

      final titleMatch = _titleRegex.firstMatch(m.group(2) ?? '');
      final title = titleMatch == null
          ? ''
          : _unescape(titleMatch.group(1) ?? '').trim();

      (programmes[channelId] ??= <EpgProgramme>[]).add(
        EpgProgramme(
          channelId: channelId,
          title: title.isEmpty ? '未知节目' : title,
          start: start,
          stop: stop,
        ),
      );
    }

    for (final list in programmes.values) {
      list.sort((a, b) => a.start.compareTo(b.start));
    }

    return XmltvGuide(programmes: programmes, channelNames: channelNames);
  }

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

  /// XMLTV 时间格式：`20261028000000 +0800`
  DateTime? _parseTime(String raw) {
    final m = _timeRegex.firstMatch(raw.trim());
    if (m == null) return null;
    final digits = m.group(1)!;
    final year = int.tryParse(digits.substring(0, 4));
    final month = int.tryParse(digits.substring(4, 6));
    final day = int.tryParse(digits.substring(6, 8));
    final hour = int.tryParse(digits.substring(8, 10));
    final minute = int.tryParse(digits.substring(10, 12));
    final second = int.tryParse(digits.substring(12, 14));
    if (year == null ||
        month == null ||
        day == null ||
        hour == null ||
        minute == null ||
        second == null) {
      return null;
    }

    var offset = Duration.zero;
    final zone = m.group(2);
    if (zone != null && zone.length == 5) {
      final sign = zone.startsWith('-') ? -1 : 1;
      final oh = int.tryParse(zone.substring(1, 3)) ?? 0;
      final om = int.tryParse(zone.substring(3, 5)) ?? 0;
      offset = Duration(hours: sign * oh, minutes: sign * om);
    }

    final utc = DateTime.utc(year, month, day, hour, minute, second)
        .subtract(offset);
    return utc.toLocal();
  }

  String _unescape(String source) {
    return source
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&apos;', "'")
        .replaceAll('&#39;', "'")
        .replaceAll('&amp;', '&');
  }
}
