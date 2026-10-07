# Campfire for BEAM: the BEAM core, in-process, on iOS (the project notes).
#
# An iOS app may not start child processes, so BEAM's wallet-api is linked into
# the app as a library (scripts/beam/core/ios). This pod wraps the pinned
# BeamWalletApi.xcframework into BeamCore.framework, which exports only the C
# interface; Dart finds it with DynamicLibrary.open('BeamCore.framework/BeamCore')
# (lib/wallets/beam/host/beam_core_library.dart).
#
# BeamWalletApi.xcframework is not in git (about 70 MB). Put it here with
#   scripts/beam/core/ios/stage_ios.sh
# which checks each slice against scripts/beam/core/ios/SHA256SUMS. The Podfile
# adds this pod only when the XCFramework is present.
Pod::Spec.new do |s|
  s.name                = 'BeamCore'
  s.version             = '7.5.14493'
  s.summary             = 'BEAM wallet-api 7.5.14493 as an in-process library (Campfire for BEAM).'
  s.homepage            = 'https://github.com/vsnation/campfire-beam'
  s.license             = { :type => 'Apache-2.0 (BEAM core), GPL-3.0 (Campfire glue)' }
  s.author              = 'vsnation'
  s.source              = { :path => '.' }
  s.platform            = :ios, '15.0'
  s.source_files        = 'Sources/*.c'
  s.vendored_frameworks = 'BeamWalletApi.xcframework'
  s.libraries           = 'c++'
  s.pod_target_xcconfig = {
    # Only the C interface leaves the framework: BEAM's sqlite, OpenSSL and
    # Boost stay private, so nothing else in the app can bind to them.
    'OTHER_LDFLAGS' => '$(inherited) -Wl,-exported_symbols_list,"$(PODS_TARGET_SRCROOT)/Sources/exported_symbols.txt"',
    'DEAD_CODE_STRIPPING' => 'YES',
    # The core is built for arm64 only (devices and Apple-silicon simulators).
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'x86_64',
  }
  s.user_target_xcconfig = {
    'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'x86_64',
  }
end
