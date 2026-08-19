# fl_state_lifecycle example

A minimal runnable demo for the [`fl_state_lifecycle`](https://pub.dev/packages/fl_state_lifecycle) package.

It demonstrates `FlStateLifecycleMixin` only:

- Page lifecycle callbacks (`onPageInit`, `onPageContextReady`, `onPageStart`,
  `onPageResume`, `onPagePause`, `onPageStop`, ...) fired when you push/pop the
  second page,
- App lifecycle callbacks (`onAppForeground` / `onAppBackground`),
- All events are printed to the console via `print()`.

## Running

```bash
cd example
flutter create .        # generate the platform folders for your target
flutter run
```

> The `example/` directory is intentionally kept minimal (no platform folders
> checked in); run `flutter create .` once to scaffold them for your device.
