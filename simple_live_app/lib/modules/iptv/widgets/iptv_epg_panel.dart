import 'dart:async';

import 'package:flutter/material.dart';
import 'package:remixicon/remixicon.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/modules/iptv/iptv_service.dart';
import 'package:simple_live_app/modules/iptv/models/iptv_channel.dart';
import 'package:simple_live_app/modules/iptv/parsers/xmltv_parser.dart';

/// IPTV 节目单面板
///
/// 直播间的聊天区对自定义源没有意义，这里换成节目单：
/// - 正在播出的节目高亮，带进度条和剩余时间
/// - 支持回看的频道，点过去的节目会切到回看地址
class IptvEpgPanel extends StatefulWidget {
  const IptvEpgPanel({
    Key? key,
    required this.channelId,
    this.onPlayCatchup,
    this.onBackToLive,
  }) : super(key: key);

  /// 频道ID（即 LiveRoomItem.roomId）
  final String channelId;

  /// 点了可回看的节目时回调，参数为拼好的回看地址
  final void Function(String url, EpgProgramme programme)? onPlayCatchup;

  /// 从回看切回直播
  final VoidCallback? onBackToLive;

  @override
  State<IptvEpgPanel> createState() => _IptvEpgPanelState();
}

class _IptvEpgPanelState extends State<IptvEpgPanel> {
  /// 固定行高，方便算"滚动到当前节目"的偏移
  static const double _itemHeight = 66;

  /// 只展示当前时间前后这段时间的节目，避免整份 EPG 全塞进来
  static const Duration _lookBack = Duration(hours: 12);
  static const Duration _lookAhead = Duration(hours: 36);

  final ScrollController _scrollController = ScrollController();

  IptvChannel? _channel;
  List<EpgProgramme> _programmes = const [];
  bool _loading = true;
  bool _hasEpg = true;
  String? _error;
  DateTime _now = DateTime.now();
  Timer? _ticker;
  bool _located = false;

  /// 当前正在回看的节目，null 表示看直播
  EpgProgramme? _catchup;

  bool get _canCatchup {
    final channel = _channel;
    if (channel == null) return false;
    return IptvService.instance.supportsCatchup(channel);
  }

