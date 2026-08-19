import 'package:flutter/material.dart';

import 'package:meta/meta.dart';

import 'lifecycle_route_aware.dart';

class FlRouteObserver extends NavigatorObserver {
  static final FlRouteObserver instance = FlRouteObserver._();

  factory FlRouteObserver() => instance;

  FlRouteObserver._();

  final Map<Route<dynamic>, Set<LifecycleRouteAware>> _listeners =
      <Route<dynamic>, Set<LifecycleRouteAware>>{};

  @internal
  void subscribe(ModalRoute route, LifecycleRouteAware routeAware) {
    final subscribers = _listeners.putIfAbsent(
      route,
      () => <LifecycleRouteAware>{},
    );
    subscribers.add(routeAware);
  }

  /// 取消 [routeAware] 在 [route] 上的订阅。
  ///
  /// 订阅方自己知道挂在哪个路由上（`FlPageRouteDelegate._modalRoute`），
  /// 因此这里按 key 直接删，不遍历整张表——页面销毁是高频操作，而一个页面里
  /// 可能同时存在多个订阅者（如多个 `FlPageView`），它们会在同一帧集中销毁。
  ///
  /// [route] 已经被 pop / remove 时表内早已没有对应条目，此时是空操作。
  @internal
  void unsubscribe(ModalRoute route, LifecycleRouteAware routeAware) {
    final subscribers = _listeners[route];
    if (subscribers == null) {
      return;
    }
    subscribers.remove(routeAware);
    if (subscribers.isEmpty) {
      _listeners.remove(route);
    }
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPop(route, previousRoute);
    // remove route atomically: 通知后不再持有已 pop 的 route
    final subscribers = _listeners.remove(route)?.toList();
    if (subscribers != null) {
      for (final routeAware in subscribers) {
        routeAware.routePageStop();
      }
    }

    // popUntil 会连续 pop 多个路由，中间那些的 previousRoute 并没有露出来。
    if (!_didBecomeVisible(previousRoute)) {
      return;
    }
    final isPopup = route is PopupRoute;
    final previousSubscribers = _listeners[previousRoute]?.toList();
    if (previousSubscribers != null) {
      for (final routeAware in previousSubscribers) {
        if (isPopup) {
          routeAware.routePageResume();
        } else {
          routeAware.routePageStart();
        }
      }
    }
  }

  /// [route] 是不是**真的**因为上面那个消失而露了出来。
  ///
  /// `didPop` / `didRemove` 的 `previousRoute` 只是「被移除者在栈中的下一个」，
  /// 并不等于「新的栈顶」。两种常见情况下它仍被别的路由盖着：
  ///
  /// - `pushAndRemoveUntil`：新路由先 push 到顶，再逐个 remove 下面的旧路由，
  ///   每次 remove 的 previousRoute 都还在新路由底下；
  /// - `popUntil`：连续 pop 多个，中间几个的 previousRoute 转瞬又被 pop 掉。
  ///
  /// 不加这个判断，被盖住的页面会收到虚假的 start / resume，而且不会有配对的
  /// stop 来纠正——曝光埋点会把一个从没露面的页面记成可见。
  ///
  /// 用 `Route.isCurrent` 判定是安全的：`Navigator` 在 `_flushHistoryUpdates`
  /// 把整个历史整理完之后才 `_flushObserverNotifications`，此刻被 pop / remove
  /// 的条目已经进入 `popping` / `removing`，不再算 present，所以正常 pop 时
  /// 下面那个就是最后一个 present 项，判定为 true，不会被误伤。
  static bool _didBecomeVisible(Route<dynamic>? previousRoute) =>
      previousRoute?.isCurrent ?? false;

  @override
  void didRemove(Route route, Route? previousRoute) {
    super.didRemove(route, previousRoute);
    // remove route atomically: 通知后不再持有已移除的 route
    final subscribers = _listeners.remove(route)?.toList();
    if (subscribers != null) {
      for (final routeAware in subscribers) {
        routeAware.routePageStop();
      }
    }

    // pushAndRemoveUntil 会先把新路由 push 到顶再逐个 remove，
    // 此时 previousRoute 仍被新路由盖着，见 [_didBecomeVisible]。
    if (!_didBecomeVisible(previousRoute)) {
      return;
    }
    final previousSubscribers = _listeners[previousRoute]?.toList();
    if (previousSubscribers != null) {
      for (final routeAware in previousSubscribers) {
        routeAware.routePageStart();
      }
    }
  }

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    super.didPush(route, previousRoute);
    final previousSubscribers = _listeners[previousRoute]?.toList();
    final isPopup = route is PopupRoute;
    if (previousSubscribers != null) {
      for (final routeAware in previousSubscribers) {
        if (isPopup) {
          routeAware.routePagePause();
        } else {
          routeAware.routePageStop();
        }
      }
    }
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    super.didReplace(newRoute: newRoute, oldRoute: oldRoute);
    // pushReplacement: 旧路由立即从 _listeners 中移除
    if (oldRoute != null) {
      final subscribers = _listeners.remove(oldRoute)?.toList();
      if (subscribers != null) {
        for (final routeAware in subscribers) {
          routeAware.routePageStop();
        }
      }
    }
  }
}
