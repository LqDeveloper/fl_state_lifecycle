import 'package:example/src/animation_page.dart';
import 'package:example/src/app_lifecycle_page.dart';
import 'package:example/src/event_bus_page.dart';
import 'package:example/src/home_page.dart';
import 'package:example/src/page_lifecycle_page.dart';
import 'package:example/src/page_view_page.dart';
import 'package:example/src/route_page.dart';
import 'package:example/src/route_stack_page.dart';
import 'package:flutter/material.dart';
import 'package:fl_state_lifecycle/fl_state_lifecycle.dart';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Flutter Demo',
      theme: ThemeData(colorScheme: .fromSeed(seedColor: Colors.deepPurple)),
      home: const HomePage(),
      navigatorObservers: [FlRouteObserver()],
      routes: {
        "/FlAnimationLifecycleMixin": (_) => AnimationPage(),
        "/FlAppLifecycleMixin": (_) => AppLifecyclePage(),
        "/FlPageRouteMixin_one": (_) => RouteOnePage(),
        "/FlPageRouteMixin_two": (_) => RouteTwoPage(),
        "/FlPageLifecycleMixin": (_) => PageLifecyclePage(),
        "/PageViewPage": (_) => PageViewPage(),
        routeStackRouteName: (_) => RouteStackPage(),
        "/FlStateEventBusMixin": (_) => EventBusPage(),
      },
    );
  }
}
