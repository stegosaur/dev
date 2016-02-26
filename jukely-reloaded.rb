#!/usr/bin/env ruby

require 'capybara/rspec'
require 'json'
require 'curb'
require 'logger'

#####CONFIG HERE#################
ENV['DISPLAY']=":99"
logPath = "/var/log/jukely.log"
@alertVenue = "Webster Hall"
@alertArtist = "no alert set"
@alertType = "claim"
##################################

@logger = Logger.new(logPath)
@logger.level = Logger::DEBUG
@loggedIn=false
@lastLogin=nil
@driver = Capybara::Session.new(:selenium)
@output = nil
@claimed = false

def login
  @driver.visit("https://jukely.com/log_in")
  @driver.fill_in 'username', :with => 'user_name'
  @driver.fill_in 'password', :with => 'password'
  @driver.click_button 'Log in'
  sleep 2
  @loggedIn=check_login()
  @lastLogin=Time.now
  return @lastLogin if @loggedIn
end

def refresh_token
  @driver.visit(@driver.current_url)
  access_token = JSON.parse(@driver.html.match(/{\"access_token.*?}/).to_s)
  @logger.info("got new access_token data: #{access_token}") 
  return access_token
end

def check_login
  if @driver.html.match(/access_token.*?/)
     @logger.info("we are logged in to jukely")
     return true
  else
     @logger.info("we are NOT logged in to jukely")
     return false
  end
end

def parse()
  @logger.info("hitting jukely api for data")
  c = Curl::Easy.new("https://api.jukely.com/v5/metros/new-york/events?tier=unlimited&access_token=#{@access_token["access_token"]}") do |curl|
    curl.headers["User-Agent"] = "Mozilla/5.0 (X11; Fedora; Linux x86_64; rv:42.0) Gecko/20100101 Firefox/42.0"
  end
  c.perform
  events = JSON.parse(c.body_str)
  output = ""
  events["events"].each { |x| output << "#{x["headliner"]["name"]} at #{x["venue"]["name"]}"
    output << " on #{DateTime.parse(x["starts_at"]).to_time.strftime('%A, %B %d, %r')}"
    genre = ""
    x["headliner"]["genres"].each {|x| genre << x["name"] + ", " } 
    output << " playing #{genre.gsub(/.$/, '')}"
    output << " with passes available" if x["status"]!=3  
    output << " with passes sold out" if x["status"]==3
    output << "\n"
    alert(x) if @claimed != true
    @logger.info("claim attempt already tried, skipping") if @claimed == true && x["headliner"]["name"] == @alertArtist
  }
  return output
end

def alert(event)
  claimLink = "https://www.jukely.com/s/" + event["parse_id"] + "/unlimited_rsvp"
  if event["headliner"]["name"] == @alertArtist && (DateTime.parse(event["starts_at"]).to_time - 3600*48).strftime('%e').to_i < (DateTime.now.to_time - 3600*11).strftime('%e').to_i 
    @logger.info("alert show detected!!!!")
    if @alertType == 'wall'
       `wall #{@alertArtist} is available on jukely. visit #{claimLink} to claim`
    elsif @alertType == 'claim'
      @driver.visit(claimLink)
      @claimed = true
    end
  end
end


while true
  if @output.nil?
     last_output = nil
     @logger.info("no jukely data available yet")
  else
     last_output = @output
  end
  if !@access_token.nil? 
    if Time.now < Time.at(@access_token["expires_at"].to_i)
      @output = parse()
    else
      if @loggedIn == true
        @access_token = refresh_token
        @output = parse()
      else
        if Time.now - 3600*6 < @lastLogin 
          login()
          access_token = refresh_token
          @output = parse()
        else
          @logger.info("not ready to login yet. sleeping.")
        end
      end
    end
  else
    @loggedIn=check_login()
    login() if @loggedIn != true
    @access_token=refresh_token()
    @output = parse()
  end
  @logger.info(@output) if last_output != @output
  sleepInterval = (rand*10+1).to_i*500
  @logger.info("going to sleep for #{sleepInterval/60} minutes ")
  sleep sleepInterval
end
