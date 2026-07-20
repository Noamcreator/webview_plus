#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint webview_plus.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'webview_plus'
  s.version          = '0.8.6'
  s.summary          = 'A cross-platform Flutter plugin that directly encapsulates native WebViews (Android, iOS/macOS, Windows, Linux andWeb) with no WebView dependencies.'
  s.description      = <<-DESC
  A cross-platform Flutter plugin that directly encapsulates native WebViews (Android, iOS/macOS, Windows, Linux andWeb) with no WebView dependencies.
                       DESC
  s.homepage         = 'https://github.com/Noamcreator/webview_plus'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Noam' => 'noam.bourmault@gmail.com' }
  s.source           = { :path => '.' }
  s.source_files = 'webview_plus/Sources/webview_plus/**/*'
  s.dependency 'Flutter'
  s.platform = :ios, '13.0'
  s.frameworks = 'WebKit'

  # Flutter.framework does not contain a i386 slice.
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.swift_version = '5.0'

  # If your plugin requires a privacy manifest, for example if it uses any
  # required reason APIs, update the PrivacyInfo.xcprivacy file to describe your
  # plugin's privacy impact, and then uncomment this line. For more information,
  # see https://developer.apple.com/documentation/bundleresources/privacy_manifest_files
  # s.resource_bundles = {'webview_plus_privacy' => ['webview_plus/Sources/webview_plus/PrivacyInfo.xcprivacy']}
end
