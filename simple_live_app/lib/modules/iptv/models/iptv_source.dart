import 'package:hive/hive.dart';

/// IPTV 播放源
///
/// 一个 m3u 播放列表对应一个源。频道本身拆到 [IptvChannel] 单独存，
/// 刷新源时整体替换该源下的频道，避免逐条 diff。
class IptvSource {
  IptvSource({
    required this.id,
    required this.name,
    required this.url,
    this.epgUrl = '',
    this.enabled = true,
    this.lastUpdate,
    this.channelCount = 0,
    this.catchupMode = '',
    this.catchupSource = '',
  });

  /// 源ID，导入时生成，作为频道ID前缀
  final String id;

  /// 源名称，用户可改
  String name;

  /// m3u 地址（http/https），暂不支持本地文件持久化
  String url;

  /// EPG 地址，优先取 m3u 头部的 x-tvg-url，用户也可手填
  String epgUrl;

  /// 是否在分类页显示
  bool enabled;

  /// 上次刷新时间
  DateTime? lastUpdate;

  /// 频道数量
  int channelCount;

  /// m3u 头部的 catchup 模式（append 等），用于回看
  String catchupMode;

  /// m3u 头部的 catchup-source 模板，含 ${(b)yyyyMMddHHmmss} 占位符
  String catchupSource;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'epgUrl': epgUrl,
        'enabled': enabled,
        'lastUpdate': lastUpdate?.toIso8601String(),
        'channelCount': channelCount,
        'catchupMode': catchupMode,
        'catchupSource': catchupSource,
      };

  factory IptvSource.fromJson(Map<String, dynamic> json) => IptvSource(
        id: json['id'] as String,
        name: (json['name'] ?? '') as String,
        url: (json['url'] ?? '') as String,
        epgUrl: (json['epgUrl'] ?? '') as String,
        enabled: (json['enabled'] ?? true) as bool,
        lastUpdate: json['lastUpdate'] == null
            ? null
            : DateTime.tryParse(json['lastUpdate'] as String),
        channelCount: (json['channelCount'] ?? 0) as int,
        catchupMode: (json['catchupMode'] ?? '') as String,
        catchupSource: (json['catchupSource'] ?? '') as String,
      );
}

/// 手写 TypeAdapter，避免依赖 build_runner 生成代码
class IptvSourceAdapter extends TypeAdapter<IptvSource> {
  @override
  final int typeId = 10;

  @override
  IptvSource read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (var i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return IptvSource(
      id: (fields[0] ?? '') as String,
      name: (fields[1] ?? '') as String,
      url: (fields[2] ?? '') as String,
      epgUrl: (fields[3] ?? '') as String,
      enabled: (fields[4] ?? true) as bool,
      lastUpdate: fields[5] as DateTime?,
      channelCount: (fields[6] ?? 0) as int,
      catchupMode: (fields[7] ?? '') as String,
      catchupSource: (fields[8] ?? '') as String,
    );
  }

  @override
  void write(BinaryWriter writer, IptvSource obj) {
    writer
      ..writeByte(9)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.name)
      ..writeByte(2)
      ..write(obj.url)
      ..writeByte(3)
      ..write(obj.epgUrl)
      ..writeByte(4)
      ..write(obj.enabled)
      ..writeByte(5)
      ..write(obj.lastUpdate)
      ..writeByte(6)
      ..write(obj.channelCount)
      ..writeByte(7)
      ..write(obj.catchupMode)
      ..writeByte(8)
      ..write(obj.catchupSource);
  }
}
