require 'xcodeproj'
root = File.expand_path('..', __dir__)
[['ios', :ios, '15.0', 'com.gteijeiro.lanlink.share'], ['macos', :osx, '12.0', 'com.example.lanlink.share']].each do |folder, platform, minimum, bundle|
  project = Xcodeproj::Project.open(File.join(root, folder, 'Runner.xcodeproj'))
  runner = project.targets.find { |target| target.name == 'Runner' }
  share = project.targets.find { |target| target.name == 'LanLinkShare' } || project.new_target(:app_extension, 'LanLinkShare', platform, minimum)
  group = project.main_group.groups.find { |item| item.name == 'LanLink Native' } || project.main_group.new_group('LanLink Native', '../apple')
  sources = ['Shared/DirectPeerEngine.swift', 'Shared/QuickNativeSender.swift', 'Shared/NativeBluetoothClient.swift', 'ShareExtension/ShareViewController.swift']
  (sources + ['Shared/DirectFlutterBridge.swift']).each do |path|
    file = group.files.find { |item| item.path == path } || group.new_file(path)
    targets = path.end_with?('DirectFlutterBridge.swift') ? [runner] : (path.end_with?('DirectPeerEngine.swift') ? [runner, share] : [share])
    targets.each { |target| target.source_build_phase.add_file_reference(file) unless target.source_build_phase.files_references.include?(file) }
  end
  share.build_configurations.each do |config|
    config.build_settings.merge!({'PRODUCT_BUNDLE_IDENTIFIER' => bundle, 'PRODUCT_NAME' => 'LanLinkShare', 'SWIFT_VERSION' => '5.0', 'MARKETING_VERSION' => '1.4.1', 'CURRENT_PROJECT_VERSION' => '10', 'INFOPLIST_FILE' => "../apple/ShareExtension/Info-#{folder}.plist", 'GENERATE_INFOPLIST_FILE' => 'NO', 'SKIP_INSTALL' => 'YES', 'APPLICATION_EXTENSION_API_ONLY' => 'YES', 'DEVELOPMENT_TEAM' => '6WV47G2CGZ', 'CODE_SIGN_STYLE' => 'Automatic'})
    config.build_settings['CODE_SIGN_ENTITLEMENTS'] = '../apple/ShareExtension/Share-macos.entitlements' if folder == 'macos'
  end
  runner.add_dependency(share) unless runner.dependencies.any? { |dependency| dependency.target == share }
  embed = runner.copy_files_build_phases.find { |phase| phase.name == 'Embed Share Extension' } || runner.new_copy_files_build_phase('Embed Share Extension')
  embed.dst_subfolder_spec = '13'
  if folder == 'ios'
    # Embed before Flutter's Thin Binary phase, which reads the completed Info.plist.
    runner.build_phases.delete(embed)
    thin = runner.build_phases.index { |phase| phase.display_name == 'Thin Binary' } || runner.build_phases.length
    runner.build_phases.insert(thin, embed)
  end
  unless embed.files_references.include?(share.product_reference)
    file = embed.add_file_reference(share.product_reference)
    file.settings = {'ATTRIBUTES' => ['RemoveHeadersOnCopy']}
  end
  if folder == 'macos'
    file = project.main_group.files.find { |item| item.path == 'Runner/IncomingShareBridge.swift' } || project.main_group.new_file('Runner/IncomingShareBridge.swift')
    runner.source_build_phase.add_file_reference(file) unless runner.source_build_phase.files_references.include?(file)
  end
  project.save
end
