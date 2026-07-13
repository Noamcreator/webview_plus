import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'webview_plus_method_channel.dart';

abstract class WebviewPlusPlatform extends PlatformInterface {
  /// Constructs a WebviewPlusPlatform.
  WebviewPlusPlatform() : super(token: _token);

  static final Object _token = Object();

  static WebviewPlusPlatform _instance = MethodChannelWebviewPlus();

  /// The default instance of [WebviewPlusPlatform] to use.
  ///
  /// Defaults to [MethodChannelWebviewPlus].
  static WebviewPlusPlatform get instance => _instance;

  /// Platform-specific implementations should set this with their own
  /// platform-specific class that extends [WebviewPlusPlatform] when
  /// they register themselves.
  static set instance(WebviewPlusPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
