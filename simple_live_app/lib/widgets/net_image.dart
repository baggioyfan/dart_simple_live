import 'package:extended_image/extended_image.dart';
import 'package:flutter/material.dart';

class NetImage extends StatelessWidget {
  final String picUrl;
  final double? width;
  final double? height;
  final BoxFit? fit;
  final double borderRadius;
  const NetImage(this.picUrl,
      {this.width,
      this.height,
      this.fit = BoxFit.cover,
      this.borderRadius = 0,
      Key? key})
      : super(key: key);

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
          // 按实际显示宽度解码，别拿原图尺寸去解。
          // 列表封面原图常见 1280x720，而卡片只有 200 逻辑像素宽，
          // 不限制的话每张要解出 3.7MB 的位图（约 10 倍浪费），
          // 解码又压在主线程上，滚动时就掉帧。
          //
          // 只给 cacheWidth、不给 cacheHeight：两个都给会强制拉伸，
          // 竖版封面会变形。单边限制会按原比例缩放。
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
            // 同一张图在不同位置可能按不同尺寸解码，
            // 缓存键带上宽度，避免小图把大图的位置占了。
            cacheKey: cacheWidth == null ? null : '$pic#w$cacheWidth',
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
