#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html.
# Run `pod lib lint webview_plus.podspec` to validate before publishing.
#
Pod::Spec.new do |s|
  s.name             = 'webview_plus'
  s.version          = '7.0.0'
  s.summary          = 'A cross-platform Flutter plugin that directly encapsulates native WebViews (Android, iOS/macOS, Windows, Linux andWeb) with no WebView dependencies.'
  s.description      = <<-DESC
  A cross-platform Flutter plugin that directly encapsulates native WebViews (Android, iOS/macOS, Windows, Linux andWeb) with no WebView dependencies.
                       DESC
  s.homepage         = 'https://github.com/Noamcreator/webview_plus'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Noam' => 'noam.bourmault@gmail.com' }

  s.source           = { :path => '.' }
  s.source_files = 'webview_plus/Sources/webview_plus/**/*'

  s.dependency 'FlutterMacOS'
  s.frameworks = 'WebKit'

  # `isInspectable` (macOS 13.3+) et le hack `drawsBackground` sur WKWebview
  # nécessitent une cible >= 10.15 pour compiler sereinement avec Swift 5.
  s.platform = :osx, '10.15'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  s.swift_version = '5.0'
end
