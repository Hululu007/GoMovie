Pod::Spec.new do |spec|
  spec.name = 'GoMovieCore'
  spec.version = '0.2.0'
  spec.summary = 'GoMovie原生核心'
  spec.homepage = 'https://github.com/feyakit/GoMovie'
  spec.author = 'GoMovie contributors'
  spec.source = { :path => '.' }
  spec.license = { :type => 'See application repository' }
  spec.ios.deployment_target = '15.1'
  spec.source_files = 'Sources/**/*.{h,m}'
  spec.public_header_files = 'Sources/*.h'
  spec.vendored_frameworks = 'GoMovieCore.xcframework'
  spec.static_framework = true
  spec.frameworks = 'Foundation', 'CoreFoundation', 'Security'
  spec.libraries = 'resolv'
  spec.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }
  spec.user_target_xcconfig = {
    'OTHER_LDFLAGS' => '$(inherited) -Wl,-u,_GoMovieRequest -Wl,-u,_GoMovieFree -Wl,-export_dynamic',
    'STRIP_STYLE' => 'non-global'
  }
end
