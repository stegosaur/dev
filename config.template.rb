@config = {
        "logpath" => "/var/log/encoder_autoscale.log",  #where to log
        "db_host" => "botr.master.database", #master jwplatform transcoding database hostname
        "db_user" => "dbuser", #db username with sufficient permissions
        "db_pass" => "dbpassword", #db password
        "aws_key" => "AKIAXXXXXXXXXXXXXXXX", #aws key with launch and terminate permissions
        "aws_secret" -> "SSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSS", #aws secret for above
        "aws_r53_key" => "AKIAXXXXXXXXXXXXXXXX", #aws key for modifying dns
        "aws_r53_secret" => "SSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSSS", #aws secret for above   
        "subnets" => { "a" => "subnet-XXXXXXXX", "b" => "subnet-XXXXXXXX", "c" => "subnet-XXXXXXXX", "e" => "subnet-XXXXXXXX" }, #subnet ids to launch in to 
        "zones" => { "us-east-1a" => 1, "us-east-1b" => 0, "us-east-1c" => 0, "us-east-1e" => 0 }, #quantity of servers already in availibiltiy zone 
        "default_security_group" => "sg-XXXXXXXX", #security group id for default vpc
        "ami" => "ami-XXXXXXXX", #ami id that launches transcoders
        "base_transcoder_name" => "XXX.jwplatform.com", #base transcoder hostname that the autoscaler should ignore
        "environment" => "production", #environment we are running in
        "max_unassigned_priority_jobs" => 15, #max unassigned priority jobs before scaling up
        "max_unassigned_jobs" => 500, #max total jobs per transcoder before scaling up
        "priority_activation_threshold" => 5, #max unassigned priority jobs before reactivating out-of-service encoders
        "activation_threshold" => 200, #max total jobs per transcoder before reactivation out-of-service encoders
        "ec2_instance_type" => "c4.4xlarge", #ec2 instance size
        "ec2_key_name" => "XXXXX", #ec2 SSH key name
        "ebs_volume_size" => "100", #allocated disk space in GB
        "ebs_volume_type" => "gp2", #type of ebs volume
        "iam_role" => "Encoder" #iam role to be assigned to encoder
}
