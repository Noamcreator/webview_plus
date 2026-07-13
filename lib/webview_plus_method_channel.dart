import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'webview_plus_platform_interface.dart';

/// An implementation of [WebviewPlusPlatform] that uses method channels.
class MethodChannelWebviewPlus extends WebviewPlusPlatform {
  /// The method channel used to interact with the native platform.
  @visibleForTesting
  final methodChannel = const MethodChannel('webview_plus');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>(
      'getPlatformVersion',
    );
    return version;
  }
}
