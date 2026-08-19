# fl_state_lifecycle

Gives Flutter pages the visibility lifecycle layer that Android's `onResume` / iOS's `viewDidAppear` provide but Flutter lacks: **when a page is actually seen by the user, when it gets covered, and when it truly leaves**. It funnels four kinds of signals — routes, dialogs, app foreground/background, and `PageView` / `TabBarView` paging — into one set of paired, idempotent callbacks.

Flutter officially ships only `RouteObserver` + `RouteAware`. That doesn't distinguish dialogs from ordinary pages (`showDialog` and `push` both just emit `didPushNext`), offers no idempotency or pairing guarantees, requires manual `subscribe` / `unsubscribe`, and completely ignores the visibility of `PageView` children. This package handles all of that uniformly — mix it in and you're done, no manual init or disposal.

| Constraint | Version |
| --- | --- |
| Dart SDK | `>=3.1.0 <4.0.0` (Dart 3.x) |
| Flutter | `>=3.13.0` (Flutter 3.x, released alongside Dart 3.1; `AppLifecycleState.hidden` is available from that version on) |
| Dependencies | Only `meta`, no third-party runtime dependencies |

### What's missing in Flutter itself

Native Android / iOS pages (`Activity` / `UIViewController`) come with a full set of callbacks spanning "created → visible → interactive → unfocused → invisible → destroyed". Flutter's `State`, by contrast, only has **the two ends**:

- `initState` / `dispose` correspond to `onCreate` / `onDestroy`;
- everything in between — the **visibility** part — is blank.

The crux: a route covered by a new page **is not destroyed**. Its `State` stays alive, `build` isn't even called again, and Flutter gives you no notification whatsoever. So a requirement like "pause the video when the page gets covered" has no directly usable callback in Flutter.

The official `RouteObserver` + `RouteAware` only solves half of it: it doesn't distinguish dialogs from ordinary pages (`showDialog` and `push` both only emit `didPushNext`), it has no idempotency or pairing guarantees, it needs manual `subscribe` / `unsubscribe`, and it doesn't cover `PageView` / `TabBarView` children at all — which natively map to `ViewPager`'s `setMaxLifecycle` or the `viewDidAppear` of a `UIPageViewController` child controller, but in Flutter produce **no signal at all**.

### Mapping to native lifecycles

| Android `Activity` | iOS `UIViewController` | fl_state_lifecycle |
| --- | --- | --- |
| `onCreate` | `viewDidLoad` | `onPageInit` (route arguments have to wait for `onPageContextReady`) |
| — | `viewDidLayoutSubviews` | `onPagePostFrame` (first frame done, sizes readable) |
| `onStart` | `viewWillAppear` | `onPageStart` |
| `onResume` | — | `onPageResume` |
| `onWindowFocusChanged(true)` | `viewDidAppear` | `onPageEnterAnimationEnd` |
| `onPause` | `viewWillDisappear` | `onPagePause` |
| `onStop` | `viewDidDisappear` | `onPageStop` |
| `onDestroy` | `deinit` | `onPageDispose` |

⚠️ **One timing difference**: this package's `onPageStart` / `onPageResume` fire when the **transition animation starts** (aligned with `Navigator`'s `didPush` / `didPop`), whereas iOS's `viewDidAppear` is called only after the animation **finishes**. When you need the moment "the UI has settled" (impression tracking, auto-focusing a text field, playing the first frame), use `onPageEnterAnimationEnd`.

### Occlusion semantics compared

| Scenario | Android | iOS | fl_state_lifecycle |
| --- | --- | --- | --- |
| Fully covered by an opaque page | `onPause` → `onStop` | `viewWillDisappear` → `viewDidDisappear` | `onPagePause` → `onPageStop` |
| Covered by a dialog / translucent page | `onPause`, **no** `onStop` | Depends on `modalPresentationStyle`; `overFullScreen` doesn't fire it | Only `onPagePause` |
| App goes to background | `onPause` → `onStop` | `applicationDidEnterBackground` | `onAppBackground`, **page events unchanged** |

For the first two rows this package matches native semantics: `pause` = lost focus but possibly still visible, `stop` = fully invisible.

