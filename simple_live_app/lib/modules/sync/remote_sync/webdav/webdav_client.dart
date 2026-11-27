import 'dart:async';
import 'dart:typed_data';

import 'package:webdav_client/webdav_client.dart';

class DAVClient {
  late Client client;
  Completer<bool> pingCompleter = Completer();

  DAVClient(
      String webDAVUri,
      String webDAVUser,
      String webDAVPassword,
      ) {
    client = newClient(
      webDAVUri,
      user: webDAVUser,
      password: webDAVPassword,
    );
    client.setHeaders(
      {
        'accept-charset': 'utf-8',
        'Content-Type': 'text/xml',
      },
    );
    client.setConnectTimeout(8000);
    client.setSendTimeout(8000);
    client.setReceiveTimeout(8000);
    pingCompleter.complete(_ping());
  }

  Future<bool> _ping() async {
    try {
      await client.ping();
      return true;
    } catch (_) {
      return false;
    }
  }
  // 强制统一
  get root => "/simple_live_app";

  get backupFile => "$root/backup.zip";

  backup(Uint8List data) async {
    await client.mkdir("$root");
    await client.write("$backupFile", data);
    return true;
  }

  Future<List<int>> recovery() async {
    await client.mkdir("$root");
    final data = await client.read(backupFile);
    return data;
  }

  /// 云端备份文件的修改时间
  ///
  /// 自动同步靠它判断云端有没有比本地更新的数据。返回的是**服务器时钟**，
  /// 所以调用方不要拿本地 `DateTime.now()` 去比较。
  /// 文件不存在或请求失败都返回 null（服务器不支持 PROPFIND 也会走到这里）。
  Future<DateTime?> remoteModified() async {
    try {
      final props = await client.readProps(backupFile);
      return props.mTime;
    } catch (_) {
      return null;
    }
  }
}