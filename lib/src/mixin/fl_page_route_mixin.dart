import 'package:flutter/material.dart';

import 'package:meta/meta.dart';

import '../delegate/fl_page_route_delegate.dart';
import '../lifecycle/fl_route_observer.dart';
import '../lifecycle/lifecycle_route_aware.dart';

/// 只关心 **路由** 的页面 mixin：路由信息、框架路由事件、转场动画。
///
/// 处理逻辑本身全部在 [FlPageRouteDelegate] 中，本 mixin 只做两件事：
/// 在 `didChangeDependencies` / `dispose` 中自动 attach / detach，并把委托的
/// 回调转成子类可覆写的模板方法。因此**不需要**手动调用任何初始化 / 释放方法。
///
/// 与 `FlPageLifecycleMixin` 的区别：本 mixin **原样转发** [FlRouteObserver]
/// 发出的路由事件，不做任何幂等、补发与 PageView 判断——不会保证
/// 「start 后必跟 resume」「stop 前必补 pause」，也不关心页面是否真的可见。
/// 需要这些语义时用 `FlPageLifecycleMixin`，它已经内置了同一个委托，
/// **两者不要叠加使用**。
///
/// 唯一不依赖路由的是首帧的 [onRouteStart] / [onRouteResume] 与 `dispose` 时
/// 补发的 [onRoutePause] / [onRouteStop]：没有 `ModalRoute` 时它们照常发出，
/// 因此这一对始终是配对的。
///
/// ```dart
/// class _DetailPageState extends State<DetailPage> with FlPageRouteMixin {
///   @override
///   void onPageContextReady(String? routeName, Object? arguments) {
///     _id = (arguments as Map?)?['id'] as String?;
///   }
///
///   @override
///   void onPageEnterAnimationEnd() => _loadHeavyStuff();
/// }
/// ```
mixin FlPageRouteMixin<T extends StatefulWidget> on State<T>
    implements LifecycleRouteAware {
  /// 路由相关处理（取路由、订阅路由事件、监听转场动画）全部委托给它。
  late final FlPageRouteDelegate _routeDelegate = FlPageRouteDelegate(
    host: this,
    onEnterAnimationEnd: onPageEnterAnimationEnd,
    onLeaveAnimationEnd: onPageLeaveAnimationEnd,
    onEnterAnimationStart: onPageEnterAnimationStart,
    onLeaveAnimationStart: onPageLeaveAnimationStart,
  );

  bool _didRunOnContextReady = false;

  /// 页面所在的路由，页面不处于任何路由中或已 `dispose` 时为 null。
  ModalRoute? get modalRoute => _routeDelegate.modalRoute;

  String? get routeName => _routeDelegate.routeName;

  Object? get arguments => _routeDelegate.arguments;

  /// 本页是不是**所在 Navigator** 的栈顶路由。实时查询，不缓存。
  ///
  /// 三个容易踩的点：
  ///
  /// - 被弹窗（`PopupRoute`）盖住时为 false，但此刻页面**仍然可见**——弹窗只
  ///   触发 [onRoutePause] 不触发 [onRouteStop]；
  /// - 嵌套 Navigator 时只反映**本层**：内层栈顶页即使整个内层 Navigator 被
  ///   外层路由盖住，这里依然是 true；
  /// - 转场动画期间就已经翻转：被 pop 的路由在动画**开始**时就不再是栈顶，
  ///   要判断转场真的结束请用 [onPageEnterAnimationEnd] /
  ///   [onPageLeaveAnimationEnd]。
  ///
  /// 不在任何路由中（`ModalRoute.of` 为 null）时为 false，因此**不要**拿它去
  /// 过滤生命周期事件——那会把非路由页面永久挡死。
  bool get isCurrent => _routeDelegate.isCurrent;

  /// 是否已成功挂到某个路由上。为 false 时下面的路由回调都不会触发。
  bool get hasRoute => _routeDelegate.isAttached;
  bool _hasDispose = false;
  bool _hasAppear = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((timeStamp) {
      if (_hasDispose) {
        return;
      }
      if (_hasAppear) {
        return;
      }
      _hasAppear = true;
      onRouteStart();
      onRouteResume();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didRunOnContextReady) {
      return;
    }
    // 拿不到 ModalRoute 时**不**置位，留到下一次 didChangeDependencies 重试：
    // 页面可能先于 Navigator 构建（如先作为普通子 Widget 挂上、随后才被塞进
    // 路由）。一次性放弃会让这类页面永久收不到本 mixin 的任何回调。
    // 已经 attach 成功后不会再走到这里，因此不存在重复订阅与重复挂动画监听。
    if (!_routeDelegate.attach(context)) {
      return;
    }
    _didRunOnContextReady = true;
    onPageContextReady(_routeDelegate.routeName, _routeDelegate.arguments);
  }

  @override
  void dispose() {
    _hasDispose = true;
    _routeDelegate.detach();
    if (_hasAppear) {
      onRoutePause();
      onRouteStop();
    }
    super.dispose();
  }

  /// 依赖就绪且成功拿到 `ModalRoute`，此时 [routeName] / [arguments] 可用。
  ///
  /// **可能永不触发**：页面不处于任何路由中时（`ModalRoute.of` 为 null），
  /// 本回调与两个转场动画回调都不会触发，[onRoutePause] / [onRouteStop] 也
  /// 只剩 `dispose` 时的补发。
  ///
  /// 但 [onRouteStart] / [onRouteResume] **仍会在首帧发出**——它们由首帧回调
  /// 驱动，不依赖路由，因此即使没有 `ModalRoute`，「首帧 start → dispose 时
  /// stop」这一对仍然是配对的。
  @protected
  void onPageContextReady(String? routeName, Object? arguments) {}

  /// 入场转场动画开始播放（`AnimationStatus.forward`）。
  ///
  /// **首次 push 入场时通常不会触发**：动画监听器在 [onPageContextReady]
  /// （首次 `didChangeDependencies`）中才绑定，而 Navigator 在更早的
  /// `didPush` 里就已把动画推进到 `forward`。需要「页面开始进场」这个时机，
  /// 请用 [onPageContextReady]。
  ///
  /// 实际能收到的主要是**动画折返**：iOS 侧滑返回中途放弃，动画由
  /// `reverse` 回到 `forward`，此时触发，随后是 [onPageEnterAnimationEnd]。
  @protected
  void onPageEnterAnimationStart() {}

  /// 入场转场动画播放完毕。iOS 侧滑返回中途放弃时会重复发出。
  @protected
  void onPageEnterAnimationEnd() {}

  /// 退场转场动画开始播放（`AnimationStatus.reverse`）。
  ///
  /// 触发来源：自身被 pop 时动画开始反向；iOS 侧滑返回手势开始拖动。
  ///
  /// **不代表页面一定会退出**：iOS 侧滑返回中途放弃时也会发出，随后是
  /// [onPageEnterAnimationStart] → [onPageEnterAnimationEnd] 而非
  /// [onPageLeaveAnimationEnd]。因此释放资源、上报离开埋点这类不可逆操作
  /// 应放在 [onPageLeaveAnimationEnd] 或 `dispose` 中。
  ///
  /// 与 [onRouteStop] 相互独立：普通 pop 时两者几乎同时发生，先后不作保证；
  /// 侧滑手势场景下本回调远早于 [onRouteStop]（手势确认返回后才 pop）。
  @protected
  void onPageLeaveAnimationStart() {}

  /// 退场转场动画播放完毕。
  @protected
  void onPageLeaveAnimationEnd() {}

  /// 本页重新入栈顶（上层非弹窗路由被 pop / remove）。
  @protected
  void onRouteStart() {}

  /// 本页重新可交互（上层弹窗被 pop）。
  @protected
  void onRouteResume() {}

  /// 本页被弹窗盖住。
  @protected
  void onRoutePause() {}

  /// 本页被非弹窗路由盖住，或自身被 pop / remove / replace。
  @protected
  void onRouteStop() {}

  ///*********************RouteAware 框架路由生命周期，**不允许子类重写***************************

  @internal
  @override
  void routePageStart() {
    if (_hasAppear) {
      return;
    }
    _hasAppear = true;
    onRouteStart();
    onRouteResume();
  }

  @internal
  @override
  void routePageResume() {
    onRouteResume();
  }

  @internal
  @override
  void routePagePause() {
    onRoutePause();
  }

  @internal
  @override
  void routePageStop() {
    if (!_hasAppear) {
      return;
    }
    // 与 routePageStart 一致：标志位先翻转再回调，回调里再次触发时能被挡住。
    _hasAppear = false;
    onRoutePause();
    onRouteStop();
  }
}
