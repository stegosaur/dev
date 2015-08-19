#!/usr/bin/ruby
require 'selenium/webdriver'
require 'selenium/client'
require 'selenium/server'
require 'capybara/rspec'
require 'json'
require 'mail'
require 'curl'

ENV['DISPLAY']=":99"
ENV['PATH']="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games"

def parse()
        count=0
        @driver.visit("https://www.jukely.com/unlimited/shows")
        rawData=@driver.source.match(/{\".*?:null}\]}/).to_s rescue nil
        events=JSON.parse(rawData) rescue nil
#        count +=1
#        parse() if events.nil?
#       puts "trying again" if events.nil? 
#       exit 2 if count == 5
        return events
end

Capybara.register_driver :selenium do |app|
        Capybara::Selenium::Driver.new(app, :browser => :chrome)
end

@driver = Capybara::Session.new(:selenium)
@driver.visit("https://jukely.com/log_in")
@driver.fill_in('#username', :with => "YOUR_LOGIN")
@driver.fill_in('#password', :with => "YOUR_PASSWORD")
@driver.click_button 'Log in'
sleep 5
previous_data=File.read("/tmp/previous_run.txt")
relevant_data=[]
events = parse() rescue nil
events["events"].each { |x| relevant_data << x["headliner"]["name"] }
File.write("/tmp/previous_run.txt", relevant_data.sort.to_s)
output = ""
events["events"].each { |x| listeners = JSON.parse(Curl.get("http://ws.audioscrobbler.com/2.0/?method=artist.getinfo&artist=#{x["headliner"]["name"].gsub(' ', '+')}&api_key=LAST_FM_API_KEY&format=json").body_str)["artist"]["stats"]["listeners"] rescue Curl::Err::GotNothingError
                            output << "#{x["headliner"]["name"]} at #{x["venue"]["name"]}" + " on #{DateTime.parse(x["starts_at"]).strftime('%A, %B %d, %T')}" + " playing #{x["headliner"]["genres"].join(", ")}" + " with #{listeners} listeners"
                            output << " and passes available\n" if x["status"]==2  
                            output << " and passes sold out\n" if x["status"]==3 
                            if (x["headliner"]["name"] =~ /SOME CONDITION/i or x["venue"]["name"] =~ /SOME CONDITION/i) and x["status"]==2 
                                alert = Mail.new do
                                        from 'SOME_EMAIL_ADDRESS' 
                                        to 'SOME_EMAIL_ADDRESS'
                                        subject 'check jukely'
                                        body 'passes available'
                                end
                                alert.delivery_method.settings[:openssl_verify_mode] = 'none'
                                alert.deliver!
                            end  } 
if previous_data != relevant_data.sort.to_s
        mail = Mail.new do
                from    'SOME_EMAIL_ADDRESS'
                to      'SOME_EMAIL_ADDRESS'
                subject 'jukely list updated'
                body    output
        end
        mail.delivery_method.settings[:openssl_verify_mode] = 'none'
        mail.deliver!
end
`killall chrome`
`rm -rf /tmp/.com.google*`
