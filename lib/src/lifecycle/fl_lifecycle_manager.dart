import 'dart:async';

import 'package:flutter/material.dart';

class FlLifecycleManager extends WidgetsBindingObserver {
  static final FlLifecycleManager instance = FlLifecycleManager._();

  FlLifecycleManager._();

  factory FlLifecycleManager() => instance;

  bool _hasListen = false;

  /// 标记是否从 paused 状态恢复
  ///
  /// 防止 resume 时 inactive→resumed 的短暂切换被误判为"从后台返回"。
  /// paused 时置 true，resumed 时消费后置 false。
  bool _isFromAppPause = false;

  /// 标记是否已经发送过初始前台事件（冷启动时首次 resumed）
  ///
  /// 用于区分冷启动的首次 resumed 和后续 inactive→resumed 短暂中断。
  /// listen() 时若 app 已处于 resumed 状态，也会将此置为 true。
  bool _hasEverSentForeground = false;

  /// 当前是否处于前台（同步读取，不依赖 stream）
  bool get isForeground =>
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  StreamController<bool> _streamController = StreamController<bool>.broadcast();

  /// 前台/后台状态流（true=前台，false=后台）
  ///
  /// 基于 _isFromAppPause 判断，过滤掉 inactive→resumed 的 transient 状态。
  /// 仅当 paused→resumed 完整经过时发送 true。
  ///
  /// ## 冷启动的那一次 true 只有首个订阅者收得到
  ///
  /// [listen] 时若 App 已处于 resumed，会补发一次 `true`（见 [listen]），
  /// 但控制它的 `_hasEverSentForeground` 是**全局**标志位：补发只发生一次，
  /// 之后创建的页面**永远等不到**这个初始事件。
  ///
  /// 因此不要用「收到过 foreground」来判断当前在不在前台——那是个事件流，
  /// 不是状态。要判断状态请直接读 [isForeground]，它同步读
  /// `WidgetsBinding.instance.lifecycleState`，任何时机都可用，
  /// 也不依赖有没有订阅过。
  Stream<bool> get stream {
    listen();
    return _streamController.stream;
  }

  StreamController<AppLifecycleState> _lifecycleController =
      StreamController<AppLifecycleState>.broadcast();

  /// 原始 AppLifecycleState 流（不过滤，透传所有状态）
  Stream<AppLifecycleState> get lifecycle {
    listen();
    return _lifecycleController.stream;
  }