**The third row is a deliberate difference.** Android merges "covered by another page" and "app went to background" into the same `onPause` / `onStop` pair, which makes it impossible for app code to tell the two apart. This package splits them into two independent channels: route visibility goes through `onPageStart` / `onPageStop`, and app foreground/background goes through `onAppForeground` / `onAppBackground`. If you want Android's merged semantics, merge them yourself:

```dart
import 'package:flutter/material.dart';
import 'package:fl_state_lifecycle/fl_state_lifecycle.dart';

class VideoPage extends StatefulWidget {
  const VideoPage({super.key});

  @override
  State<VideoPage> createState() => _VideoPageState();
}

class _VideoPageState extends State<VideoPage> with FlPageLifecycleMixin {
  final _player = _Player(); // swap in your own player
  bool _pageVisible = false;

  /// The app foreground/background callbacks are off by default; turn them on.
  @override
  bool get observeAppLifecycle => true;

  /// Equivalent to Android's "onResume and the window has focus":
  /// the page is visible **and** the app is in the foreground.
  void _sync() {
    if (_pageVisible && isForeground) {
      _player.play();
    } else {
      _player.pause();
    }
  }

  @override
  void onPageResume() {
    _pageVisible = true;
    _sync();
  }

  @override
  void onPagePause() {
    _pageVisible = false;
    _sync();
  }

  @override
  void onAppForeground() => _sync();

  @override
  void onAppBackground() => _sync();

  @override
  Widget build(BuildContext context) => const SizedBox();
}

class _Player {
  void play() {}
  void pause() {}
}
```

> App events are broadcast to **every live page**, including the ones currently invisible. That's why the code above must check both `_pageVisible` and `isForeground` together instead of relying on app events alone.

---

## ✨ Features

**What it does**

- **A paired, idempotent visibility state machine**: `onPageStart` is always followed by `onPageResume`, and `onPagePause` is always emitted before `onPageStop`; duplicate triggers are swallowed by internal flags, so you don't have to de-duplicate yourself.
- **Distinguishes "covered by a dialog" from "covered by a page"**: `PopupRoute` (dialog / bottomSheet / PopupMenu) only emits `onPagePause` and the page stays visible; only ordinary routes emit `onPageStop`.
- **`PageView` / `TabBarView` child visibility**: paging drives start / stop, with arbitrary nesting supported (when an outer `PageView` slides away, the current child of an inner `TabBarView` gets a stop as well).
- **App foreground/background**: distinguishes "genuinely backgrounded and came back" from brief interruptions like pulling down the notification shade or taking a call — both semantics are provided.
- **Route transition animation timing**: the start and end of the enter / exit animations, so you can defer heavy work until the transition finishes.
- **One unified sink for 18 events**: `onLifecycleStateChanged(FlLifecycleState)` receives every event in a single method, handy for analytics hookup.
- **Trim to taste**: use `FlPageRouteMixin` for routes only, `FlAppLifecycleMixin` for foreground/background only, `FlAnimationLifecycleMixin` for transition animations only.
- **Non-widget classes can receive events too**: `FlPageControllerMixin` lets a Controller / ViewModel get page lifecycle directly.
- **Subscriptions clean themselves up**: every listener unbinds automatically with `State.dispose`; there is no object you have to cancel by hand.

**What it does not do**

- **No pixel-level visibility detection**: it is unaware of a widget being occluded by another widget, scrolled off screen, or pushed away by the keyboard. If you need "what percentage of the element is exposed", use something like `visibility_detector`.
- **No list item impressions**: items of a `ListView` / `GridView` entering and leaving the screen are out of scope.
- **It doesn't take over routing**: it doesn't replace `Navigator` and doesn't change any navigation behavior — it only observes as a `NavigatorObserver`.
- **It doesn't infer the render tree**: the page index of a `PageView` child must be passed down explicitly by the builder via `FlPageViewScope`; no ancestor-walking guesswork.
- **No cross-isolate / background task keep-alive.**

---

## 🎯 Use Cases

**Good fit**

| Scenario | Usage |
| --- | --- |
| Page impression tracking, dwell-time stats | Start timing in `onPageResume`, end in `onPagePause` |
| Pausing and resuming video / animation / live streams | Pause in `onPagePause`, resume in `onPageResume` |
| Starting and stopping polling, long-lived connections, sensors | Subscribe in `onPageStart`, release in `onPageStop` |
| Refreshing data after returning from a child page | `onPageResume` (note: closing a dialog triggers it too) |
| Lazy loading and releasing in a multi-tab home page | `FlPageViewScope` + `onPageStart` / `onPageStop` |
| Re-validating login state when the app returns to the foreground | `onAppForeground` (brief interruptions already filtered out) |
| Forwarding lifecycle to a Controller / ViewModel | `FlPageControllerMixin` |

