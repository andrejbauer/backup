Backup is a perl script that creates remote backups. It uses ssh and rsync and
should work well on Unix-based system.

Backup organizes its backups much like the OSX Time machine does. Backup has existed since
late year 2000 and so predates Time machine. I am writing this in case anyone cares about
prior art.

Read the file `INSTALL.txt` for installation instructions.

Features:

* either the client or the backup server can initiate backup
* uses ssh for authentication
* makes incremental backups, but stores them as complete images with shared content
* can be automatized as a cron job

The script could probably use some updating and improvements, so pull requests are
welcome.

