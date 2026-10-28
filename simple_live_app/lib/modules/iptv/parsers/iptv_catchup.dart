/// 回看（catchup）地址拼装
///
/// m3u 头部的 `catchup-source` 是个模板，例如：
/// ```
/// ?playbackbegin=${(b)yyyyMMddHHmmss}&playbackend=${(e)yyyyMMddHHmmss}
/// ```
/// `(b)` 是节目开始时间，`(e)` 是结束时间，后面跟一段时间格式。
/// 拼好的地址要么是相对查询串（接在频道地址后面），要么是完整地址。
class IptvCatchup {
  static const String _defaultFormat = 'yyyyMMddHHmmss';

  /// 匹配 `${(b)yyyyMMddHHmmss}` / `${(e)yyyyMMddHHmmss}`，格式可省略
  static final RegExp _placeholder = RegExp(r'\$\{\(([be])\)([^}]*)\}');

  /// 匹配 `${start}` / `${end}` 这类简化写法
  static final RegExp _simplePlaceholder = RegExp(r'\$\{(start|end|utc)\}');

  /// 是否具备回看能力
  static bool isSupported(String catchupMode, String catchupSource) {
    if (catchupSource.trim().isEmpty) return false;
    final mode = catchupMode.trim().toLowerCase();
    // append 是最常见的实现；default/空 也当 append 处理，模板本身能说明意图
    return mode.isEmpty || mode == 'append' || mode == 'default';
  }

  /// 拼装回看地址，失败返回 null
  static String? buildUrl({
    required String streamUrl,
    required String template,
    required DateTime start,
    required DateTime stop,
  }) {
    final tpl = template.trim();
    if (tpl.isEmpty) return null;
    if (!stop.isAfter(start)) return null;

    var result = tpl.replaceAllMapped(_placeholder, (match) {
      final which = match.group(1);
      final format = (match.group(2) ?? '').trim();
      final time = which == 'e' ? stop : start;
      return _format(time, format.isEmpty ? _defaultFormat : format);
    });

    result = result.replaceAllMapped(_simplePlaceholder, (match) {
      final which = match.group(1);
      final time = which == 'end' ? stop : start;
      return _format(time, _defaultFormat);
    });

    if (result.contains('://')) {
      // 完整地址模板，频道地址不再参与
      return result;
    }

    // 相对模板：接在频道地址后面，处理好分隔符
    if (result.startsWith('?') || result.startsWith('&')) {
      if (streamUrl.contains('?')) {
        // 频道地址已经带了查询串，把开头的 ? 换成 &
        final suffix = result.startsWith('?')
            ? '&${result.substring(1)}'
            : result;
        return '$streamUrl$suffix';
      }
      return '$streamUrl$result';
    }

    return '$streamUrl?$result';
  }

  /// 支持 yyyy / MM / dd / HH / mm / ss 这几个 token
  static String _format(DateTime time, String pattern) {
    var result = pattern;
    result = result.replaceAll('yyyy', time.year.toString().padLeft(4, '0'));
    result = result.replaceAll('MM', time.month.toString().padLeft(2, '0'));
    result = result.replaceAll('dd', time.day.toString().padLeft(2, '0'));
    result = result.replaceAll('HH', time.hour.toString().padLeft(2, '0'));
    result = result.replaceAll('mm', time.minute.toString().padLeft(2, '0'));
    result = result.replaceAll('ss', time.second.toString().padLeft(2, '0'));
    return result;
  }
}
