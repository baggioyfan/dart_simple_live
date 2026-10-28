import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:remixicon/remixicon.dart';
import 'package:simple_live_app/modules/iptv/iptv_source_controller.dart';
import 'package:simple_live_app/modules/iptv/models/iptv_source.dart';

/// IPTV 直播源管理页
///
/// 入口：我的 → 直播源设置
class IptvSourcePage extends GetView<IptvSourceController> {
  const IptvSourcePage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("直播源设置"),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: "添加直播源",
            onPressed: () => _showAddDialog(context),
          ),
        ],
      ),
      body: Obx(() {
        if (controller.sources.isEmpty) {
          return _emptyView(context);
        }
        return ListView.separated(
          padding: const EdgeInsets.symmetric(vertical: 8),
          itemCount: controller.sources.length,
          separatorBuilder: (_, __) => Divider(
            indent: 16,
            endIndent: 16,
            height: 1,
            color: Colors.grey.withAlpha(25),
          ),
          itemBuilder: (context, index) {
            final source = controller.sources[index];
            return _sourceItem(context, source);
          },
        );
      }),
    );
  }

  Widget _emptyView(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Remix.play_list_line,
            size: 56,
            color: Colors.grey.withAlpha(120),
          ),
          const SizedBox(height: 12),
          const Text(
            "还没有直播源",
            style: TextStyle(fontSize: 15),
          ),
          const SizedBox(height: 6),
          Text(
            "点右上角 + 导入 m3u 播放列表地址",
            style: TextStyle(
              fontSize: 13,
              color: Colors.grey.withAlpha(180),
            ),
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: () => _showAddDialog(context),
            icon: const Icon(Icons.add),
            label: const Text("添加直播源"),
          ),
        ],
      ),
    );
  }

  Widget _sourceItem(BuildContext context, IptvSource source) {
    return ListTile(
      leading: Icon(
        source.enabled ? Remix.play_circle_line : Remix.pause_circle_line,
        color: source.enabled ? null : Colors.grey,
      ),
      title: Text(
        source.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: source.enabled ? null : Colors.grey,
        ),
      ),
      subtitle: Text(
        _subtitle(source),
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 12),
      ),
      isThreeLine: true,
      trailing: PopupMenuButton<String>(
        icon: const Icon(Icons.more_vert),
        onSelected: (value) => _onAction(context, source, value),
        itemBuilder: (_) => [
          const PopupMenuItem(
            value: "refresh",
            child: Text("刷新频道"),
          ),
          PopupMenuItem(
            value: "toggle",
            child: Text(source.enabled ? "停用" : "启用"),
          ),
          const PopupMenuItem(
            value: "rename",
            child: Text("重命名"),
          ),
          const PopupMenuItem(
            value: "delete",
            child: Text("删除"),
          ),
        ],
      ),
    );
  }

  String _subtitle(IptvSource source) {
    final buffer = StringBuffer("${source.channelCount} 个频道");
    final last = source.lastUpdate;
    if (last != null) {
      buffer.write(
        " · 更新于 ${last.month}-${last.day} "
        "${last.hour.toString().padLeft(2, '0')}:"
        "${last.minute.toString().padLeft(2, '0')}",
      );
    }
    if (source.epgUrl.isNotEmpty) {
      buffer.write(" · 含节目单");
    }
    buffer.write("\n${source.url}");
    return buffer.toString();
  }

  Future<void> _onAction(
    BuildContext context,
    IptvSource source,
    String action,
  ) async {
    switch (action) {
      case "refresh":
        await controller.refreshSource(source);
        break;
      case "toggle":
        await controller.toggleEnabled(source);
        break;
      case "rename":
        final name = await _showRenameDialog(context, source.name);
        if (name != null) {
          await controller.rename(source, name);
        }
        break;
      case "delete":
        final ok = await _confirmDelete(context, source.name);
        if (ok) {
          await controller.remove(source);
        }
        break;
    }
  }

  Future<void> _showAddDialog(BuildContext context) async {
    final result = await showDialog<_AddSourceResult>(
      context: context,
      builder: (_) => const _AddSourceDialog(),
    );
    if (result == null) return;
    await controller.importSource(url: result.url, name: result.name);
  }

  Future<String?> _showRenameDialog(BuildContext context, String current) async {
    final textController = TextEditingController(text: current);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("重命名"),
        content: TextField(
          controller: textController,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: "名称",
            hintText: "例如 家里 IPTV",
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text("取消"),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(ctx).pop(textController.text.trim()),
            child: const Text("保存"),
          ),
        ],
      ),
    );
    textController.dispose();
    return (result == null || result.isEmpty) ? null : result;
  }

  Future<bool> _confirmDelete(BuildContext context, String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text("删除直播源"),
        content: Text("确定删除「$name」及其所有频道吗？"),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text("取消"),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text("删除"),
          ),
        ],
      ),
    );
    return ok ?? false;
  }
}

class _AddSourceResult {
  _AddSourceResult(this.url, this.name);
  final String url;
  final String name;
}

class _AddSourceDialog extends StatefulWidget {
  const _AddSourceDialog();

  @override
  State<_AddSourceDialog> createState() => _AddSourceDialogState();
}

class _AddSourceDialogState extends State<_AddSourceDialog> {
  final TextEditingController urlController = TextEditingController();
  final TextEditingController nameController = TextEditingController();

  @override
  void dispose() {
    urlController.dispose();
    nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text("添加直播源"),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: urlController,
            autofocus: true,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: "播放列表地址",
              hintText: "http://example.com/playlist.m3u",
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: nameController,
            decoration: const InputDecoration(
              labelText: "名称（可选）",
              hintText: "留空则自动取地址末段",
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text("取消"),
        ),
        TextButton(
          onPressed: () {
            final url = urlController.text.trim();
            if (url.isEmpty) return;
            Navigator.of(context).pop(
              _AddSourceResult(url, nameController.text.trim()),
            );
          },
          child: const Text("导入"),
        ),
      ],
    );
  }
}
