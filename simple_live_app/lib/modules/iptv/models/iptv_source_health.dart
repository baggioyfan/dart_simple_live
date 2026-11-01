/// 一个直播源的可用性采样结果
///
/// 不追求精确 —— 一个源动辄几百个频道，全探一遍要几分钟，还会被源站当成
/// 爬虫。取几个频道当样本，只回答「这个源整体还能不能用」。
class IptvSourceHealth {
  const IptvSourceHealth({required this.alive, required this.total});

  /// 样本里能播通的条数
  final int alive;

  /// 实际探了几个
  final int total;

  /// 没探过，或者源里没有频道
  bool get unknown => total == 0;

  /// 一条都不通 —— 基本可以判定这个源废了
  bool get allDead => total > 0 && alive == 0;

  /// 全通
  bool get allAlive => total > 0 && alive == total;

  /// 部分可用
  bool get partial => total > 0 && alive > 0 && alive < total;

  String get text => unknown ? "未检测" : "$alive/$total 可用";
}
