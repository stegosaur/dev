#!/usr/bin/env bash
 
export AWS_ACCESS_KEY_ID=MASKED
export AWS_SECRET_ACCESS_KEY=MASKED
TARGET_DIRECTORY='/mnt/backups/'
S3_PATH='s3://aam-backups/mysql/backups'
SNAPSHOT_MOUNT='/mnt/snapshot/'
SNAPSHOT_VOLUME='vol-4e0484ea'
WEEK=week`date +%V-%Y`
MYSQL_USER=dbadmin
MYSQL_PASS='MASKED'
INNOBACKUP_COMMAND="innobackupex --user=$MYSQL_USER --pass=$MYSQL_PASS"
LOG="echo \`date '+[%m/%d/%Y %H:%M:%S]'\`"
LOG_FILE=$TARGET_DIRECTORY/simple_mysql_backup.log
COUNT=0
CURRENT_BACKUP_DIR=$(find $TARGET_DIRECTORY |grep week |head -1)
FULL_BACKUP_DIR=$(grep -l "incremental = N" $TARGET_DIRECTORY*/*/xtrabackup_info |awk -F'xtrabackup_info' {'print $1'})
 
exec 2>> $TARGET_DIRECTORY/backup.log >> $TARGET_DIRECTORY/backup_error.log
 
s3_sync()
{
    if [ -d $CURRENT_BACKUP_DIR ]; then
    eval $LOG "Syncing last week to s3" >> $LOG_FILE
    aws s3 sync $CURRENT_BACKUP_DIR $S3_PATH/`basename $CURRENT_BACKUP_DIR`
        S3_STATUS=$?
        eval $LOG "s3sync exited with status $S3_STATUS" >> $LOG_FILE
    else
        S3_STATUS=0
    fi
    if [ $S3_STATUS -eq 0 ]; then
        create_snapshot
        eval $LOG "Deleting last week\'s backup" >> $LOG_FILE
        rm -rf $TARGET_DIRECTORY/week*
    else
        eval $LOG "s3sync failed, trying again after $COUNT tries" >> $LOG_FILE
        if [ $COUNT -gt 2 ]; then
            eval $LOG "s3sync tries exhausted, giving up" >> $LOG_FILE
        fi
        COUNT=$((COUNT+1))
        s3_sync
    fi
}
 
create_snapshot()
{
    rm -rf $SNAPSHOT_MOUNT*
    cd $FULL_BACKUP_DIR
    eval $LOG `pwd` >> $LOG_FILE
    eval $LOG "copying mysql data from `pwd` to snapshot mount" >> $LOG_FILE
    cp -R ./* $SNAPSHOT_MOUNT
    $INNOBACKUP_COMMAND --apply-log --use-memory=2g $SNAPSHOT_MOUNT
    eval $LOG "copy finished, creating ebs snapshot" >> $LOG_FILE
    RESPONSE=`aws ec2 create-snapshot --volume-id $SNAPSHOT_VOLUME --description "MySQL production snapshot for $WEEK" --region=us-east-1`
    eval $LOG $RESPONSE >> $LOG_FILE
    SNAPSHOT_ID=`$RESPONSE |grep -o snap-........`
    aws ec2 create-tags --resources $SNAPSHOT_ID --tags Key=type,Value=mysqlvolume Key=date,Value=`basename $CURRENT_BACKUP_DIR` --region=us-east-1
    aws ec2 modify-snapshot-attribute --snapshot-id $SNAPSHOT_ID --attribute createVolumePermission --operation-type add --user-ids 317085423413 --region=us-east-1
}
 
 
backup()
{
    FULL_BACKUP_COUNT=$(grep "incremental = N" $TARGET_DIRECTORY*/*/xtrabackup_info |wc -l)
    INCREMENTAL_COUNT=$(grep "incremental = Y" $TARGET_DIRECTORY*/*/xtrabackup_info |wc -l)
    eval $LOG "Starting mysql backup" >> $LOG_FILE
    if [ $INCREMENTAL_COUNT -gt 5 ]; then
        eval $LOG "Incremental count exceeded, moving to s3, snapshot, and deleting" >> $LOG_FILE
        s3_sync
        backup
    elif [ $FULL_BACKUP_COUNT -gt 1 ]; then
        eval $LOG "More than one full backup found, starting over" >> $LOG_FILE
        rm -rf $TARGET_DIRECTORY/week*
        backup
    elif [ $FULL_BACKUP_COUNT -eq 1 ]; then
        eval $LOG "Full backup exists, performing incremental backup" >> $LOG_FILE
        $INNOBACKUP_COMMAND --slave-info --incremental $FULL_BACKUP_DIR/..
        if [ $? -eq 0 ]; then
            eval $LOG "Backup completed successfully" >> $LOG_FILE
        else
            eval $LOG "Backup failed, check logs" >> $LOG_FILE
        fi
    else
        eval $LOG "No backups found, performing full backup" >> $LOG_FILE
        mkdir -p $TARGET_DIRECTORY$WEEK
        $INNOBACKUP_COMMAND --slave-info $TARGET_DIRECTORY$WEEK
        if [ $? -eq 0 ]; then
            eval $LOG "Backup completed successfully" >> $LOG_FILE
        else
            eval $LOG "Backup failed, check logs" >> $LOG_FILE
        fi
    fi
}
 
backup
