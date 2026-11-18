Pod::Spec.new do |spec|
  spec.name = 'GoMovieCore'
  spec.version = '0.2.0'
  spec.summary = 'GoMovie原生核心'
  spec.homepage = 'https://github.com/fish2018/guoapp'
  spec.author = 'GuoApp contributors'
  spec.source = { :path => '.' }
  spec.license = { :type => 'See application repository' }
  spec.osx.deployment_target = '12.0'
  spec.source_files = 'Sources/**/*.{h,m}'
  spec.public_header_files = 'Sources/*.h'
  spec.vendored_libraries = 'libGoMovieCore.a'
  spec.static_framework = true
  spec.frameworks = 'Foundation', 'CoreFoundation', 'Security'
  spec.libraries = 'resolv'
  spec.user_target_xcconfig = {
    'OTHER_LDFLAGS' => '$(inherited) -Wl,-u,_GoMovieRequest -Wl,-u,_GoMovieFree -Wl,-export_dynamic',
    'STRIP_STYLE' => 'non-global'
  }
end
