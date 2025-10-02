Pod::Spec.new do |s|
  s.name         = "LinkMeKit"
  s.version      = "0.1.0"
  s.summary      = "LinkMe iOS SDK (Swift)"
  s.license      = { :type => "Apache-2.0" }
  s.author       = { "LinkMe" => "support@li-nk.me" }
  s.homepage     = "https://li-nk.me"
  s.source       = { :path => "." }

  s.platform     = :ios, '13.0'
  s.swift_version = "5.9"

  s.source_files = [
    "Sources/LinkMeKit/**/*.swift"
  ]
end
