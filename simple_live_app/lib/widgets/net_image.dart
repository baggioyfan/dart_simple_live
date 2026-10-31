import 'package:extended_image/extended_image.dart';
import 'package:flutter/material.dart';

class NetImage extends StatelessWidget {
  final String picUrl;
  final double? width;
  final double? height;
  final BoxFit? fit;
  final double borderRadius;

  /// 额外的请求头
  ///
  /// 只有自定义源（IPTV）会传 —— 那些台标来自各种自建图床，不少会按 UA
  /// 拦掉非浏览器请求，不带头就只拿到 403。其它平台的图床有自己的防盗链
  /// 规则，别去动它们的请求头，所以这里默认 null 保持原样。
  final Map<String, String>? headers;

  /// 自定义源台标请求头
  ///
  /// 和 IptvService 拉播放列表用的 UA 保持一致。
  static const Map<String, String> iptvHeaders = {
    'user-agent':
        'Mozilla/5.0 (Linux; Android 13) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Mobile Safari/537.36',
  };

  const NetImage(
    this.picUrl, {
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.borderRadius = 0,
    this.headers,
    Key? key,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    if (picUrl.isEmpty) {
      return Image.asset(
        'assets/images/logo.png',
        width: width,
        height: height,
      );
    }
    var pic = picUrl;
    if (pic.startsWith("//")) {
      pic = 'https:$pic';
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // 按实际显示宽度解码。封面原图常见 1280x720，卡片只有 200 逻辑像素宽，
          // 不限制的话每张要解出 3.7MB 位图（约 10 倍浪费），解码还压在主线程上。
          //
          // 只给 cacheWidth、不给 cacheHeight：两个都给会强制拉伸，竖版封面会变形。
          // 单边限制会按原比例缩放。
          //
          // 不要自己传 cacheKey：ExtendedImage 内部会用 ExtendedResizeImage 包一层，
          // 尺寸已经进了缓存键；而自定义 cacheKey 会被 extended_image 直接当成
          // 磁盘缓存文件名（不 hash），传 URL 进去会拼出非法路径、写缓存抛异常，
          // 结果每张图都要下载两遍。
          final dpr = MediaQuery.of(context).devicePixelRatio;
          var targetWidth =
              (width != null && width!.isFinite) ? width! : constraints.maxWidth;
          if (!targetWidth.isFinite || targetWidth <= 0) {
            targetWidth = 0;
          }
          final cacheWidth =
              targetWidth > 0 ? (targetWidth * dpr).round() : null;

          return ExtendedImage.network(
            pic,
            fit: fit,
            height: height,
            width: width,
            shape: BoxShape.rectangle,
            borderRadius: BorderRadius.circular(borderRadius),
            cacheWidth: cacheWidth,
            headers: headers,
            // 台标服务器经常接了连接却迟迟不吐数据，不设上限就一直卡在
            // loading 态（转圈图标），比直接报错更让人摸不着头脑。
            timeLimit: const Duration(seconds: 20),
            loadStateChanged: (e) {
              if (e.extendedImageLoadState == LoadState.loading) {
                return const Icon(
                  Icons.image,
                  color: Colors.grey,
                  size: 24,
                );
              }
              if (e.extendedImageLoadState == LoadState.failed) {
                return const Icon(
                  Icons.broken_image,
                  color: Colors.grey,
                  size: 24,
                );
              }
              return null;
            },
          );
        },
      ),
    );
  }
}
