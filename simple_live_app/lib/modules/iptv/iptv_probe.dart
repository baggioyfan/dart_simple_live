import 'dart:convert';
import 'dart:io';

/// IPTV 线路探测 + 域名健康度
///
/// 播放器只有自己报错才知道线路挂了，而它愿意等多久不受我们控制 —— 域名黑洞
/// （DNS 能解析、TCP SYN 不回）时 libmpv 要一直等到系统 connect 超时，一条
/// 线路能卡几十秒，5 条线路加起来就是几分钟。这里主动发一个只读前 2KB 的
/// HTTP 请求，正常情况下 3 秒内就能判断线路活不活。
///
/// 健康度按**域名**记而不是按频道：m3u 里大量频道共用同一个 CDN 域名，
/// 域名挂了就整片挂，没必要每个频道各自从头重试一遍。这就是「不行就都不行」
/// 的落地方式 —— 一个域名连续失败之后，同域名的线路探测超时会压到 1 秒。
///
/// 但只能压超时，不能直接判死：同一个域名下挂的是不同的 path，
/// 403 / 404 / 空分片这类故障是单个频道自己的事，域名本身还是活的。
class IptvProbe {
  IptvProbe._();

  /// 正常线路的探测超时
  static const Duration timeout = Duration(seconds: 3);

  /// 域名近期连续失败时用的超时，够拿到一个 RST 就行
  static const Duration suspectTimeout = Duration(seconds: 1);

  /// 同时探测的线路数
  ///
  /// IPTV 源普遍限制并发连接数，一次铺开太多会被当成滥用，
  /// 反而把本来能用的线路探成不可用。但太小又追不上播放器的
  /// 错误级联 —— 一个台十几条线路时，探不完就等于没探。
  static const int maxConcurrent = 4;

  /// 读这么多就够判断是不是 m3u8 了
  static const int _probeBytes = 2048;

  /// 域名坏标记的记忆时长
  static const Duration healthTtl = Duration(minutes: 10);

  /// 连续失败多少次算「可疑」
  static const int _suspectThreshold = 2;

  static const String _userAgent =
      'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36';

  static final Map<String, _HostHealth> _hosts = <String, _HostHealth>{};

  /// 探测单条线路，能播返回 true
  ///
  /// 判定标准是「拿得到响应且内容是播放列表」：
  /// - 200 / 206 且内容含 `#EXTM3U`（或 Content-Type 是 mpegurl）
  /// - 直连流（.ts / .flv / .mp4 这类）只看状态码，读内容反而会卡住
  static Future<bool> probeOne(String url) async {
    final uri = Uri.tryParse(url.trim());
    // udp:// rtp:// 这些没法用 HTTP 探，交给播放器自己判断
    if (uri == null || uri.host.isEmpty) return true;
    if (uri.scheme != 'http' && uri.scheme != 'https') return true;

    final host = uri.host;
    final wait = isSuspect(url) ? suspectTimeout : timeout;
    final client = HttpClient()
      ..connectionTimeout = wait
      ..userAgent = _userAgent;

    try {
      final request = await client.getUrl(uri).timeout(wait);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=0-$_probeBytes');
      final response = await request.close().timeout(wait);

      // 能收到响应说明域名和端口都是通的，问题出在路径上。
      // 这种情况算 host 健康 —— 否则一个频道的 404 会把这个域名下
      // 所有本来能用的线路都连累成「可疑」。
      if (response.statusCode != HttpStatus.ok &&
          response.statusCode != HttpStatus.partialContent) {
        _markOk(host);
        // 416 是「文件比我要的区间还小」，服务器活得好好的
        return response.statusCode ==
            HttpStatus.requestedRangeNotSatisfiable;
      }

      if (_isDirectMedia(uri.path) ||
          _isPlaylistMime(response.headers.contentType)) {
        _markOk(host);
        return true;
      }

      final bytes = <int>[];
      await for (final chunk in response.timeout(wait)) {
        bytes.addAll(chunk);
        if (bytes.length >= _probeBytes) break;
      }
      final text = latin1.decode(bytes, allowInvalid: true);
      final playable = text.contains('#EXTM3U') || text.contains('#EXTINF');

      // 200 但内容是 HTML 错误页 —— 很多 IPTV 源就这么干，
      // 播放器拿到手才会报错，这里先拦下来
      if (playable) {
        _markOk(host);
      } else {
        _markFail(host);
      }
      return playable;
    } catch (e) {
      _markFail(host);
      return false;
    } finally {
      // 探完立刻断开，别留 keep-alive 占着源的并发额度
      client.close(force: true);
    }
  }

