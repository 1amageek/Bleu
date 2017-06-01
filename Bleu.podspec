Pod::Spec.new do |s|

  s.name         = "Bleu"
  s.version      = "1.0"
  s.summary      = "BLE(Bluetooth LE) for U💖). Bleu enables communication in server and client format."
  s.description  = <<-DESC
  BLE(Bluetooth LE) for U💖). Bleu enables communication in server and client format.
                   DESC

  s.homepage     = "https://github.com/1amageek/Bleu"
  s.license      = "MIT"
  #s.screenshots     = 'www.example.com/screenshots_1', 'www.example.com/screenshots_2'
  s.license      = { :type => "MIT", :file => "LICENSE" }
  s.author             = { "1_am_a_geek" => "tmy0x3@icloud.com" }
  s.social_media_url   = "http://twitter.com/1amageek"
  s.platform     = :ios, "10.0"
  s.source       = { :git => "https://github.com/1amageek/Bleu.git", :tag => "#{s.version}" }
  s.source_files  = "Sources/**/*.swift"
  s.requires_arc = true

end
