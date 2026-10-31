import 'dart:convert';

class LivePlayUrl {
  /// 播放地址
  final List<String> urls;

  /// 请求头
  final Map<String, String>? headers;

  /// 每条线路的显示名，与 [urls] 一一对应
  ///
  /// 为空表示没有额外信息，界面按「线路1/线路2」显示。
  /// 自定义源会填成「源名 · 分组」，让用户在切线路时知道这条是哪来的。
  final List<String>? labels;

  LivePlayUrl({
    required this.urls,
    this.headers,
    this.labels,
  });

  @override
  String toString() {
    return json.encode({
      "urls": urls,
      "headers": headers.toString(),
      "labels": labels,
    });
  }
}