  void listen() {
    if (_hasListen) {
      return;
    }
    _hasListen = true;
    if (_streamController.isClosed) {
      _streamController = StreamController<bool>.broadcast();
      _lifecycleController = StreamController<AppLifecycleState>.broadcast();
    }
    WidgetsBinding.instance.addObserver(this);

    // 冷启动时，Flutter 引擎可能已在 listen() 之前发出了 resumed 事件。
    // 通过 scheduleMicrotask 让 subscriber 有机会先 attach 到 stream，
    // 然后补发一个 foreground=true 事件。
    if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed &&
        !_hasEverSentForeground) {
      _hasEverSentForeground = true;
      scheduleMicrotask(() => _emitForeground(true));
    }
  }

  /// 停止监听并关闭两条流。
  ///
  /// ## ⚠️ 只用于测试 tearDown 与 App 退出
  ///
  /// 这是全局单例：每一个 `FlPageLifecycleMixin` / `FlAppLifecycleMixin` 都在
  /// `initState` 中订阅了 [stream] 与 [lifecycle]。一次 [cancel] 会关闭这两条流，
  /// **所有存活页面**的 App 生命周期回调就此永久失效——后续 [listen] 重建的是
  /// 新的 `StreamController`，老订阅者不会被迁移过去，也不会收到任何报错。
  ///
  /// 页面自己的订阅由 `FlAppLifecycleDelegate` 在 `dispose` 中释放，
  /// 无需也不应该调用本方法。
  void cancel() {
    if (!_hasListen) {
      return;
    }
    _hasListen = false;
    _isFromAppPause = false;
    _hasEverSentForeground = false;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_streamController.close());
    unawaited(_lifecycleController.close());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _emitLifecycle(state);
    _notifyObserver(state);
  }

  /// 两条流都要判 `isClosed` 再 add：[cancel] 关闭 controller 与
  /// `removeObserver` 生效之间存在竞态（微任务补发同理），关闭后再 add 会抛
  /// `Bad state: Cannot add event after closing`。与 `FlEventBus.fire` 的做法一致。
  void _emitForeground(bool isForeground) {
    if (_streamController.isClosed) {
      return;
    }
    _streamController.add(isForeground);
  }

  void _emitLifecycle(AppLifecycleState state) {
    if (_lifecycleController.isClosed) {
      return;
    }
    _lifecycleController.add(state);
  }

  /// AppLifecycleState 各状态调用时机
  ///
  /// ┌────────────────────┬──────────────────────────────────────────────┐
  /// │ 状态               │ 触发时机                                      │
  /// ├────────────────────┼──────────────────────────────────────────────┤
  /// │ resumed            │ 应用可见且可响应用户输入。                     │
  /// │                    │ iOS: applicationDidBecomeActive               │
  /// │                    │ Android: Activity.onResume → onWindowFocusChanged(true) │
  /// ├────────────────────┼──────────────────────────────────────────────┤
  /// │ inactive           │ 应用可见但不可响应输入（临时中断）。            │
  /// │                    │ iOS: applicationWillResignActive              │
  /// │                    │   - 电话来了 / 控制中心拉起 / App Switcher    │
  /// │                    │ Android: 多任务键 / 下拉通知栏                │
  /// │                    │ 典型序列: resumed → inactive → resumed (未离开App) │
  /// ├────────────────────┼──────────────────────────────────────────────┤
  /// │ hidden             │ (Flutter 3.13+) 应用被隐藏但仍可能可见于       │
  /// │                    │ App Switcher。                                │
  /// │                    │ iOS: applicationDidEnterBackground →          │
  /// │                    │   UISceneLifecycleState background            │
  /// │                    │ Android: Activity.onStop (部分设备)           │
  /// │                    │ 典型序列: inactive → hidden → paused          │
  /// ├────────────────────┼──────────────────────────────────────────────┤
  /// │ paused             │ 应用不可见（进入后台）。                       │
  /// │                    │ iOS: applicationDidEnterBackground            │
  /// │                    │ Android: Activity.onStop                      │
  /// │                    │ 此时应释放不可见的资源、暂停动画、停止定时器。  │
  /// ├────────────────────┼──────────────────────────────────────────────┤
  /// │ detached           │ (Flutter 3.13+) 应用从宿主视图分离。           │
  /// │                    │ Android 特有：Activity 被销毁但 Engine 缓存存活 │
  /// │                    │ iOS: 通常不会触发，除非 FlutterEngine 被手动释放 │
  /// │                    │ 典型序列: paused → detached                   │
  /// │                    │ 此时必须释放所有 Activity 级别资源（Camera、   │
  /// │                    │ Sensor、MethodChannel 注册），因为 Engine 仍   │
  /// │                    │ 可能被复用于新的 Activity。                    │
  /// └────────────────────┴──────────────────────────────────────────────┘
  ///
  /// 状态机流转（Flutter 3.13+）:
  ///
  /// iOS:
  ///   resumed ←→ inactive ←→ hidden ←→ paused
  ///                              ↑ 从 App Switcher 返回时跳过 paused
  ///
  /// Android:
  ///   resumed ←→ inactive ←→ paused → detached
  ///                              ↑ 冷启动新 Activity 时从 detached 重建
  ///                              resumeDetached → [inactive → resumed]
  void _notifyObserver(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        if (_isFromAppPause) {
          // 完整经历了 paused → ... → resumed，确认从后台返回
          _isFromAppPause = false;
          _hasEverSentForeground = true;
          _emitForeground(true);
        } else if (!_hasEverSentForeground) {
          // 冷启动首次 resumed（或 cancel→listen 后的首次 resumed），
          // 订阅者尚未收到初始 foreground 事件，补发。
          _hasEverSentForeground = true;
          _emitForeground(true);
        }
        // 若 _isFromAppPause == false && _hasEverSentForeground == true，
        // 说明只是 inactive → resumed 短暂中断，不触发 foreground 通知。
        break;
      case AppLifecycleState.hidden:
        // hidden 是 iOS 14+/Flutter 3.13+ 新增状态。
        // 介于 inactive 和 paused 之间，暂时不做前台/后台切换判断。
        break;
      case AppLifecycleState.inactive:
        // inactive 发生在前台短暂中断时（电话、通知栏）。
        // 不做前台/后台状态切换，等待后续是 resumed 还是 paused。
        break;
      case AppLifecycleState.paused:
        _isFromAppPause = true;
        _emitForeground(false);
        break;
      case AppLifecycleState.detached:
        // detached 时不重置 _isFromAppPause，保留 paused 标记
        // 以支持 Android Activity 销毁重建后 resumed 时能正确发送 foreground 事件。
        // 注意：不在此处发送 _streamController 事件，
        // 因为 detached 不改变"前台/后台"语义（已在 paused 时发送过 false）。
        break;
    }
  }
}
