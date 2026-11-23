Pod::Spec.new do |s|
  s.name             = 'fb_ios_embedded'
  s.version          = '0.3.0'
  s.summary          = 'Firebird 5 embedded engine for iOS (Flutter plugin).'
  s.description      = <<-DESC
Firebird 5 embedded database engine packaged as native iOS frameworks of a
Flutter plugin. Companion to fb_5_embedded (Android).
                       DESC
  s.homepage         = 'https://github.com/vkruglik/fb_ios_embedded'
  s.license          = { :type => 'MIT', :file => '../LICENSE' }
  s.author           = 'Vadim Kruglik'
  s.source           = { :path => '.' }

  s.ios.deployment_target = '15.0'
  s.swift_version    = '5.0'

  s.source_files     = 'Classes/**/*'

  s.vendored_frameworks = Dir.glob('Frameworks/*.xcframework')

  s.dependency 'Flutter'

  s.pod_target_xcconfig = {
    'DEFINES_MODULE' => 'YES',
    'LD_RUNPATH_SEARCH_PATHS' => '$(inherited) @executable_path/Frameworks @loader_path/Frameworks',
  }
  s.user_target_xcconfig = {
    'LD_RUNPATH_SEARCH_PATHS' => '$(inherited) @executable_path/Frameworks',
  }
end
