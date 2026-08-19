import 'package:flutter/material.dart';

/// 页面入场/退场动画感知 Mixin — 独立版
mixin FlAnimationLifecycleMixin<T extends StatefulWidget> on State<T> {
  Animation<double>? _routeAnimation;
  bool _disposed = false;
  bool _didRunOnContextReady = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_didRunOnContextReady) return;
    // 拿不到 ModalRoute 时不置位，留到下一次 didChangeDependencies 重试：
    // 页面可能先于 Navigator 构建，一次性放弃会让本 mixin 的回调永久失效。
    final modalRoute = ModalRoute.of(context);
    if (modalRoute == null) return;
    _didRunOnContextReady = true;
    _attachRouteAnimation(modalRoute.animation);
  }

  /// 绑定路由动画对象，自动监听动画状态变化
  void _attachRouteAnimation(Animation<double>? animation) {
    _detachRouteAnimation();
    _routeAnimation = animation;
    _routeAnimation?.addStatusListener(_handlerAnimationStatus);
  }

  /// 解绑当前路由动画
  void _detachRouteAnimation() {
    _routeAnimation?.removeStatusListener(_handlerAnimationStatus);
    _routeAnimation = null;
  }

  @override
  void dispose() {
    _disposed = true;
    _detachRouteAnimation();
    super.dispose();
  }

  /// forward → completed → reverse → dismissed
  void _handlerAnimationStatus(AnimationStatus status) {
    if (_disposed) return;
    switch (status) {
      case AnimationStatus.forward:
        onPageEnterAnimationStart();
        break;
      case AnimationStatus.completed:
        onPageEnterAnimationEnd();
        break;
      case AnimationStatus.reverse:
        onPageLeaveAnimationStart();
        break;
      case AnimationStatus.dismissed:
        onPageLeaveAnimationEnd();
        break;
    }
  }

  /// 入场动画开始（AnimationStatus.forward）
  ///
  /// 页面正在推入，此时页面尚未完全显示；适合做轻量准备工作，
  /// 避免在此执行耗时操作导致掉帧。
  @protected
  void onPageEnterAnimationStart() {}

  /// 入场动画结束（AnimationStatus.completed）
  ///
  /// 页面已完全显示且动画停止；适合执行首屏之后的耗时操作，
  /// 如网络请求、播放动画、自动聚焦输入框等。
  @protected
  void onPageEnterAnimationEnd() {}

  /// 退场动画开始（AnimationStatus.reverse）
  ///
  /// 页面正在退出（返回或被替换），此时页面仍然可见；
  /// 适合暂停视频/动画、收起键盘等。
  ///
  /// 注意：iOS 侧滑返回被取消时，动画会重新 forward，
  /// 因此该回调可能在同一次生命周期内多次触发。
  @protected
  void onPageLeaveAnimationStart() {}

  /// 退场动画结束（AnimationStatus.dismissed）
  ///
  /// 页面已完全移出屏幕；通常紧随其后会触发 [dispose]，
  /// 适合做最后的状态上报或资源释放。
  @protected
  void onPageLeaveAnimationEnd() {}
}
