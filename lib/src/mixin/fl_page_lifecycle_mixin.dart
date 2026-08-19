import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../delegate/fl_app_lifecycle_delegate.dart';
import '../delegate/fl_page_route_delegate.dart';
import '../delegate/fl_page_view_delegate.dart';
import '../lifecycle/fl_lifecycle_state.dart';
import '../lifecycle/lifecycle_route_aware.dart';

mixin FlPageLifecycleMixin<T extends StatefulWidget> on State<T>
    implements LifecycleRouteAware {
  bool _didRunOnContextReady = false;

  /// 路由相关处理（取路由、订阅路由事件、监听转场动画）全部委托给它。
  late final FlPageRouteDelegate _routeDelegate = FlPageRouteDelegate(
    host: this,
    onEnterAnimationStart: _handleEnterAnimationStart,
    onEnterAnimationEnd: _handleEnterAnimationEnd,
    onLeaveAnimationStart: _handleLeaveAnimationStart,
    onLeaveAnimationEnd: _handleLeaveAnimationEnd,
  );

  /// App 生命周期相关处理（前后台切换、AppLifecycleState）全部委托给它。
  late final FlAppLifecycleDelegate _appDelegate = FlAppLifecycleDelegate(
    onForeground: _handleAppForeground,
    onBackground: _handleAppBackground,
    onStateChanged: appLifecycleChanged,
  );

  /// PageView 相关处理（判断是否位于 PageView、监听页码变化）全部委托给它。
  late final FlPageViewDelegate _pageViewDelegate = FlPageViewDelegate(
    onPageShow: _notifyPageStart,
    onPageHide: _notifyPageStop,
    onIndexChanged: onPageViewChanged,
  );

  String? get routeName => _routeDelegate.routeName;

  Object? get arguments => _routeDelegate.arguments;

  /// 本页是否位于 `PageView` 中，即是否命中了 `FlPageViewScope`。
  /// 首次 `didChangeDependencies` 之前恒为 false。
  bool get isInPageView => _pageViewDelegate.isInPageView;

  /// 本页在 `PageView` 中的页码，由 `FlPageViewScope` 自动下发，**只读**。
  ///
  /// 不在 PageView 中（或首次 `didChangeDependencies` 之前）为 -1。
  int get pageIndex => _pageViewDelegate.pageIndex;

  /// 本页所在层当前展示的页码，未能确定时为 -1。
  int get currentPageIndex => _pageViewDelegate.currentIndex;

  /// `FlPageViewScope` 的嵌套深度，取值与 `ScrollNotification.depth` 对齐：
  /// 最外层为 0，每往里嵌一层（如 `PageView` 里再套 `TabBarView`）加一；
  /// 不在任何 Scope 中为 -1。
  int get pageViewDepth => _pageViewDelegate.depth;

  /// 是否启用 PageView 可见性判定，**默认 false**：不做判定，
  /// 页面首帧后直接按普通页面发出 start / resume。
  ///
  /// 页面位于 `PageView` / `TabBarView` 中（外面包了 `FlPageViewScope`）、
  /// 需要由页码而非路由驱动 start / stop 时，覆写它返回 true。
  ///
  /// **必须在整个生命周期内保持不变**，debug 下有断言把关。可见性状态机是
  /// 有状态的：中途翻转会留下对不齐的中间态——由 false 变 true 时，本页可能
  /// 已经在首帧发过 start，此刻却不是当前页，于是停在「屏幕外却是 started」；
  /// 由 true 变 false 时则可能停在「本该可见却是 stopped」。要动态控制可见性，
  /// 请改用 `FlPageViewScope` 的挂载与否，而不是翻这个开关。
  bool get observePageView => false;

  /// 是否订阅 App 前后台事件，**默认 false**：[onAppForeground] /
  /// [onAppBackground] / [appLifecycleChanged] 与对应的三个 App 枚举事件
  /// 都不发出，页面生命周期本身不受影响。需要这些事件时覆写它返回 true。
  ///
  /// 默认关掉是为了**摊薄实例成本**：打开后每个混入本 mixin 的 `State` 都会
  /// 订阅两条全局广播流，一次 App 前后台切换要在同一帧内同步 fan-out 给所有
  /// 存活实例。单个路由页可以忽略，但把 `FlPageView` 用在列表项上时
  /// （几百个实例）就很可观——只在真正需要 App 事件的页面上打开。
  ///
  /// **必须在整个生命周期内保持不变**：只在 `initState` 中读取一次，
  /// 运行时改变无效，debug 下有断言把关。
  bool get observeAppLifecycle => false;

  /// App 当前是否位于前台。不依赖任何生命周期时机，随时可读，
  /// 也不依赖 [observeAppLifecycle]（它同步读 `WidgetsBinding.lifecycleState`）。
  bool get isForeground => _appDelegate.isForeground;

  /// 本页当前是否可见，即已发出 [onPageStart] 且尚未发出 [onPageStop]。
  ///
  /// 用于在异步回调返回时判断「页面还在不在前台」，避免对已 stop 的页面做
  /// 刷新、埋点这类动作。
  bool get isPageAppeared => _hasAppeared;

  /// 本页当前是否可交互，即已发出 [onPageResume] 且尚未发出 [onPagePause]。
  bool get isPageResumed => _hasResume;

  /// 本页是不是**所在 Navigator** 的栈顶路由。实时查询，不缓存。
  ///
  /// 三个容易踩的点：
  ///
  /// - 被弹窗（`PopupRoute`）盖住时为 false，但此刻页面**仍然可见**——弹窗只
  ///   触发 [onPagePause] 不触发 [onPageStop]，判断可见性请用 [isPageAppeared]；
  /// - 嵌套 Navigator 时只反映**本层**：内层栈顶页即使整个内层 Navigator 被
  ///   外层路由盖住，这里依然是 true；
  /// - 转场动画期间就已经翻转：被 pop 的路由在动画**开始**时就不再是栈顶，
  ///   要判断转场真的结束请用 [onPageEnterAnimationEnd] /
  ///   [onPageLeaveAnimationEnd]。
  ///
  /// 不在任何路由中（`ModalRoute.of` 为 null）时为 false，因此**不要**拿它去
  /// 过滤生命周期事件——那会把非路由页面永久挡死。
  bool get isCurrent => _routeDelegate.isCurrent;

  bool _hasAppeared = false;
  bool _hasResume = false;
  bool _hasDispose = false;
  bool _hasPostFrame = false;

  /// 两个开关的首次取值，仅用于 debug 断言，见 [_debugCheckSwitchesStable]。
  bool? _debugObservePageView;
  bool? _debugObserveAppLifecycle;

  /// 两个开关都必须在整个生命周期内保持不变，翻转会让可见性状态机对不齐。
  bool _debugCheckSwitchesStable() {
    assert(() {
      _debugObservePageView ??= observePageView;
      _debugObserveAppLifecycle ??= observeAppLifecycle;
      assert(
        observePageView == _debugObservePageView,
        'observePageView 在运行时被改成了 $observePageView（初始为 '
        '$_debugObservePageView）。它必须在整个生命周期内保持不变，'
        '否则可见性状态机会停在对不齐的中间态。',
      );
      assert(
        observeAppLifecycle == _debugObserveAppLifecycle,
        'observeAppLifecycle 在运行时被改成了 $observeAppLifecycle（初始为 '
        '$_debugObserveAppLifecycle）。它只在 initState 读取一次，改了也不会生效。',
      );
      return true;
    }());
    return true;
  }

  @override
  void initState() {
    super.initState();
    assert(_debugCheckSwitchesStable());
    if (observeAppLifecycle) {
      _appDelegate.attach();
    }

    onPageInit();
    onLifecycleStateChanged(FlLifecycleState.onPageInit);
    WidgetsBinding.instance.addPostFrameCallback((timeStamp) {
      if (_hasDispose) {
        return;
      }
      _notifyPostFrame();
      _startIfNotInPageView();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // 判断本页是不是 PageView 的一页：`FlPageViewScope` 是 InheritedWidget，
    // 这里才是注册依赖的合法时机，Scope 变化（页码调整、控制器被换掉）也能
    // 通过重新进入本方法被感知到。这里只做绑定，不发出任何事件。
    assert(_debugCheckSwitchesStable());
    if (observePageView) {
      _pageViewDelegate.attach(context);
    }

    if (_didRunOnContextReady) {
      return;
    }
    // 拿不到 ModalRoute 时**不**置位，留到下一次 didChangeDependencies 重试：
    // 页面可能先于 Navigator 构建（如先作为普通子 Widget 挂上、随后才被塞进
    // 路由）。一次性放弃会让这类页面永久收不到 start / resume / pause / stop。
    // 已经 attach 成功后不会再走到这里，因此不存在重复订阅。
    if (!_routeDelegate.attach(context)) {
      return;
    }
    _didRunOnContextReady = true;
    onPageContextReady(_routeDelegate.routeName, _routeDelegate.arguments);
    onLifecycleStateChanged(FlLifecycleState.onPageContextReady);
  }

  @override
  void reassemble() {
    super.reassemble();
    if (kDebugMode) {
      onPageReassemble();
      onLifecycleStateChanged(FlLifecycleState.onPageReassemble);
    }
  }

  @override
  void dispose() {
    _hasDispose = true;
    // 开关关掉时委托从未被创建过，这里不去碰它——`late final` 一读就会实例化，
    // 只为了调一次空操作的 detach 不值得（列表里放几百个 FlPageView 时尤其）。
    if (observeAppLifecycle) {
      _appDelegate.detach();
    }
    // 这里用 _notifyPageStop 而非 _checkNotifyPageStop：页面已经在销毁，
    // 不该再用「是不是 PageView 当前页」去过滤。被滑走的子页在这一刻
    // isCurrentPage 已经是 false，走 check 会让它带着 _hasAppeared 直接销毁，
    // 收不到与 onPageStart 配对的 onPageStop。幂等由 _hasAppeared 保证。
    _notifyPageStop();
    _routeDelegate.detach();
    if (observePageView) {
      _pageViewDelegate.detach();
    }
    onPageDispose();
    onLifecycleStateChanged(FlLifecycleState.onPageDispose);
    super.dispose();
  }

  /// App 切换到前台，由 [_appDelegate] 回调。
  void _handleAppForeground() {
    onAppForeground();
    onLifecycleStateChanged(FlLifecycleState.onAppForeground);
  }

  /// App 切换到后台，由 [_appDelegate] 回调。
  void _handleAppBackground() {
    onAppBackground();
    onLifecycleStateChanged(FlLifecycleState.onAppBackground);
  }

  /// 入场转场动画播放开始，由 [_routeDelegate] 回调。
  void _handleEnterAnimationStart() {
    onPageEnterAnimationStart();
    onLifecycleStateChanged(FlLifecycleState.onPageEnterAnimationStart);
  }

  /// 入场转场动画播放完毕，由 [_routeDelegate] 回调。
  void _handleEnterAnimationEnd() {
    onPageEnterAnimationEnd();
    onLifecycleStateChanged(FlLifecycleState.onPageEnterAnimationEnd);
  }

  /// 退场转场动画播放开始，由 [_routeDelegate] 回调。
  void _handleLeaveAnimationStart() {
    onPageLeaveAnimationStart();
    onLifecycleStateChanged(FlLifecycleState.onPageLeaveAnimationStart);
  }

  /// 退场转场动画播放完毕，由 [_routeDelegate] 回调。
  void _handleLeaveAnimationEnd() {
    onPageLeaveAnimationEnd();
    onLifecycleStateChanged(FlLifecycleState.onPageLeaveAnimationEnd);
  }

  /// 首帧渲染完成后，为**不在 PageView 中**的页面发出 start。
  ///
  /// 位于 PageView 中的页面不走这里——start 要等页码切到本页，由
  /// [_pageViewDelegate] 回调 [_notifyPageStart]（首页在 `attach` 当场即可
  /// 确定，同样无需等待用户滑动）。
  ///
  /// 之所以留在首帧回调而不是跟着 `attach` 一起放进 `didChangeDependencies`：
  /// 这里是**同步**发出 start / resume 的，放进构建期会让宿主在回调里
  /// `setState` 直接报错。
  void _startIfNotInPageView() {
    if (observePageView && _pageViewDelegate.isInPageView) {
      return;
    }
    _notifyPageStart();
  }

  /// 本页是不是「可以接收路由事件」的那一页。
  ///
  /// 关掉 [observePageView] 时恒为 true，且**短路掉**对委托的访问——
  /// 否则 `late final` 会在这里被实例化出来，白白抵消掉关开关省下的成本。
  bool get _isCurrentPage =>
      !observePageView || _pageViewDelegate.isCurrentPage;

  void _checkNotifyPageStart() {
    if (!_isCurrentPage) {
      return;
    }
    _notifyPageStart();
  }

  void _checkNotifyPageResume() {
    if (_hasAppeared) {
      _notifyPageResume();
    }
  }

  void _checkNotifyPagePause() {
    if (_hasAppeared) {
      _notifyPagePause();
    }
  }

  void _checkNotifyPageStop() {
    if (!_isCurrentPage) {
      return;
    }
    _notifyPageStop();
  }

  /// 首帧回调，幂等。
  ///
  /// 抽出来是为了让 [_notifyPageStart] 能兜底补发：PageView 子页的 start 走
  /// 帧末队列，而队列的回调可能比本页自己的首帧回调注册得更早（同一帧里前一页
  /// 先排了队），不兜底的话 start 会跑到 [onPagePostFrame] 前面去。
  void _notifyPostFrame() {
    if (_hasPostFrame) {
      return;
    }
    _hasPostFrame = true;
    onPagePostFrame();
    onLifecycleStateChanged(FlLifecycleState.onPagePostFrame);
  }

  void _notifyPageStart() {
    if (_hasAppeared) {
      return;
    }
    // 保证 onPagePostFrame 一定早于 start：此时布局与绘制已完成，宿主在
    // onPageStart 里可以直接用上量到的尺寸。
    _notifyPostFrame();
    _hasAppeared = true;
    onPageStart();
    onLifecycleStateChanged(FlLifecycleState.onPageStart);
    _notifyPageResume();
  }

  void _notifyPageResume() {
    if (_hasResume) {
      return;
    }
    _hasResume = true;
    onPageResume();
    onLifecycleStateChanged(FlLifecycleState.onPageResume);
  }

  void _notifyPagePause() {
    if (!_hasResume) {
      return;
    }
    _hasResume = false;
    onPagePause();
    onLifecycleStateChanged(FlLifecycleState.onPagePause);
  }

  void _notifyPageStop() {
    if (!_hasAppeared) {
      return;
    }
    _hasAppeared = false;
    _notifyPagePause();
    onPageStop();
    onLifecycleStateChanged(FlLifecycleState.onPageStop);
  }

  ///*********************************************
  @protected
  void onPageInit() {}

  @protected
  void onPageContextReady(String? routeName, Object? arguments) {}

  @protected
  void onPagePostFrame() {}

  @protected
  void onPageReassemble() {}

  /// 入场转场动画开始播放（`AnimationStatus.forward`），
  /// 对应 [FlLifecycleState.onPageEnterAnimationStart]。
  ///
  /// **首次 push 入场时通常不会触发**：动画监听器在 [onPageContextReady]
  /// （首次 `didChangeDependencies`）中才由 [_routeDelegate] 绑定，
  /// 而 Navigator 在更早的 `didPush` 里就已把动画推进到 `forward`。
  /// 需要「页面开始进场」这个时机请用 [onPageContextReady]。
  ///
  /// 实际能收到的主要是动画折返：iOS 侧滑返回中途放弃，动画由 `reverse`
  /// 回到 `forward`，随后是 [onPageEnterAnimationEnd]。
  ///
  /// 与可见性状态机（[onPageStart] / [onPageResume]）无关，
  /// 不参与 `_hasAppeared` / `_hasResume` 判断，也没有幂等保证。
  @protected
  void onPageEnterAnimationStart() {}

  @protected
  void onPageStart() {}

  @protected
  void onPageResume() {}

  @protected
  void onPageEnterAnimationEnd() {}

  /// 退场转场动画开始播放（`AnimationStatus.reverse`），
  /// 对应 [FlLifecycleState.onPageLeaveAnimationStart]。
  ///
  /// 触发来源：自身被 pop 时动画开始反向；iOS 侧滑返回手势开始拖动。
  ///
  /// **不代表页面一定会退出**：侧滑手势中途放弃时也会触发，随后是
  /// [onPageEnterAnimationStart] → [onPageEnterAnimationEnd]，
  /// 而**不是** [onPageLeaveAnimationEnd]，页面也不会收到 pause / stop
  /// （从未真正 pop）。不可逆操作请放在 [onPageLeaveAnimationEnd] 或
  /// [onPageDispose]。
  ///
  /// 与 [onPageStop] 相互独立：普通 pop 时两者几乎同时，先后不作保证；
  /// 侧滑场景下本回调远早于 [onPageStop]（手势确认返回后才 pop）。
  @protected
  void onPageLeaveAnimationStart() {}

  @protected
  void onPagePause() {}

  @protected
  void onPageStop() {}

  @protected
  void onPageLeaveAnimationEnd() {}

  @protected
  void onPageDispose() {}

  @protected
  void onAppResume() {}

  @protected
  void onAppInactive() {}

  @protected
  void onAppPause() {}

  @protected
  void onAppForeground() {}

  @protected
  void onAppBackground() {}

  @protected
  @mustCallSuper
  void onLifecycleStateChanged(FlLifecycleState state) {}

  /// PageView 页码发生变化，参数为 (旧页码, 新页码)。
  ///
  /// 仅在 [isInPageView] 为 true 时触发，且**首次确定页码时不发出**
  /// （此时没有「旧页码」）。所有页都会收到，不只是 [pageIndex] 对应的那页。
  @protected
  void onPageViewChanged(int from, int to) {}

  ///*********************RouteAware 框架路由生命周期，**不允许子类重写***************************

  @internal
  @override
  @nonVirtual
  void routePageStart() {
    _checkNotifyPageStart();
  }

  @internal
  @override
  @nonVirtual
  void routePageResume() {
    _checkNotifyPageResume();
  }

  @internal
  @override
  @nonVirtual
  void routePagePause() {
    _checkNotifyPagePause();
  }

  @internal
  @override
  @nonVirtual
  void routePageStop() {
    _checkNotifyPageStop();
  }

  ///***********************************************************************************************
  @mustCallSuper
  @protected
  void appLifecycleChanged(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        onAppResume();
        onLifecycleStateChanged(FlLifecycleState.onAppResume);
        break;
      case AppLifecycleState.inactive:
        onAppInactive();
        onLifecycleStateChanged(FlLifecycleState.onAppInactive);
        break;
      case AppLifecycleState.paused:
        onAppPause();
        onLifecycleStateChanged(FlLifecycleState.onAppPause);
        break;
      default:
        break;
    }
  }
}
