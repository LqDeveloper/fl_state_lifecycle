## 0.1.3

* Fix lifecycle timing docs: `onPagePostFrame` is now explicitly described as firing **before** `onPageStart` / `onPageResume` (all three happen in the first-frame callback), so you can measure sizes in postFrame and use them directly in start.
* Clarify the timing of `onPageEnterAnimationStart`: on the first `push` entry it is **not guaranteed** to be received (the animation listener binds only in `onPageContextReady`, and `didPush` may already have advanced the animation to `forward`); don't rely on it for first-screen logic.
* Note that when the app's first page (`home`) has no transition animation, neither EnterAnimation event is emitted; also that a lower page's `onPageStart` / `onPageResume` fire when the animation **starts**, without waiting for it to finish.
* Rewrite the README in English and improve its structure; polish demo page layout and interactions in the example app.
* Hide the `@internal` `FlPageViewScopeData` at export time, removing the `invalid_export_of_internal_element` analyzer warning.


