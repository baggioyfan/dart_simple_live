import 'package:flutter/scheduler.dart';

/// 给 TabController 用的 TickerProvider
///
/// 为什么不直接用 `GetSingleTickerProviderStateMixin`：
/// 那个 mixin 只允许创建一个 Ticker，而这里的 TabController 会在
/// 「自定义源」开关切换时被销毁重建，同一个 controller 生命周期内会创建多次。
///
/// 这个实现不持有任何状态：每次 createTicker 都给一个新的 Ticker，生命周期
/// 完全交给 TabController —— TabController.dispose() 会连带把它释放掉，
/// 因此不存在 Ticker 泄漏，也不需要额外 dispose。
class TabsTickerProvider implements TickerProvider {
  const TabsTickerProvider();

  @override
  Ticker createTicker(TickerCallback onTick) {
    return Ticker(onTick, debugLabel: "TabController");
  }
}
