Pod::Spec.new do |s|

  s.name         = "Bleu"
  s.version      = "0.0.1"
  s.summary      = "A short description of Bleu."
  s.description  = <<-DESC
  BLE for U
                   DESC

  s.homepage     = "https://github.com/1amageek/Bleu"
  s.license      = "MIT"
  #s.screenshots     = 'www.example.com/screenshots_1', 'www.example.com/screenshots_2'
  #s.license      = { :type => "MIT", :file => "FILE_LICENSE" }
  s.author             = { "1_am_a_geek" => "tmy0x3@icloud.com" }
  s.social_media_url   = "http://twitter.com/1amageek"
  s.platform     = :ios, "10.0"
  s.source       = { :git => "https://github.com/1amageek/Bleu", :tag => "#{s.version}" }
  s.source_files  = "Classes", "Classes/**/*.swift"
  s.exclude_files = "Classes/Exclude"
  s.requires_arc = true

end
