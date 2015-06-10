#!/usr/bin/env ruby

$LOAD_PATH.unshift("#{File.dirname(__FILE__)}/")
require 'aws-sdk'
require 'mysql2'
require 'logger'
require 'config-prod.rb'

@ec2 = Aws::EC2::Client.new(region: 'us-east-1')


def getInstances()
    @zone = @zones
    @instances = @ec2.describe_instances(max_results: 1000)[0]
    @oldEncoders = [] if @encoders.nil?
    @oldEncoders = @encoders unless @encoders.nil?
    @encoders = []
    @instances.each{ |instance| 
        if instance[:instances][0][:tags].inspect =~ /"Name", value="enc.*jwplatform.com/ and !(instance.inspect.match("enc0.jwplatform.com")) and instance.inspect.match(/running/)
            @encoders << { "#{instance.inspect.match(/value="enc.*?jwplatform.com/).to_s.gsub(/.jwplatform.com|value="/, "")}" => "#{instance[4][0][0]}"} 
            @zone[instance[4][0][11][0]] += 1
        end
    }
    @encoders=@encoders.sort_by { |key| key.keys }
    if @encoders-@oldEncoders != [] 
        @logger.debug("new transcoders detected: #{(@encoders - @oldEncoders).to_s}")
        monitor()
    elsif @oldEncoders-@encoders != []
    @logger.debug("transcoder removal detected: #{(@oldEncoders - @encoders).to_s}") 
        monitor(true)
    end
end

def launchInstance(zone, subnet)
    response = @ec2.run_instances(
      image_id: @ami, min_count: 1, max_count: 1, key_name: "Ops-Prod", instance_type: "c4.4xlarge",
      placement: {
        availability_zone: zone,
        tenancy: "default",
      },
      block_device_mappings: [
        {
          device_name: "/dev/sda1",
          ebs: {
            volume_size: 250,
            delete_on_termination: true,
            volume_type: "gp2",
          },
        },
      ],
      monitoring: { enabled: true },
      disable_api_termination: false,
      instance_initiated_shutdown_behavior: "terminate",
      network_interfaces: [ { groups: [@default_security_group], subnet_id: subnet, device_index: 0, associate_public_ip_address: true } ],
      iam_instance_profile: { name: "Encoder" },
      ebs_optimized: true,
    )
    return [response[:instances][0][0], response[:instances][0]["private_ip_address"]]
end

def monitor(remove=false)
    conf=["all_hosts += [", "", "]"]
    @encoders.each {|enc| conf.insert(1, "'#{enc.keys[0]}.jwplatform.com',") }
    f = File.new("/etc/check_mk/conf.d/enc.mk", "w+")
    conf.each { |line| f.write(line.gsub(/$/, "\n")) }
    f.chmod(0644)
    f.close
    @encoders.each {|enc| @logger.debug("scanning #{enc.keys[0]}")
                    `/usr/bin/cmk -II #{enc.keys[0]}.jwplatform.com` } unless remove==true
    @logger.debug(`/usr/bin/cmk -O`)
end

def sweeper()
    registeredTranscoders = []
    @db.query("select distinct(transcoder_id) from transcoder").each {|result| registeredTranscoders <<  result.values[0] unless result.values[0] == "enc0"}
    registeredTranscoders.each {|transcoder|
        running = @ec2.describe_instance_status(:instance_ids => [transcoder.gsub("enc", "i-")]).data.inspect.match(/running/).to_s rescue Aws::EC2::Errors::InvalidInstanceIDNotFound
        if running != "running"
            @db.query("delete from transcoder where transcoder_id='#{transcoder}'")
            @logger.error("deleted offline transcoder #{transcoder} from pool")
            @db.query("update queue set processed = null, transcoder_id=null where transcoder_id='#{transcoder}'")
            @db.query("update uploadqueue set upload_server_id='enc0', processing = NULL where upload_server_id='#{transcoder}'")
            @logger.error("moved jobs from offline transcoder #{transcoder}")
        end }
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
            @logger.error("#{encoder.keys.first} is down but jobs are queued")
        else
            @logger.info("job stuck on #{encoder.keys.first}, skipping")
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
        zone = @zone.select {|key, value| value == @zone.values.min }.first[0]
        instance=launchInstance(zone, @subnets[zone[-1]])
        instance_id=instance[0]
        private_ip=instance[1]
        @logger.debug("#{instance_id} -> #{private_ip}")
        encoder="enc#{instance_id.gsub("i-", "")}"
        create_set=[ { :action => :create, :name => "#{encoder}.jwplatform.com", :type => "A", :ttl => 30, :resource_records => private_ip } ]
        r53 = Aws::Route53::Client.new(region: "us-east-1", credentials: @awsdev)
        resp = r53.change_resource_record_sets( hosted_zone_id: "Z21GK6IRST1JD7",
               change_batch: { comment: "changed by autoscaler",
               changes: [ { action: "CREATE", resource_record_set: { name: "#{encoder}.jwplatform.com", type: "A", set_identifier: "ResourceRecordSetIdentifier", region: "us-east-1", ttl: 30, resource_records: [ { value: private_ip } ], }, }, ], } )
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
        success = true
    end    
    return success
end

def scaleUp(activateOnly=false)
    response = nil
    begin
       inactive = @db.query("select distinct(transcoder_id) from transcoder where in_service = 0").first.values[0]
    rescue
       inactive = []
    end
    if inactive.size > 0 or activateOnly == true
        response = start_encoder(inactive) 
    elsif inactive.size == 0
        response = start_encoder()
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
    queue = @db.query("select count(*) from queue where type='conversion' and subpriority < 25 and transcoder_id is null and added < now()-60").first.values[0]
    users = @db.query("SELECT COUNT(DISTINCT `scheduler_group_id`) FROM `queue` WHERE `try_count` < max_try_count;").first.values[0]
    #@db.query("update queue set priority=6 where data not like '%320L%' and subpriority > 25") #prioritize 320L to keep queue at minimum and speed up ready state until proper fix is in place
    #sweeper()
    @logger.debug("queue at #{queue}, users at #{users}")
    if queue > 15 or queuesize > online * 500
        scaleUp()
    elsif queuesize > online*200 or queue >= 5
        activateOnly=true
        scaleUp(activateOnly)
    else
        scaleDown() unless queue > 0
    end
end

while true
    begin
        check_queue()
        sleep 30 
    rescue Exception => e
        @logger.debug(e)
        exit if e =~ /Mysql2::Error/
        sleep 5
    end
end