  /// 批量探测，返回值与 [urls] 一一对应
  ///
  /// [onResult] 每探完一条就回调一次，调用方可以边探边更新界面，
  /// 不用等整批跑完 —— 十几条线路的台，等全部探完用户早等不及了。
  static Future<List<bool>> probeAll(
    List<String> urls, {
    void Function(int index, bool alive)? onResult,
  }) async {
    final results = List<bool>.filled(urls.length, false);
    if (urls.isEmpty) return results;

    for (var start = 0; start < urls.length; start += maxConcurrent) {
      final next = start + maxConcurrent;
      final end = next < urls.length ? next : urls.length;
      final batch = await Future.wait(<Future<bool>>[
        for (var i = start; i < end; i++) probeOne(urls[i]),
      ]);
      for (var i = 0; i < batch.length; i++) {
        results[start + i] = batch[i];
        onResult?.call(start + i, batch[i]);
      }
    }
    return results;
  }

  /// 播放器报错时调用
  ///
  /// 探测通过但流打不开的情况（分片地址失效、鉴权过期）靠这个补一刀。
  static void reportFailed(String url) {
    final host = _hostOf(url);
    if (host != null) _markFail(host);
  }

  /// 该线路的域名最近是否连续失败过
  static bool isSuspect(String url) {
    final host = _hostOf(url);
    if (host == null) return false;
    final health = _hosts[host];
    if (health == null || health.failCount < _suspectThreshold) return false;
    final at = health.lastFailAt;
    if (at == null) return false;
    return DateTime.now().difference(at) < healthTtl;
  }

  /// 播放器报的这个错是不是网络层面的
  ///
  /// 解码失败、音轨缺失这些跟域名无关，不能算到 host 头上 —— 一旦误记，
  /// 这个域名下的其它线路下次探测会被压到 1 秒，好线路也可能探成不通。
  static bool looksLikeNetworkError(String error) {
    final text = error.toLowerCase();
    for (final hint in const <String>[
      'failed to open',
      'connection',
      'timed out',
      'timeout',
      'could not resolve',
      'server returned',
      'http error',
      'network is unreachable',
    ]) {
      if (text.contains(hint)) return true;
    }
    return false;
  }

  static void _markOk(String host) {
    final health = _hosts[host];
    if (health == null) return;
    health.failCount = 0;
    health.lastFailAt = null;
  }

  static void _markFail(String host) {
    final now = DateTime.now();
    final health = _hosts.putIfAbsent(host, () => _HostHealth());
    // 上次失败已经过去很久了，说明中间好过，重新计数
    final at = health.lastFailAt;
    if (at == null || now.difference(at) > healthTtl) {
      health.failCount = 0;
    }
    health.failCount += 1;
    health.lastFailAt = now;
  }

  static String? _hostOf(String url) {
    final uri = Uri.tryParse(url.trim());
    if (uri == null) return null;
    final host = uri.host.trim();
    return host.isEmpty ? null : host;
  }

  static bool _isDirectMedia(String path) {
    final lower = path.toLowerCase();
    for (final ext in const <String>['.ts', '.flv', '.mp4', '.mkv', '.mpd']) {
      if (lower.endsWith(ext)) return true;
    }
    return false;
  }

  static bool _isPlaylistMime(ContentType? type) {
    if (type == null) return false;
    return type.mimeType.toLowerCase().contains('mpegurl');
  }
}

class _HostHealth {
  int failCount = 0;
  DateTime? lastFailAt;
}
