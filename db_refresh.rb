#!/usr/bin/env ruby
#this is a script that takes an rds snapshot from one DB cluster and replaces a DB cluster on another account using it.

require 'aws-sdk'
require 'resolv'

#config

config = {
  "db_cluster_identifier" => ENV["SOURCE_CLUSTER"],
  "account_to_share_with" => ENV["ACCOUNT_TO_SHARE"],
  "target_env" => ENV["TARGET_CLUSTER"]
} 

#hardcode the parameter group to avoid the wrong group being migrated
instance_parameter_group="auroracustomparameters"

#first create the snapshot
db_cluster_snapshot_identifier="#{config["db_cluster_identifier"]}-snapshot-#{Time.new.to_i}"
rds = Aws::RDS::Client.new(:region=>'us-east-1', :credentials => Aws::SharedCredentials.new(:profile_name => "demdex"))
response = rds.create_db_cluster_snapshot({
  db_cluster_identifier: config["db_cluster_identifier"],
  db_cluster_snapshot_identifier: db_cluster_snapshot_identifier
})
#now share it to another account
begin
    while rds.describe_db_cluster_snapshots({db_cluster_snapshot_identifier: db_cluster_snapshot_identifier}).db_cluster_snapshots[0].status != "available"
          puts "#{Time.now} :: waiting for #{db_cluster_snapshot_identifier} to become ready"
              sleep 5
    end
rescue Exception => e
    puts "#{Time.now} :: " + e.message
end

rds.modify_db_cluster_snapshot_attribute({ 
  db_cluster_snapshot_identifier: response.db_cluster_snapshot.db_cluster_snapshot_identifier, 
  attribute_name: "restore", 
  values_to_add: [config["account_to_share_with"]] 
})

rds = Aws::RDS::Client.new(:region=>'us-east-1', :credentials => Aws::SharedCredentials.new(:profile_name => "aam-npe"))

