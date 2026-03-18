require 'json'

package = JSON.parse(File.read(File.join(__dir__, 'package.json')))

Pod::Spec.new do |s|
  s.name = 'CapacitorPjsip'
  s.version = package['version']
  s.summary = package['description']
  s.license = package['license']
  s.homepage = package['repository']['url']
  s.author = package['author']
  s.source = { :git => package['repository']['url'], :tag => s.version.to_s }
  s.source_files = 'ios/Sources/**/*.{swift,h,m,c,cc,mm,cpp}'
  s.ios.deployment_target = '15.0'
  s.dependency 'Capacitor'
  s.swift_version = '5.1'

  # PJSIP built from source (via scripts/build-ios.sh)
  s.vendored_frameworks = 'ios/Frameworks/PjsipSDK.xcframework'
  s.frameworks = 'CallKit', 'PushKit', 'AVFoundation', 'AudioToolbox', 'CFNetwork', 'Security'
  s.libraries = 'c++'

  # Suppress warnings from PJSIP headers
  s.pod_target_xcconfig = {
    'OTHER_LDFLAGS' => '-ObjC',
    'HEADER_SEARCH_PATHS' => '$(inherited) "${PODS_ROOT}/../../ios/Frameworks/PjsipSDK.xcframework/Headers"'
  }
end