**Not recommended**

- List item impression stats — this package is unaware of items entering and leaving the screen.
- Cases needing "visible area ratio" or "is it occluded" precision — this package only answers "is this page the one currently being shown".
- Pages not inside any `Navigator` (a purely embedded subtree) — all route events are inert, leaving only `onPageInit` / `onPagePostFrame` / `onPageDispose` plus app events.
- Hundreds or thousands of instances in one page (e.g. wrapping every list item in a `FlPageView`) — see the per-instance cost note in [Notes](#-notes).

---


## 📖 Basic Usage

**Two steps**: register `FlRouteObserver` in `navigatorObservers`, then mix `FlPageLifecycleMixin` into your page's `State`.

> If `FlRouteObserver` isn't registered, none of the route-related callbacks fire (in debug mode you get a one-time console hint).

```dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fl_state_lifecycle/fl_state_lifecycle.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      // Step 1: register the route observer; nested Navigators each need their own registration
      navigatorObservers: [FlRouteObserver.instance],
      home: const DemoPage(),
    );
  }
}

class DemoPage extends StatefulWidget {
  const DemoPage({super.key});

  @override
  State<DemoPage> createState() => _DemoPageState();
}

// Step 2: mix in FlPageLifecycleMixin
class _DemoPageState extends State<DemoPage> with FlPageLifecycleMixin {
  Timer? _timer;

  @override
  void onPageStart() {
    debugPrint('Page visible, start subscribing to data');
  }

  @override
  void onPageResume() {
    // Page is interactive: resume polling, report the impression
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _poll());
  }

  @override
  void onPagePause() {
    // Being covered by a dialog also lands here, and the page is still visible
    _timer?.cancel();
    _timer = null;
  }

  @override
  void onPageStop() {
    debugPrint('Page fully invisible, release the heavier resources');
  }

  void _poll() {}

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('fl_state_lifecycle')),
      body: Center(
        child: ElevatedButton(
          onPressed: () => showDialog<void>(
            context: context,
            builder: (_) => const AlertDialog(
              content: Text('A dialog only triggers onPagePause, never onPageStop'),
            ),
          ),
          child: const Text('Open dialog'),
        ),
      ),
    );
  }
}
```

When the page is a `StatelessWidget`, or mixing into `State` is inconvenient, wrap it in `FlPageView` — the capabilities are exactly equivalent:

```dart
FlPageView(
  onStateChanged: (context, state) => debugPrint('Event: ${state.name}'),
  child: const DetailBody(),
)
```

---

## 📚 Exposed API

### 1. Core: `FlRouteObserver` (registration required)

A singleton implementation of `NavigatorObserver`; it is the event source for the whole package.

| Member | Type | Description |
| --- | --- | --- |
| `FlRouteObserver.instance` | `FlRouteObserver` | The singleton. `FlRouteObserver()` is a factory alias for it; the two are equivalent |

```dart
MaterialApp(navigatorObservers: [FlRouteObserver.instance], home: HomePage());
```

### 2. `FlPageLifecycleMixin` (full page lifecycle)

`on State<T>`; mix it in and it works, with no manual init or disposal.

**Read-only properties**

| Property | Type | Description |
| --- | --- | --- |
| `routeName` | `String?` | Route name, readable after `onPageContextReady` |
| `arguments` | `Object?` | Route arguments, same as above |
| `isCurrent` | `bool` | Whether this is the top route of **its own Navigator**. ⚠️ It's `false` while covered by a dialog (even though the page is in fact still visible); use `isPageAppeared` to judge visibility |
| `isPageAppeared` | `bool` | Whether currently visible (`onPageStart` emitted and `onPageStop` not yet) |
| `isPageResumed` | `bool` | Whether currently interactive (`onPageResume` emitted and `onPagePause` not yet) |
| `isForeground` | `bool` | Whether the app is in the foreground; readable at any time, independent of any subscription |
| `isInPageView` | `bool` | Whether a `FlPageViewScope` was matched; always `false` before the first `didChangeDependencies` |
| `pageIndex` | `int` | This page's index within its enclosing `PageView`, passed down automatically by the Scope; `-1` when not inside one |
| `currentPageIndex` | `int` | The index currently shown at this page's level; `-1` when undetermined |
| `pageViewDepth` | `int` | Scope nesting depth: `0` for the outermost, +1 per nesting level, `-1` when not in a Scope |

**Overridable switches**

| Member | Type | Default | Description |
| --- | --- | --- | --- |
| `observePageView` | `bool` | `false` | Whether to enable PageView visibility resolution; must be overridden to `true` for pages inside a `PageView` / `TabBarView`. **Must stay constant throughout**; asserted in debug |
| `observeAppLifecycle` | `bool` | `false` | Whether to subscribe to app foreground/background (two broadcast stream subscriptions per instance). Override to `true` if you need the app events. Read only once in `initState`, so it **must stay constant throughout** |

**Lifecycle callbacks** (all `@protected`, in typical firing order)

| Callback | When it fires |
| --- | --- |
| `onPageInit()` | Inside `initState`. `ModalRoute` isn't available and `context` can't look up an `InheritedWidget`. **Fires exactly once, and is always the first event** |
| `onPageContextReady(String? routeName, Object? arguments)` | On the first `didChangeDependencies` **and only if a `ModalRoute` was obtained**. Fires once; **never fires** when not inside a route |
| `onPagePostFrame()` | First frame rendered, sizes safe to read. **Guaranteed to precede this page's `onPageStart`** |
| `onPageStart()` | The page becomes visible. Sources: first frame / a route above it popped / a route above it removed / the `PageView` slid to this page |
| `onPageResume()` | The page becomes interactive; automatically follows `onPageStart` once |
| `onPageEnterAnimationStart()` | Enter animation starts (`forward`). ⚠️ Usually not received on the first push — see the FAQ |
| `onPageEnterAnimationEnd()` | Enter animation finished (`completed`) |
| `onPagePause()` | Interaction focus lost; **may still be visible** (this is the only event when covered by a dialog) |
| `onPageStop()` | Fully invisible; **`onPagePause` is emitted automatically beforehand** |
| `onPageLeaveAnimationStart()` | Exit animation starts (`reverse`). ⚠️ Does not mean the page will definitely leave |
| `onPageLeaveAnimationEnd()` | Exit animation finished (`dismissed`) |
| `onPageReassemble()` | Hot reload; **Debug mode only** |
| `onPageDispose()` | Inside `dispose`; **this is the last event** |
| `onAppResume()` / `onAppInactive()` / `onAppPause()` | Raw `AppLifecycleState`, unfiltered |
| `onAppForeground()` / `onAppBackground()` | **Filtered** foreground/background; brief interruptions like `inactive → resumed` don't fire them |
| `onPageViewChanged(int from, int to)` | The index at this level changed. Only fires when a Scope was matched, and not when the index is determined for the first time |
| `onLifecycleStateChanged(FlLifecycleState state)` | **The unified sink**: all 18 events in the table above pass through here after their dedicated callback. Overrides must call `super` (`@mustCallSuper`) |
| `appLifecycleChanged(AppLifecycleState state)` | The raw state dispatch entry point. Overrides must call `super` (`@mustCallSuper`) |

### 3. `FlLifecycleState` (the event enum)

The 18 values emitted by `onLifecycleStateChanged`, one per callback in the table above: `onPageInit`, `onPageContextReady`, `onPagePostFrame`, `onPageReassemble`, `onPageEnterAnimationStart`, `onPageStart`, `onPageResume`, `onPageEnterAnimationEnd`, `onPageLeaveAnimationStart`, `onPagePause`, `onPageStop`, `onPageLeaveAnimationEnd`, `onPageDispose`, `onAppResume`, `onAppInactive`, `onAppPause`, `onAppForeground`, `onAppBackground`.

| Extension property | Type | Description |
| --- | --- | --- |
| `isPageResume` | `bool` | Whether it is `onPageResume` |
| `isPagePause` | `bool` | Whether it is `onPagePause` |

### 4. `FlPageView` (the widget form)

Wrap a subtree to get exactly the same events as the mixin; `build` returns `child` untouched, introducing no extra layout node.

| Constructor parameter | Type | Required | Default | Description |
| --- | --- | --- | --- | --- |
| `child` | `Widget` | ✅ | — | The observed subtree |
| `observePageView` | `bool` | ❌ | `false` | Whether to enable PageView resolution; pass `true` for pages inside a `PageView` / `TabBarView`. Must always be passed the same value |
| `observeAppLifecycle` | `bool` | ❌ | `false` | Whether to subscribe to app foreground/background; pass `true` if you need the app events. Must always be passed the same value |
| `onStateChanged` | `FlPageLifecycleCallback?` | ❌ | `null` | `(BuildContext, FlLifecycleState)`, all 18 events |
| `onRouteParam` | `FlPageRouteParamCallback?` | ❌ | `null` | `(BuildContext, String?, Object?)`, corresponds to `onPageContextReady` |
| `onPageViewChanged` | `FlPageViewChangedCallback?` | ❌ | `null` | `(BuildContext, int from, int to)`, index changes |

### 5. `FlPageViewScope` (PageView / TabBarView visibility)

The **party building the `PageView`** passes "page index + controller" down. For child pages that match it, visibility becomes paging-driven.

| Constructor parameter | Type | Required | Description |
| --- | --- | --- | --- |
| `pageIndex` | `int` | ✅ | The child page's index |
| `controller` | `Listenable` | ✅ | The actual type must be `PageController` or `TabController`; asserted at construction |
| `child` | `Widget` | ✅ | The child page |

| Static method | Returns | Description |
| --- | --- | --- |
| `wrapItemBuilder({controller, builder})` | `NullableIndexedWidgetBuilder` | Wraps `PageView.builder`'s `itemBuilder`, injecting a Scope per page. Items that return `null` pass through unchanged |
| `wrapChildren({controller, children})` | `List<Widget>` | Wraps the child list of a `TabBarView` / `PageView`; the list index is the page index |
| `depthOf(BuildContext)` | `int` | The Scope nesting depth of the given context; `-1` when not in a Scope |
| `indexOf(Listenable)` | `int?` | Reads the controller's current index (past the halfway point counts as switched); returns `null` before the first layout or when multiple `PageView`s share one controller |
| `initialIndexOf(Listenable)` | `int` | The controller's initial index, as a fallback when `indexOf` is unavailable |
| `listenableOf(Listenable)` | `Listenable` | Which object to subscribe to in order to observe page switches (`TabController` requires subscribing to its `animation`) |

`FlPageViewVisibility` (the read-only snapshot the Scope pushes down): `visible` / `currentIndex` / `depth`.

### 6. The three trim-to-taste mixins

| Mixin | Provides | Read-only properties |
| --- | --- | --- |
| `FlPageRouteMixin` | `onPageContextReady`, the four transition animation callbacks, `onRouteStart` / `onRouteResume` / `onRoutePause` / `onRouteStop`. **Forwarded as-is, with no idempotency or backfill** | `modalRoute`, `routeName`, `arguments`, `isCurrent`, `hasRoute` |
| `FlAppLifecycleMixin` | `onAppForeground`, `onAppBackground`, `appLifecycleChanged` | `isForeground`, `hasInit` |
| `FlAnimationLifecycleMixin` | Only the four transition animation callbacks | — |

> **Don't stack** these three on top of `FlPageLifecycleMixin` — the latter already includes all of their capabilities.

### 7. `FlPageControllerMixin` (for non-widget classes)

It **subscribes to no event source at all**; it only provides "an entry point + template callbacks + state caching". Events must be forwarded from the page side.

| Member | Type | Description |
| --- | --- | --- |
| `onLifecycleChanged(FlLifecycleState state, {BuildContext? context})` | `void` | **The event entry point**, called from the page side. Overrides must call `super` (`@mustCallSuper`) |
| `setupRouteInfo(String? name, Object? arguments)` | `void` | Written from the page side to record route info, typically called once in `onPageContextReady` |
| `onPageViewChanged(int from, int to)` | `void` | Index changes. **Not dispatched through `onLifecycleChanged`**; the page side must forward it separately |
| `lifecycleState` | `FlLifecycleState` | The most recently received event; initially `onPageInit` |
| `isPageResume` / `isPagePause` | `bool` | Whether the last event was the corresponding value |
| `isForeground` | `bool` | Whether the app is in the foreground |
| `routeName` / `arguments` | `String?` / `Object?` | Written by `setupRouteInfo` |

The template callbacks share the names used by `FlPageLifecycleMixin`, plus one callback that takes a parameter: `onPageContextReady(BuildContext? context)`.

### 8. The event bus

| Class / Mixin | Member | Description |
| --- | --- | --- |
| `FlStateEventBusMixin` | `observeEvent<T>(void Function(T) onData)` | Subscribe to events; **cancelled automatically with `dispose`**. ⚠️ Should only be called in `initState` |
| | `dispatchEvent<T>(T event)` | Publish an event |
| `FlGlobalEventBus` | `observeEvent<T>()` → `Stream<T>` | Static subscription entry point |
| | `dispatchEvent<T>(T event)` | Static publishing entry point |
| | `configure(FlIEventBus bus)` | Inject an implementation (usually for test mocks). ⚠️ A global operation |
| | `destroy()` → `Future<void>` | Destroy the bus. ⚠️ A global operation; see Notes |
| | `reset()` | Equivalent to `destroy` but without awaiting |
| `FlEventBus` | `FlEventBus({bool sync = false})` | The default implementation (broadcast) |
| | `FlEventBus.customController(StreamController)` | A custom controller |
| | `on<T>()` / `fire(dynamic)` / `destroy()` | Subscribe / publish / destroy |
| `FlIEventBus` | `on<T>()`, `fire()`, `destroy()` | The abstract interface, to make mock injection easy |

### 9. `FlLifecycleManager` (the app foreground/background singleton)

| Member | Type | Description |
| --- | --- | --- |
| `FlLifecycleManager.instance` | `FlLifecycleManager` | The singleton |
| `isForeground` | `bool` | Reads `WidgetsBinding.lifecycleState` **synchronously**; usable at any time, no subscription needed |
| `stream` | `Stream<bool>` | The filtered foreground/background stream (`true` = foreground) |
| `lifecycle` | `Stream<AppLifecycleState>` | The raw, unfiltered state stream |
| `listen()` | `void` | Start listening; called automatically on first access to `stream` / `lifecycle` |
| `cancel()` | `void` | ⚠️ A global operation that permanently disables app events for **every live page**; use it only in tests and on app exit |

---

## 🔧 Advanced Usage

### 1. Visibility of `PageView` / `TabBarView` children

The page index is passed down by the builder via `FlPageViewScope`; child pages **don't need** to declare which page they are.

```dart
import 'package:flutter/material.dart';
import 'package:fl_state_lifecycle/fl_state_lifecycle.dart';

class TabsPage extends StatefulWidget {
  const TabsPage({super.key});

  @override
  State<TabsPage> createState() => _TabsPageState();
}

class _TabsPageState extends State<TabsPage> {
  final _controller = PageController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: PageView.builder(
        controller: _controller,
        itemCount: 3,
        // The key part: wrap in a Scope to pass the index and controller down to the children
        itemBuilder: FlPageViewScope.wrapItemBuilder(
          controller: _controller,
          builder: (context, index) => TabBody(index: index),
        ),
      ),
    );
  }
}

class TabBody extends StatefulWidget {
  const TabBody({super.key, required this.index});

  final int index;

  @override
  State<TabBody> createState() => _TabBodyState();
}

class _TabBodyState extends State<TabBody> with FlPageLifecycleMixin {
  /// PageView resolution is off by default; children inside a Scope must turn it on.
  @override
  bool get observePageView => true;

  // Fires when you slide to this page, with no extra signal needed;
  // the first page is resolved as current on the first frame
  @override
  void onPageStart() => debugPrint('Page ${widget.index} visible (pageIndex=$pageIndex)');

  @override
  void onPageStop() => debugPrint('Page ${widget.index} slid away');

  @override
  void onPageViewChanged(int from, int to) => debugPrint('Index $from -> $to');

  @override
  Widget build(BuildContext context) => Center(child: Text('Tab ${widget.index}'));
}
```

For `TabBarView`, use `wrapChildren`:

```dart
TabBarView(
  controller: tabController,
  children: FlPageViewScope.wrapChildren(
    controller: tabController,
    children: const [PageA(), PageB()],
  ),
)
```

Nesting needs no extra handling: when an outer `PageView` slides away, the current child of an inner `TabBarView` receives `onPageStop` too, and they both get `onPageStart` when you slide back.

### 2. Forwarding lifecycle to a Controller / ViewModel

`FlPageControllerMixin` subscribes to no event source, so the page side must forward events.

```dart
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:fl_state_lifecycle/fl_state_lifecycle.dart';

class DetailController with FlPageControllerMixin {
  Timer? _timer;

  @override
  void onPageContextReady(BuildContext? context) {
    debugPrint('Route arguments: $arguments');
  }

  @override
  void onPageResume() {
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
  }

  @override
  void onPagePause() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void onPageDispose() => _timer?.cancel(); // this mixin has no auto-release; clean up yourself

  void _refresh() {}
}

class DetailPage extends StatefulWidget {
  const DetailPage({super.key});

  @override
  State<DetailPage> createState() => _DetailPageState();
}

class _DetailPageState extends State<DetailPage> with FlPageLifecycleMixin {
  final _controller = DetailController();

  @override
  void onLifecycleStateChanged(FlLifecycleState state) {
    super.onLifecycleStateChanged(state); // required
    _controller.onLifecycleChanged(state, context: context);
  }

  @override
  void onPageContextReady(String? routeName, Object? arguments) {
    _controller.setupRouteInfo(routeName, arguments);
  }

  // Index changes aren't part of FlLifecycleState, so forward them separately
  @override
  void onPageViewChanged(int from, int to) =>
      _controller.onPageViewChanged(from, to);

  @override
  Widget build(BuildContext context) => const SizedBox();
}
```

If you'd rather not mix into `State`, `FlPageView` achieves the same thing:

```dart
FlPageView(
  onStateChanged: (context, state) =>
      controller.onLifecycleChanged(state, context: context),
  onRouteParam: (_, name, args) => controller.setupRouteInfo(name, args),
  child: const DetailBody(),
)
```

### 3. Deferring heavy work until the transition animation ends

Decoding large images, building complex lists, or auto-showing an onboarding overlay as the first screen enters easily drops frames during the transition.

```dart
import 'package:flutter/material.dart';
import 'package:fl_state_lifecycle/fl_state_lifecycle.dart';

class HeavyPage extends StatefulWidget {
  const HeavyPage({super.key});

  @override
  State<HeavyPage> createState() => _HeavyPageState();
}

class _HeavyPageState extends State<HeavyPage> with FlPageLifecycleMixin {
  List<Widget> _items = const [];

  @override
  void onPageEnterAnimationEnd() {
    // Build the heavy list after the animation finishes, so it doesn't
    // compete for the main thread during the transition
    setState(() => _items = _buildHeavyList());
  }

  @override
  void onPageLeaveAnimationEnd() {
    // Unlike onPageEnterAnimationStart, this means "it really did leave",
    // making it the right place for irreversible work like reporting a leave event
    debugPrint('The page really did leave');
  }

  List<Widget> _buildHeavyList() => const [];

  @override
  Widget build(BuildContext context) => ListView(children: _items);
}
```

---

## ⚠️ Notes

**Routes**

- **`FlRouteObserver` must be registered**, and **nested `Navigator`s each need their own registration**. Without it, all route-related callbacks silently do nothing; in debug mode the console prints a one-time hint.
- Dialogs (`PopupRoute`) only trigger `onPagePause` / `onPageResume`, never `onPageStop`. So **when you refresh data in `onPageResume`, account for the fact that closing a dialog triggers it too**.
- With `pushAndRemoveUntil`, the layer that stays on the stack but is covered by the new page **does not** receive `onPageStart`.
- When `popUntil` pops several layers at once, each skipped intermediate layer receives a transient `start → resume → pause → stop` pair — `Navigator.popUntil` is a loop of individual `pop()` calls, so intermediate layers really do briefly become the top of the stack. This is paired and self-correcting; filter it as needed for analytics.
- `isCurrent` means "top of its own Navigator", which is not the same as "visible": it's `false` while covered by a dialog, a nested Navigator only reflects its own level, and it flips as early as during the transition animation. Use `isPageAppeared` to judge visibility.

**context**

- Neither `onPageInit` (inside `initState`) nor `onPageDispose` (the `State` is unmounting) **can look up an `InheritedWidget`** (`Theme.of` / `MediaQuery.of` / `ModalRoute.of`) — it throws. Fetch whatever you need ahead of time in `onPageContextReady`.
- `onPageContextReady` is the earliest point at which `routeName` / `arguments` are readable.

**Animation**

- `onPageEnterAnimationStart` **usually isn't received on the first push**: the animation listener is only bound in `onPageContextReady`, while Navigator has already driven the animation to `forward` in the earlier `didPush`. If you need "the page started entering", use `onPageContextReady`.
- `onPageLeaveAnimationStart` **does not mean the page will definitely leave**: abandoning an iOS swipe-back mid-gesture also triggers it, followed by `onPageEnterAnimationStart` → `onPageEnterAnimationEnd` rather than `onPageLeaveAnimationEnd`. Put irreversible work in `onPageLeaveAnimationEnd` or `onPageDispose`.

**State and the switches**

- `observePageView` / `observeAppLifecycle` **must stay unchanged for the whole lifecycle**; asserted in debug. The visibility state machine is stateful, and flipping mid-flight leaves misaligned intermediate states behind.
- A `PageView` child **that isn't wrapped in `FlPageViewScope` is treated as an ordinary page**: start fires on the first frame, and visibility no longer follows paging.

**Global singletons**

- `FlGlobalEventBus.destroy()` / `configure()` and `FlLifecycleManager.cancel()` are all **global operations**: they silently invalidate the subscriptions of every live page (after receiving done, they don't migrate to a newly created instance). **They should only be called in a test `tearDown` or on app exit** — never in `State.dispose`.
- `FlStateEventBusMixin.observeEvent` **should be called exactly once, in `initState`**. Putting it in `build` / `onPageResume` makes the subscription count grow linearly with rebuilds; in debug there's an assertion against duplicate `(type, callback)` combinations.

**Performance**

- Each `FlPageLifecycleMixin` instance costs, by default, one route subscription and one first-frame callback; turning on `observeAppLifecycle` adds two app broadcast stream subscriptions, which are the bulk of the cost. **Don't use `FlPageView` on list items**; if you genuinely need many instances, leave `observeAppLifecycle` at its default `false`.
- Platform differences: `AppLifecycleState.hidden` and `detached` produce no events from this package; Android's `detached` (Activity destroyed while the Engine lives on) doesn't emit a duplicate `onAppBackground`.

---

## ❓ FAQ

**Q1: None of the callbacks fire, or only `onPageInit` / `onPageDispose` respond?**

Two possible causes: first, `FlRouteObserver` wasn't registered in `navigatorObservers` (the most common one; in debug the console hints at it); second, the page isn't inside any `Navigator` at all (`ModalRoute.of(context)` is `null`), in which case all route events are inert. Nested `Navigator`s need their own registration.

```dart
MaterialApp(navigatorObservers: [FlRouteObserver.instance], home: HomePage());
```

**Q2: No start / stop when paging between children of a `PageView`?**

The children aren't wrapped in `FlPageViewScope`. This package doesn't infer the render tree; the index must be passed down explicitly by whoever builds the `PageView`:

```dart
PageView.builder(
  controller: controller,
  itemBuilder: FlPageViewScope.wrapItemBuilder(
    controller: controller,
    builder: (context, index) => pages[index],
  ),
)
```

Also confirm the children turned `observePageView` on: it defaults to `false` in both the mixin and `FlPageView`, and must be enabled explicitly.

**Q3: The refresh / analytics call in `onPageResume` fires repeatedly?**

`onPageResume` means "became interactive", and closing a dialog, returning from a child page, or sliding back to this page in a `PageView` all trigger it — that's by design. If you only want "first became visible", use `onPageStart` (kept idempotent by `_hasAppeared`); if you only want to exclude the dialog case, record a flag in `onPagePause` and distinguish it yourself.

If it's an **event bus** callback firing repeatedly, check whether `observeEvent` was written inside `build` or `onPageResume` — it may only be called once, in `initState`.

**Q4: `onPageEnterAnimationStart` never arrives?**

That's expected. The animation listener is only bound to `ModalRoute.animation` at `onPageContextReady` (the first `didChangeDependencies`), while Navigator has already driven the animation to `forward` in the earlier `didPush`, so the state change happens before the binding. If you need the "page started entering" moment, use `onPageInit` or `onPageContextReady`; what this callback actually catches is mostly the animation reversal caused by abandoning an iOS swipe-back mid-gesture.

---