rds.describe_db_cluster_snapshots({
  snapshot_type: "shared",
  include_shared: true }).db_cluster_snapshots.each { |snap| $shared_id=snap["db_cluster_snapshot_arn"] if snap.inspect =~/#{response.db_cluster_snapshot.db_cluster_snapshot_identifier}/}
#now destroy the old cluster
#
tags={}
arn=nil
rds.describe_db_clusters[:db_clusters].each { |cluster| 
  #first delete the cluster members
  cluster[:db_cluster_members].each { |member| 
    if member[:db_instance_identifier] =~ /va6-#{config["target_env"]}.*aurora-portal/ 
      arn = cluster.db_cluster_arn
      rds.list_tags_for_resource({resource_name: arn})[:tag_list].each{|tag| tags.merge!(tag[:key] => tag[:value]) }  # get the tags before deleting
        puts "#{Time.now} :: deleting db cluster member #{member[:db_instance_identifier]}"
      resp = rds.delete_db_instance({ 
        db_instance_identifier: member[:db_instance_identifier],
      })
      $member_config = resp
    end
  }
  sleep 5
  #now wait for them to delete
  begin 
    while rds.describe_db_instances({ db_instance_identifier: $member_config.db_instance.db_instance_identifier }).db_instances[0].db_instance_status == "deleting" do
     puts "#{Time.now} :: waiting for #{$member_config.db_instance.db_instance_identifier} to delete"
     sleep 10
    end
    rescue Exception => e
     puts "#{Time.now} :: " + e.message
  end
  #and delete the cluster once they are gone
  if cluster[:db_cluster_identifier] =~ /#{config["target_env"]}.*aurora-portal/
    $restore_config = cluster
    rds.delete_db_cluster({
      db_cluster_identifier: cluster[:db_cluster_identifier],
      skip_final_snapshot: false,
      final_db_snapshot_identifier: "#{config['target_env']}-cluster-final-snapshot-#{Time.now.to_i}"
    })
  end 
} 
sleep 5

begin
  while rds.describe_db_clusters({db_cluster_identifier: $restore_config[:db_cluster_identifier] }).db_clusters.size > 0
    puts "#{Time.now} :: waiting for #{$restore_config[:db_cluster_identifier]} to delete"
    sleep 10
  end
rescue Exception => e
  puts "#{Time.now} :: " + e.message
end

#now restore from the snapshot
puts "#{Time.now} :: restoring db cluster from snapshot #{$shared_id} in subnet #{$restore_config[:db_subnet_group]}"
rds.restore_db_cluster_from_snapshot ({
    db_cluster_identifier: $restore_config[:db_cluster_identifier],
    engine: $member_config.db_instance.engine,
    snapshot_identifier: $shared_id,
    db_subnet_group_name: $restore_config[:db_subnet_group]
})

while rds.describe_db_clusters({ db_cluster_identifier: $restore_config[:db_cluster_identifier] })[:db_clusters][0][:status] == "creating" do
  puts "#{Time.now} :: waiting for #{$restore_config[:db_cluster_identifier]} to become ready"
  sleep 60
end

#create the cluster members
puts "#{Time.now} :: creating new db instance in parameter group #{instance_parameter_group}"
rds.create_db_instance ({
    db_instance_identifier: $member_config.db_instance.db_instance_identifier,
    db_parameter_group_name: instance_parameter_group,
    db_instance_class: $member_config.db_instance.db_instance_class,
    engine: $member_config.db_instance.engine,
    db_cluster_identifier: $member_config.db_instance.db_cluster_identifier,
    db_subnet_group_name: $member_config.db_instance.db_subnet_group.db_subnet_group_name,
})

while rds.describe_db_instances({ db_instance_identifier: $member_config.db_instance.db_instance_identifier }).db_instances[0].db_instance_status == "creating" do
    puts "#{Time.now} :: waiting for #{$member_config.db_instance.db_instance_identifier} to become ready"
    sleep 10
end


#do final modifications
puts "#{Time.now} :: modifying db cluster: db_cluster_parameter_group_name => #{$restore_config[:db_cluster_parameter_group]}"
puts "#{Time.now} :: modifying db cluster: vpc_security_group_ids: [ #{$member_config.db_instance.vpc_security_groups[0].vpc_security_group_id} ]"
rds.modify_db_cluster({
    apply_immediately: true,
    db_cluster_identifier:  $restore_config[:db_cluster_identifier],
    db_cluster_parameter_group_name: $restore_config[:db_cluster_parameter_group],
    vpc_security_group_ids: [ $member_config.db_instance.vpc_security_groups[0].vpc_security_group_id ],
    master_user_password: "sandwich"
})

sleep 15
#reboot to ensure they take effect
until rds.describe_db_instances({ db_instance_identifier: $member_config.db_instance.db_instance_identifier }).db_instances[0].db_instance_status == "available"
    puts "#{Time.now} :: waiting for status to become available for reboot. current status: #{rds.describe_db_instances({ db_instance_identifier: $member_config.db_instance.db_instance_identifier }).db_instances[0].db_instance_status}"
    sleep 5
end
rds.reboot_db_instance({
  db_instance_identifier: $member_config.db_instance.db_instance_identifier
})

#don't continue unless the db resolves
targetEndpoint=rds.describe_db_instances({ db_instance_identifier: $member_config.db_instance.db_instance_identifier }).db_instances[0].endpoint.address
dbIP = nil
while dbIP.class != String
  dbIP = Resolv.getaddress(targetEndpoint) rescue Resolv::ResolvError 
  puts "#{Time.now} :: waiting for db hostname to resolve"
  puts "#{targetEndpoint} resolved to #{dbIP}" if dbIP.class != String
  sleep 30
end


puts "#{Time.now} :: rebooting db instance #{$member_config.db_instance.db_instance_identifier} again"
until rds.describe_db_instances({ db_instance_identifier: $member_config.db_instance.db_instance_identifier }).db_instances[0].db_instance_status == "available"
    puts "#{Time.now} :: waiting for status to become available for reboot. current status: #{rds.describe_db_instances({ db_instance_identifier: $member_config.db_instance.db_instance_identifier }).db_instances[0].db_instance_status}"
    sleep 5
end
rds.reboot_db_instance({
    db_instance_identifier: $member_config.db_instance.db_instance_identifier
}) 

#add the tags back to the cluster
tags=tags.map{|k,v| { key: k, value: v} }
rds.add_tags_to_resource({ resource_name: arn, tags: tags })
rds.add_tags_to_resource({ resource_name: arn.gsub(':cluster:', ':db:').gsub('cluster', '0'), tags: tags })