  @override
  void initState() {
    super.initState();
    _load();
    // 每 30 秒推进一次，让"正在播"和进度条跟上
    _ticker = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!mounted) return;
      setState(() {
        _now = DateTime.now();
        _programmes = _visibleProgrammes();
      });
    });
  }

  @override
  void didUpdateWidget(IptvEpgPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.channelId != widget.channelId) {
      _located = false;
      _load();
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _load({bool force = false}) async {
    final service = IptvService.instance;
    final channel = service.getChannel(widget.channelId);
    if (channel == null) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = "频道不存在";
      });
      return;
    }

    // 首次加载时 _loading 已经是 true，不必再 setState
    if (!_loading) {
      setState(() {
        _loading = true;
        _error = null;
      });
    } else if (_error != null) {
      _error = null;
    }

    final guide = await service.loadEpg(channel.sourceId, force: force);
    if (!mounted) return;

    _channel = channel;
    _now = DateTime.now();
    _hasEpg = guide != null && channel.tvgId.isNotEmpty;
    _programmes = _visibleProgrammes(guide);
    _loading = false;
    setState(() {});

    // 列表建好之后再定位到当前节目
    WidgetsBinding.instance.addPostFrameCallback((_) => _locateCurrent());
  }

  List<EpgProgramme> _visibleProgrammes([XmltvGuide? guide]) {
    final channel = _channel;
    final data = guide ?? IptvService.instance.cachedEpg(channel?.sourceId ?? '');
    if (channel == null || data == null || channel.tvgId.isEmpty) {
      return const [];
    }
    final all = data.programmesOf(channel.tvgId);
    if (all.isEmpty) return const [];
    final from = _now.subtract(_lookBack);
    final to = _now.add(_lookAhead);
    return all
        .where((p) => p.stop.isAfter(from) && p.start.isBefore(to))
        .toList();
  }

  void _locateCurrent() {
    if (_located || !_scrollController.hasClients) return;
    _located = true;
    final index = _programmes.indexWhere((p) => p.contains(_now));
    if (index <= 0) return;
    final target = (index * _itemHeight).clamp(
      0.0,
      _scrollController.position.maxScrollExtent,
    );
    _scrollController.jumpTo(target);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _buildHeader(context),
        Expanded(child: _buildBody(context)),
      ],
    );
  }

  Widget _buildHeader(BuildContext context) {
    EpgProgramme? current;
    for (final programme in _programmes) {
      if (programme.contains(_now)) {
        current = programme;
        break;
      }
    }

    final catchup = _catchup;
    final String text;
    if (catchup != null) {
      text = "回看：${catchup.title}";
    } else if (current != null) {
      text = "正在播：${current.title}";
    } else {
      text = "节目单";
    }

    return Container(
      decoration: BoxDecoration(
        color: Theme.of(context).cardColor,
        border: Border(
          bottom: BorderSide(color: Colors.grey.withAlpha(25)),
        ),
      ),
      padding: AppStyle.edgeInsetsH12.copyWith(top: 6, bottom: 6),
      child: Row(
        children: [
          Icon(
            catchup == null ? Remix.calendar_schedule_line : Remix.play_circle_line,
            size: 16,
          ),
          AppStyle.hGap4,
          Expanded(
            child: Text(
              text,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12),
            ),
          ),
          if (catchup != null)
            TextButton(
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: AppStyle.edgeInsetsH8,
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: _backToLive,
              child: const Text("返回直播", style: TextStyle(fontSize: 12)),
            )
          else if (_canCatchup)
            Container(
              margin: AppStyle.edgeInsetsL8,
              padding: AppStyle.edgeInsetsH8.copyWith(top: 1, bottom: 1),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.primary.withAlpha(25),
                borderRadius: AppStyle.radius4,
              ),
              child: Text(
                "可回看",
                style: TextStyle(
                  fontSize: 10,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: "刷新节目单",
            icon: const Icon(Remix.refresh_line, size: 18),
            onPressed: _loading ? null : () => _load(force: true),
          ),
        ],
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_loading) {
      return const Center(
        child: SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    if (_error != null) {
      return _hint(context, Remix.error_warning_line, _error!, canRetry: true);
    }
    if (!_hasEpg) {
      return _hint(
        context,
        Remix.information_line,
        "这个频道没有节目单\n播放列表里缺少 EPG 地址或 tvg-id",
      );
    }
    if (_programmes.isEmpty) {
      return _hint(context, Remix.information_line, "节目单里没有该频道的数据");
    }
    return ListView.builder(
      controller: _scrollController,
      itemCount: _programmes.length,
      itemExtent: _itemHeight,
      itemBuilder: (context, index) {
        return _buildItem(context, _programmes[index]);
      },
    );
  }

  Widget _hint(
    BuildContext context,
    IconData icon,
    String text, {
    bool canRetry = false,
  }) {
    return Center(
      child: Padding(
        padding: AppStyle.edgeInsetsA16,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 32, color: Colors.grey.withAlpha(150)),
            AppStyle.vGap8,
            Text(
              text,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
            if (canRetry) ...[
              AppStyle.vGap4,
              TextButton(
                onPressed: () => _load(force: true),
                child: const Text("重试"),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildItem(BuildContext context, EpgProgramme programme) {
    final primary = Theme.of(context).colorScheme.primary;
    final isCurrent = programme.contains(_now);
    final isPast = !programme.stop.isAfter(_now);
    final canCatchup = isPast && _canCatchup;
    final catchup = _catchup;
    final isCatchup = catchup != null &&
        catchup.channelId == programme.channelId &&
        catchup.start == programme.start;

    final Color titleColor;
    if (isCurrent) {
      titleColor = primary;
    } else if (isPast) {
      titleColor = Colors.grey;
    } else {
      titleColor = Theme.of(context).colorScheme.onSurface;
    }

    return InkWell(
      onTap: canCatchup ? () => _playCatchup(programme) : null,
      child: Container(
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(
              color: isCurrent
                  ? primary
                  : (isCatchup ? primary.withAlpha(120) : Colors.transparent),
              width: 3,
            ),
            bottom: BorderSide(color: Colors.grey.withAlpha(20)),
          ),
          color: isCurrent
              ? primary.withAlpha(12)
              : (isCatchup ? primary.withAlpha(8) : null),
        ),
        padding: AppStyle.edgeInsetsH12.copyWith(top: 8, bottom: 8),
        child: Row(
          children: [
            SizedBox(
              width: 46,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    _hhmm(programme.start),
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: isCurrent ? FontWeight.bold : null,
                      color: isCurrent ? primary : Colors.grey,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _dayLabel(programme.start),
                    style: const TextStyle(fontSize: 10, color: Colors.grey),
                  ),
                ],
              ),
            ),
            AppStyle.hGap8,
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    programme.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      color: titleColor,
                      fontWeight: isCurrent ? FontWeight.bold : null,
                    ),
                  ),
                  const SizedBox(height: 4),
                  if (isCurrent)
                    _buildProgress(programme, primary)
                  else
                    Text(
                      "${_hhmm(programme.start)} - ${_hhmm(programme.stop)}",
                      style: const TextStyle(fontSize: 11, color: Colors.grey),
                    ),
                ],
              ),
            ),
            if (isCatchup) ...[
              AppStyle.hGap4,
              Icon(Remix.volume_up_line, size: 18, color: primary),
            ] else if (canCatchup) ...[
              AppStyle.hGap4,
              Icon(
                Remix.play_circle_line,
                size: 20,
                color: primary.withAlpha(180),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildProgress(EpgProgramme programme, Color primary) {
    final total = programme.stop.difference(programme.start).inSeconds;
    final elapsed = _now.difference(programme.start).inSeconds;
    final progress = total <= 0 ? 0.0 : (elapsed / total).clamp(0.0, 1.0);
    final remain = programme.stop.difference(_now).inMinutes;
    return Row(
      children: [
        Expanded(
          child: ClipRRect(
            borderRadius: AppStyle.radius4,
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 3,
              backgroundColor: Colors.grey.withAlpha(50),
            ),
          ),
        ),
        AppStyle.hGap8,
        Text(
          remain <= 0 ? "即将结束" : "还剩 $remain 分钟",
          style: TextStyle(fontSize: 10, color: primary),
        ),
      ],
    );
  }

  Future<void> _playCatchup(EpgProgramme programme) async {
    final channel = _channel;
    if (channel == null) return;
    final url = IptvService.instance.buildCatchupUrl(channel, programme);
    if (url == null || url.isEmpty) return;
    setState(() => _catchup = programme);
    widget.onPlayCatchup?.call(url, programme);
  }

  void _backToLive() {
    setState(() => _catchup = null);
    widget.onBackToLive?.call();
  }

  String _hhmm(DateTime time) =>
      "${time.hour.toString().padLeft(2, '0')}:"
      "${time.minute.toString().padLeft(2, '0')}";

  String _dayLabel(DateTime time) {
    final today = DateTime(_now.year, _now.month, _now.day);
    final day = DateTime(time.year, time.month, time.day);
    final diff = day.difference(today).inDays;
    if (diff == 0) return "今天";
    if (diff == 1) return "明天";
    if (diff == -1) return "昨天";
    return "${time.month}/${time.day}";
  }
}
