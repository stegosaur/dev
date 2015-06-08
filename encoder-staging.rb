#!/usr/bin/env ruby

$LOAD_PATH.unshift("#{File.dirname(__FILE__)}/")
require 'aws-sdk'
require 'mysql2'
require 'logger'
require 'config-stage.rb'

#logPath=STDOUT
@timeStarted = Hash.new
@ec2 = Aws::EC2::Client.new(region: 'us-east-1')

instances = @ec2.describe_instances(max_results: 1000)[0]
@encoders = [] 
instances.each{ |instance| @encoders << {"#{instance.inspect.match(/enc.-staging/)}" => "#{instance[4][0][0]}"} if instance.inspect.match(/enc.-staging/) and !(instance.inspect.match(/enc0/)) } 

@encoders=@encoders.sort_by { |key| key.keys }
@logger.debug("Loaded encoders: #{@encoders.to_s}")


def monitor(encoder, active)
    sedremove = "s/\\'#{encoder.keys.first}/\\#\\'#{encoder.keys.first}/g"
    sedadd = "s/\\#\\'#{encoder.keys.first}/\\'#{encoder.keys.first}/g"
    if active == false
        @logger.info("running /bin/sed -i #{sedremove} /etc/check_mk/main.mk")
        `/bin/sed -i #{sedremove} /etc/check_mk/main.mk`
        @logger.debug`/usr/bin/cmk -O`
    else
        @logger.info("running /bin/sed -i #{sedadd} /etc/check_mk/main.mk")
        `/bin/sed -i #{sedadd} /etc/check_mk/main.mk`
        @logger.debug(`/usr/bin/cmk -O`)
    end
end
def stop_encoder(encoder) 
    success=false
    if @db.query("select (select count(*) from uploadqueue where upload_server_id='#{encoder.keys.first}') + (select count(*) from queue where transcoder_id='#{encoder.keys.first}') as total").first.values[0] == 0
        if @ec2.describe_instance_status(:instance_ids => encoder.values).data.inspect.match(/running/) 
            if @timeStarted[encoder.keys.first].nil? || (@timeStarted[encoder.keys.first].min-15...@timeStarted[encoder.keys.first].min).cover?(Time.now.min) || (@timeStarted[encoder.keys.first].min-15+60..@timeStarted[encoder.keys.first].min+60).cover?(Time.now.min) 
                @db.query("delete from transcoder where transcoder_id='#{encoder.keys.first}'")
                @db.query("delete from uploader where uploader_id='#{encoder.keys.first}'")
                @logger.info("stopping #{encoder.keys.first}")
                @ec2.stop_instances(:instance_ids => encoder.values)
                success = true
                monitor(encoder, false)
            else
                @logger.info("allowing #{encoder.keys.first} to stay online until time expired")
            end
        end
    else
        in_service=@db.query("select in_service from transcoder where transcoder_id='#{encoder.keys.first}'").first
        if !(@ec2.describe_instance_status(:instance_ids => encoder.values).data.inspect.match(/running/) )
            @logger.error("#{encoder.keys.first} is down but jobs are queued.")
            start_encoder(encoder)
        else
            @logger.info("job stuck on #{encoder.keys.first}, skipping")
            if @timeStarted[encoder.keys.first].nil? || (@timeStarted[encoder.keys.first].min-20...@timeStarted[encoder.keys.first].min).cover?(Time.now.min) || (@timeStarted[encoder.keys.first].min-20+60..@timeStarted[encoder.keys.first].min+60).cover?(Time.now.min)
                @db.query("update transcoder set in_service=0 where transcoder_id='#{encoder.keys.first}'")
                @db.query("update uploader set in_service=0 where uploader_id='#{encoder.keys.first}'")
                @logger.info("taking #{encoder.keys.first} out of service to cool down") if @db.affected_rows > 0 
            else 
                @db.query("update transcoder set in_service=1 where transcoder_id='#{encoder.keys.first}'")
                @db.query("update uploader set in_service=1 where uploader_id='#{encoder.keys.first}'")
                @logger.info("putting #{encoder.keys.first} back in service") if @db.affected_rows > 0
            end unless in_service.nil? 
        end
    end 
    return success
end
def start_encoder(encoder)
    success = false
    if !(@ec2.describe_instance_status(:instance_ids => encoder.values).data.inspect.match(/running/))
        @timeStarted[encoder.keys.first]=Time.now
        @logger.info("starting #{encoder.keys.first}, marking timeStarted at #{@timeStarted[encoder.keys.first]}")
        @ec2.start_instances(:instance_ids => encoder.values) 
        count=0
        until @db.query("select count(*) from transcoder where transcoder_id='#{encoder.keys.first}'").first.values[0] != 0
                count += 1
                sleep 1
                break if count == 90
        end
        success = true unless @db.query("select count(*) from transcoder where transcoder_id='#{encoder.keys.first}'").first.values[0] == 0 
        start_encoder(encoder) if success == false
        monitor(encoder, true) unless success == false
    elsif @db.query("select in_service from transcoder where transcoder_id='#{encoder.keys.first}'").first.values[0] == 0
        @db.query("update transcoder set in_service=1 where transcoder_id='#{encoder.keys.first}'")
        @logger.info("putting #{encoder.keys.first} back in service") 
        success = true
    end
    return success
end

def scaleUp(activateOnly=false)
    response = nil
    @encoders.each { |enc| 
        response = start_encoder(enc) if @db.query("select count(*) from transcoder where transcoder_id='#{enc.keys.first}' and slot_type='large'").first.values[0] == 1
        break if response
    }
    return true if response or activateOnly
    @encoders.each { |enc|
        response = start_encoder(enc)
        break if response
    }
end

def scaleDown()
    online = @db.query("select count(distinct(transcoder_id)) from transcoder").first.values[0]
    @encoders.each { |enc| 
        response = stop_encoder(enc)
        break if response 
    } 
end

def check_queue
    queuesize =  @db.query("select count(*) from queue").first.values[0]
    online = @db.query("select count(*) from transcoder where slot_type='large'").first.values[0]
    queue = @db.query("select count(*) from queue where type='conversion' and subpriority < 25 and transcoder_id is null and added < now()-60").first.values[0]
    users = @db.query("SELECT COUNT(DISTINCT `scheduler_group_id`) FROM `queue` WHERE `try_count` < max_try_count;").first.values[0]
    @db.query("update queue set priority=6 where data not like '%320L%'") #prioritize 320L to keep queue at minimum and speed up ready state until proper fix is in place
    @db.query("update uploadqueue set priority = 6 where type = 'multi'")
    @logger.debug("queue at #{queue}, users at #{users}")
    if queue > 10
        scaleUp()
    elsif queuesize > online*75 or queue >= 5
        activateOnly=true
        scaleUp(activateOnly)
    else
        scaleDown()
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

