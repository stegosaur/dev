#!/usr/bin/env ruby

$LOAD_PATH.unshift("#{File.dirname(__FILE__)}/")
require 'aws-sdk'
require 'mysql2'
require 'logger'
require 'config.prod'

@logger = Logger.new(@config["logpath"])
@logger.level = Logger::DEBUG
@db = Mysql2::Client.new(:host => @config["db_host"], :username => @config["db_user"], :password => @config["db_pass"], :database => 'transcoding')
@aws = Aws::Credentials.new(@config["aws_key"], @config["aws_secret"])
@awsdev = Aws::Credentials.new(@config["aws_r53_key"], @config["aws_r53_secret"])
@subnets = @config["subnets"]
@environment_filters = "-#{@config["environment"]}" unless @config["environment"] == "production"
@environment_filters = "" if @config["environment"] == "production"

@ec2 = Aws::EC2::Client.new(region: 'us-east-1', credentials: @aws)


def getInstances()
     @zone = @config["zones"].dup
     @instances = @ec2.describe_instances(max_results: 1000)[0]
     @oldEncoders = [] if @encoders.nil?
     @oldEncoders = @encoders unless @encoders.nil?
     @encoders = []
     @instances.each{ |instance| 
         if instance[:instances][0][:tags].inspect =~ /"Name", value="enc.*?#{@environment_filters}.jwplatform.com/ and !(instance.inspect.match(@config["base_transcoder_name"])) and instance.inspect.match(/running/)
             @encoders << { "#{instance.inspect.match(/"Name", value="enc.*?#{@environment_filters}.jwplatform.com/).to_s.gsub(/.jwplatform.com|"Name", value="/, "")}" => "#{instance[4][0][0]}"}
             @zone[instance[4][0][11][0]] += 1
         end    
     }          
     @encoders=@encoders.sort_by { |key| key.keys }
     if @encoders-@oldEncoders != []
         @logger.info("new transcoders detected: #{(@encoders - @oldEncoders).to_s}")
         (@encoders-@oldEncoders).each { |newEncoder| newEncoder = newEncoder.keys.first 
                @instances.each { |instance|
                        updateDNS(newEncoder, instance[:instances][0][:private_ip_address]) if instance[:instances][0][:tags].inspect.match(/#{newEncoder}/) } } 
         monitor() if @config["environment"] == "production" 
     elsif @oldEncoders-@encoders != []
     @logger.debug("transcoder removal detected: #{(@oldEncoders - @encoders).to_s}")
         monitor(true) if @config["environment"] == "production"
     end 
end     

def launchInstance(zone, subnet, spot=false)
    begin
    launchSpec = {image_id: @config["ami"], min_count: 1, max_count: 1, key_name: @config["ec2_key_name"], instance_type: @config["ec2_instance_type"],
        placement: { availability_zone: zone },
        block_device_mappings: [ { device_name: "/dev/sda1", ebs: { volume_size: @config["ebs_volume_size"], delete_on_termination: true, volume_type: @config["ebs_volume_type"], }, }, ],
        monitoring: { enabled: true }, disable_api_termination: false, instance_initiated_shutdown_behavior: "terminate",
        network_interfaces: [ { groups: [@config["default_security_group"]], subnet_id: subnet, device_index: 0, associate_public_ip_address: true } ],
        iam_instance_profile: { name: @config["iam_role"] }, ebs_optimized: true}
    if spot == true
        launchSpec.delete(:min_count)
        launchSpec.delete(:max_count)
        launchSpec.delete(:disable_api_termination)
        launchSpec.delete(:instance_initiated_shutdown_behavior)
        launchSpec.delete(:ebs_optimized)
        launchSpec[:instance_type] = "cc2.8xlarge"
        spotSpec = { spot_price: "90.00", instance_count: 1, type: "one-time", launch_specification: launchSpec }
        @logger.info("requesting spot instance")
        response = @ec2.request_spot_instances(spotSpec)
        sleep 25
    else
        response = @ec2.run_instances(launchSpec)
    end
    rescue Exception => e
        @logger.error("instance failed to start (#{e}), check AWS config. dying")
        abort("aws error") 
    end
    return [response[:instances][0][0], response[:instances][0]["private_ip_address"]] unless spot
    return response[0][0][:spot_instance_request_id] if spot
end    

def updateDNS(name, record)
    r53 = Aws::Route53::Client.new(region: "us-east-1", credentials: @awsdev)
    r53.list_hosted_zones rescue abort("aws error") #die if r53 can't do this for whatever reason
    resp = r53.change_resource_record_sets( hosted_zone_id: "Z21GK6IRST1JD7",
        change_batch: { comment: "changed by autoscaler",
        changes: [ { action: "CREATE", resource_record_set: { name: name + ".jwplatform.com" , type: "A", set_identifier: "ResourceRecordSetIdentifier", region: "us-east-1", ttl: 30, resource_records: [ { value: record } ],  }, }, ], } ) rescue update=false
    if update == false
        return true
    else
        @logger.info("updating dns #{name} => #{record}")
        sleep 5
    end
end

def monitor(remove=false)
     conf=["all_hosts += [", "", "]"]
     @encoders.each {|enc| conf.insert(1, "'#{enc.keys[0]}.jwplatform.com',") }
     f = File.new("/etc/check_mk/conf.d/enc.mk", "w+")
     conf.each { |line| f.write(line.gsub(/$/, "\n")) }
     f.chmod(0644)
     f.close
     @encoders.each {|enc| @logger.debug("scanning #{enc.keys[0]}")
                     `/usr/bin/cmk -I #{enc.keys[0]}.jwplatform.com` } unless remove==true
     @logger.debug(`/usr/bin/cmk -O`)
end

def stop_encoder(encoder)
     success=false
     timeStarted=@ec2.describe_instances(:instance_ids => encoder.values)[:reservations][0][:instances][0][10]
     if @db.query("select (select count(*) from uploadqueue where upload_server_id='#{encoder.keys.first}') + (select count(*) from queue where transcoder_id='#{encoder.keys.first}') as total").first.values[0] == 0
         if @ec2.describe_instance_status(:instance_ids => encoder.values).data.inspect.match(/running/)
             if (timeStarted.min-15...timeStarted.min).cover?(Time.now.min) || (timeStarted.min-15+60..timeStarted.min+60).cover?(Time.now.min)
                 @db.query("delete from transcoder where transcoder_id='#{encoder.keys.first}'")
                 @db.query("delete from uploader where uploader_id='#{encoder.keys.first}'")
                 @logger.info("stopping #{encoder.keys.first}")
                 @ec2.terminate_instances(:instance_ids => encoder.values)
                 success = true
             else
                 @logger.info("allowing #{encoder.keys.first} to stay online until time expired")
             end
         end
     else
         if !(@ec2.describe_instance_status(:instance_ids => encoder.values).data.inspect.match(/running/) )
             @logger.error("#{encoder.keys.first} is down but jobs are queued, moving jobs")
             @db.query("update queue set processed = null, transcoder_id=null where transcoder_id='#{transcoder}'")
         end
     end
     in_service=@db.query("select in_service from transcoder where transcoder_id='#{encoder.keys.first}'").first
     if (timeStarted.min-20...timeStarted.min).cover?(Time.now.min) || (timeStarted.min-20+60..timeStarted.min+60).cover?(Time.now.min)
         @db.query("update uploader set in_service=0 where uploader_id='#{encoder.keys.first}'")
         @db.query("update transcoder set in_service=0 where transcoder_id='#{encoder.keys.first}'")
         @logger.info("taking #{encoder.keys.first} out of service to cool down") if @db.affected_rows > 0
     else
         @db.query("update uploader set in_service=1 where uploader_id='#{encoder.keys.first}'")
         @db.query("update transcoder set in_service=1 where transcoder_id='#{encoder.keys.first}'")
         @logger.info("putting #{encoder.keys.first} back in service") if @db.affected_rows > 0
     end unless in_service.nil?
     return success
end

def start_encoder(encoder=nil)
     success = false
     if encoder.nil?
        @logger.info("launching new encoder")
        zone = @zone.key(@zone.values.min)
        instance=launchInstance(zone, @subnets[zone[-1]])
        instance_id=instance[0]
        private_ip=instance[1]
        encoder="enc#{instance_id.gsub("i-", "")}#{@environment_filters}"
        updateDNS(encoder, private_ip)
        count=0
        until @db.query("select count(*) from transcoder where transcoder_id='#{encoder}'").first.values[0] != 0
            count += 1
            sleep 1
            @logger.info("waiting for #{encoder} to start...") if count % 15 == 0
            break if count == 300
        end
        success = true unless @db.query("select count(*) from transcoder where transcoder_id='#{encoder}'").first.values[0] == 0
     else
        @logger.info("reactivating encoder #{encoder}") unless encoder.size == 0
        @db.query("update transcoder set in_service=1 where transcoder_id='#{encoder}'")
        @db.query("update uploader set in_service=1 where uploader_id='#{encoder}'")
        success = true
     end
     return success
end

def scaleUp(activateOnly=false,spot=false)
    response = nil
    begin
       inactive = @db.query("select distinct(transcoder_id) from transcoder where in_service = 0").first.values[0]
    rescue
       inactive = []
    end
    if inactive.size > 0 or activateOnly == true
        response = start_encoder(inactive) 
    elsif inactive.size == 0 and spot == false
        response = start_encoder()
    elsif spot == true
        prices = {} 
        @ec2.describe_spot_price_history({instance_types: ["cc2.8xlarge"], product_descriptions: ["Linux/UNIX (Amazon VPC)"], start_time: Time.now})[0].each { |price| 
                prices.merge!({ price[:availability_zone] => price[:spot_price].to_f }) }
        zone = prices.key(prices.values.min)
        subnet = @subnets[zone[-1]] 
        response = launchInstance(zone, subnet, spot)
        @logger.info("successfully requested spot with id #{response}")
    end
    return true if response or activateOnly
end

def scaleDown()
    online = @db.query("select count(distinct(transcoder_id)) from transcoder").first.values[0]
    @encoders.each { |enc| 
        response = stop_encoder(enc)
        break if response 
    } 
end

def check_queue
     getInstances()
     queuesize =  @db.query("select count(*) from queue").first.values[0]
     online = @db.query("select count(*) from transcoder where slot_type='large'").first.values[0]
     spots = @ec2.describe_spot_instance_requests({filters:[ {name: "state", values: ["active", "open"] }, {name: "launch.image-id", values:["ami-f5857e9e"] } ] } )[0].size
     jobAge = 60 * (online.to_i*0.2 + 1.0) - 12
     queue = @db.query("select count(*) from queue where type='conversion' and subpriority < 25 and transcoder_id is null and added < now()-#{jobAge}").first.values[0]
     users = @db.query("SELECT COUNT(DISTINCT `scheduler_group_id`) FROM `queue` WHERE `try_count` < max_try_count;").first.values[0]
     @db.query("update queue set priority=4 where type='metadata'") #metadata should take priority over all other small jobs
     @db.query("update queue set priority=6 where subpriority > 25 and added < now()-3600 and data not like '%320L%'") #
     @logger.debug("priority queue jobs: #{queue}, total queue size: #{queuesize}, users: #{users}, encoders online: #{online}, spot requests: #{spots}")
     if queue > @config["max_unassigned_priority_jobs"]
         scaleUp()
     elsif queuesize > online*@config["activation_threshold"] or queue >= @config["priority_activation_threshold"]
         scaleUp(activateOnly=true, spot=false)
     else
         scaleDown() unless queue > 0
     end
     if queuesize/@config["spot_request_threshold"] > online # > spots --- use on demand until proper handling for spots is in place
        scaleUp(activateOnly=false, spot=false)
     end
end

while true
    begin
        check_queue()
        sleep 30 
    rescue Exception => e
        exception = e.to_s
        backtrace = e.backtrace.to_s
        @logger.debug(exception)
        @logger.debug(backtrace)
        exit 1 if exception =~ /Mysql2::Error/
        exit 1 if exception =~ /aws error/
        @logger.debug(e)
        sleep 5
    end
end

