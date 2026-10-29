//
//  Generated file. Do not edit.
//

// clang-format off

#import "GeneratedPluginRegistrant.h"

#if __has_include(<integration_test/IntegrationTestPlugin.h>)
#import <integration_test/IntegrationTestPlugin.h>
#else
@import integration_test;
#endif

#if __has_include(<webview_plus/WebviewPlusPlugin.h>)
#import <webview_plus/WebviewPlusPlugin.h>
#else
@import webview_plus;
#endif

@implementation GeneratedPluginRegistrant

+ (void)registerWithRegistry:(NSObject<FlutterPluginRegistry>*)registry {
  [IntegrationTestPlugin registerWithRegistrar:[registry registrarForPlugin:@"IntegrationTestPlugin"]];
  [WebviewPlusPlugin registerWithRegistrar:[registry registrarForPlugin:@"WebviewPlusPlugin"]];
}

@end
