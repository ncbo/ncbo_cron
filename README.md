# ncbo_cron

## Run the ncbo_cron daemon

To run it use the `bin/ncbo_cron` command

Running this command without option will cause to run the jobs according to the settings defined in the NcboCron config file. Or by default in [ncbo_cron/lib/ncbo_cron/config.rb](https://github.com/ncbo/ncbo_cron/blob/master/lib/ncbo_cron/config.rb)

But the user can define options to change some settings.
Example to run the flush old graph job every 3 hours and to disable the automatic pull of new submissions

```
bin/ncbo_cron --flush-old-graphs "0 */3 * * *" --disable-pull
```

It will run by default as a daemon

But it will not run as a daemon if you use one of the following options:

* console (to open a pry console
* view_queue (view the queue of jobs waiting for processing)
* queue_submission (adding a submission to the processing submission queue)
* kill (stop the ncbo_cron daemon)

## Stop the ncbo_cron daemon

The PID of the ncbo_cron process is in /var/run/ncbo_cron/ncbo_cron.pid

To stop the ncbo_cron daemon: 
```
bin/ncbo_cron -k
```
