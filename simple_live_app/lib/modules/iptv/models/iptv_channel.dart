import 'package:hive/hive.dart';

/// IPTV 频道
///
/// 由 m3u 解析而来，[id] 作为 LiveRoomItem.roomId 使用，
/// 因此必须在同一个源内稳定且唯一。
class IptvChannel {
  IptvChannel({
    required this.id,
    required this.sourceId,
    required this.name,
    required this.streamUrl,
    this.groupTitle = '',
    this.logo = '',
    this.tvgId = '',
    this.channelNumber,
    this.catchupMode = '',
    this.catchupSource = '',
    this.order = 0,
  });

  /// 频道ID = 源ID + 频道标识，全局唯一
  final String id;

  /// 所属源ID
  final String sourceId;

  /// 频道名（#EXTINF 最后一个逗号后的部分）
  String name;

  /// 播放地址
  String streamUrl;

  /// 分组名（group-title）
  String groupTitle;

  /// 台标（tvg-logo）
  String logo;

  /// tvg-id，通常与 EPG 的 channel id 对应
  String tvgId;

  /// 频道号（tvg-chno），没有则为 null
  int? channelNumber;

  /// 回看模式
  String catchupMode;

  /// 回看地址模板
  String catchupSource;

  /// 在播放列表中的序号，从 0 开始
  ///
  /// 分组顺序和组内顺序都直接沿用它 —— Hive 的 `Box.values` 不保证按写入顺序
  /// 迭代，重启后拿到的顺序和导入时看到的不一样，所以必须把顺序显式存下来。
  int order;

  Map<String, dynamic> toJson() => {
        'id': id,
        'sourceId': sourceId,
        'name': name,
        'streamUrl': streamUrl,
        'groupTitle': groupTitle,
        'logo': logo,
        'tvgId': tvgId,
        'channelNumber': channelNumber,
        'catchupMode': catchupMode,
        'catchupSource': catchupSource,
        'order': order,
      };

  factory IptvChannel.fromJson(Map<String, dynamic> json) => IptvChannel(
        id: json['id'] as String,
        sourceId: (json['sourceId'] ?? '') as String,
        name: (json['name'] ?? '') as String,
        streamUrl: (json['streamUrl'] ?? '') as String,
        groupTitle: (json['groupTitle'] ?? '') as String,
        logo: (json['logo'] ?? '') as String,
        tvgId: (json['tvgId'] ?? '') as String,
        channelNumber: json['channelNumber'] as int?,
        catchupMode: (json['catchupMode'] ?? '') as String,
        catchupSource: (json['catchupSource'] ?? '') as String,
        order: (json['order'] ?? 0) as int,
      );
}

class IptvChannelAdapter extends TypeAdapter<IptvChannel> {
  @override
  final int typeId = 11;

  @override
  IptvChannel read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{
      for (var i = 0; i < numOfFields; i++) reader.readByte(): reader.read(),
    };
    return IptvChannel(
      id: (fields[0] ?? '') as String,
      sourceId: (fields[1] ?? '') as String,
      name: (fields[2] ?? '') as String,
      streamUrl: (fields[3] ?? '') as String,
      groupTitle: (fields[4] ?? '') as String,
      logo: (fields[5] ?? '') as String,
      tvgId: (fields[6] ?? '') as String,
      channelNumber: fields[7] as int?,
      catchupMode: (fields[8] ?? '') as String,
      catchupSource: (fields[9] ?? '') as String,
      // 老数据没有这一列，读出来是 null，落到 0 由 IptvService 统一迁移
      order: (fields[10] ?? 0) as int,
    );
  }

  @override
  void write(BinaryWriter writer, IptvChannel obj) {
    writer
      ..writeByte(11)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.sourceId)
      ..writeByte(2)
      ..write(obj.name)
      ..writeByte(3)
      ..write(obj.streamUrl)
      ..writeByte(4)
      ..write(obj.groupTitle)
      ..writeByte(5)
      ..write(obj.logo)
      ..writeByte(6)
      ..write(obj.tvgId)
      ..writeByte(7)
      ..write(obj.channelNumber)
      ..writeByte(8)
      ..write(obj.catchupMode)
      ..writeByte(9)
      ..write(obj.catchupSource)
      ..writeByte(10)
      ..write(obj.order);
  }
}
