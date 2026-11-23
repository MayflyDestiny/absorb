import 'package:flutter/foundation.dart';

/// Whether stats and settings draw their icons in the app's accent color
/// instead of the neutral gray. Loaded from PlayerSettings at startup and
/// flipped by the Appearance switch.
final ValueNotifier<bool> coloredIconsNotifier = ValueNotifier<bool>(true);