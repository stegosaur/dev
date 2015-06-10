# -*- coding: utf-8 -*-
#uploads video to jwplatform via api, waits for it to finish, pushes time to process to nagios as a passive check
#sample: [1432241817] PROCESS_SERVICE_CHECK_RESULT;encoder-stats.longtailvideo.com;JWPlatform Upload and wait until ready via API;0;OMGLOL
import os
import hashlib
import time
import sys
import logging

from botr.api import API

logging.basicConfig(filename='api_upload.log',level=logging.DEBUG, format='%(asctime)s %(message)s')
# Please update kkkk with your key and ssss with your secret
api = API('kkkkkkkk', 'ssssssssssssssssssssssss')

base_dir = u'/usr/lib/nagios/plugins'
file_name = u'Pixar.mp4'

file_path = os.path.join(base_dir, file_name)
# file_size and file_md5 are optional
file_size = os.path.getsize(file_path)
file_md5 = hashlib.md5(open(file_path, 'rb').read()).hexdigest()

nagios_cmd_file = u'/var/lib/nagios3/rw/nagios.cmd'

call_params = {
    'title': 'New test video',
    'tags': 'new, test, video, upload',
    'description': 'New video',
    'link': 'http://www.bitsontherun.com',
    'author': 'Bits on the Run',
}

while True:
    response = api.call('/videos/list')
    try:
        if response['total'] == 1:
            try:
                if response['videos'][0]['status'] == 'ready':
                 time_process_complete = time.time()
                 time_to_process = time_process_complete - time_upload_complete
                 if time_to_process < 500:
                     message = '0;OK: video processing successful after %s seconds | time_to_process=%s' % (time_to_process, time_to_process)
                 else:
                     message = '1;WARNING: video processing successful after %s seconds | time_to_process=%s' % (time_to_process, time_to_process)
                 f = open(nagios_cmd_file, 'r+')
                 to_write = '[%s] PROCESS_SERVICE_CHECK_RESULT;encoder-stats.longtailvideo.com;JWPlatform Upload and wait until ready via API;%s' % (int(time.time()), message)
                 f.write(to_write)
                 f.close()
                 api.call('/videos/delete', {'video_key': response['videos'][0]['key'] }, verbose=False )
            except:
                logging.info(sys.exc_info()[0])
        elif response['total'] == 0:
            try:
                response = api.call('/videos/create', call_params, verbose=False)
                if response['status'] == 'ok':
                    logging.info(response['media']['key'])
                    api.upload(response['link'], file_path, verbose=False)
                    time_upload_complete = time.time()
            except:
                logging.info(sys.exc_info()[0])
                f = open(nagios_cmd_file, 'r+')
                to_write = '[%s] PROCESS_SERVICE_CHECK_RESULT;encoder-stats.longtailvideo.com;JWPlatform Upload and wait until ready via API;2;CRITICAL: videos/create failed' % (int(time.time()))
                f.write(to_write)
                f.close()
                time.sleep(30)
    except:
        logging.info(sys.exc_info()[0])
    time.sleep(1)
