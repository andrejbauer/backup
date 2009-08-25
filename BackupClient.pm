# -*- perl -*-

package BackupClient;

use Backup;
use strict;


##################################################
# read local config file

sub get_config_file {
  my $configuration = shift;

  my $file = Backup::canonical_filename($configuration->{CLIENT_CONF_FILE},
					$configuration->{CLIENT_BASEDIR});

  open (F, $file) or log_fatal "Could not open $file.\n";

  my $line;
  chomp ($line = <F>);

  close F or log_fatal "Could not close $file.\n";

  my @s = split(" ", $line);

  if ($#s != 1) {
    log_fatal "$file must have the form: <ssh_id_file> <user\@host:remote_basedir>\n";
  }

  my $t;

  ($configuration->{CLIENT_SSH_ID}, $t) = @s;
  ($configuration->{SERVER}, $configuration->{SERVER_BASEDIR}) = Backup::parse_ssh_location($t);
}



##################################################
# run remote routines

my $run_wrapper; 
my $dry_run;

sub init_run_remote {
  my $configuration = shift;

  $dry_run = $configuration->{DRY_RUN};

  ### at this point the $configuration should know
  ### where the server is, and what ssh identity to use

  my $server = $configuration->{SERVER};
  my $sshid = Backup::canonical_filename($configuration->{CLIENT_SSH_ID},
					 $configuration->{CLIENT_BASEDIR});

  $run_wrapper = "ssh -x -a -q -n -i $sshid $server ";

  log_verbose "\nWrapper for remote commands is: $run_wrapper\n";
}

sub run_remote {
  my $command = shift;

  log_message "\n$run_wrapper \'$command\'\n";
  if (!$dry_run) {
    log_message `$run_wrapper \'$command 2>&1\'` . "\n";
    my $status = $? >> 8;
    if ($status) {
      # the process died in some unexpected way
      log_fatal "\nThe last command failed with exit status $status.\n";
    }
  }
}


sub run_remote_with_output {
  my $command = shift;

  log_verbose "\n$run_wrapper $command\n";
  my $out = `$run_wrapper $command 2>/dev/null`;
  log_verbose "$out\n";
  return $out;
}


##################################################
# read remote config file

sub get_remote_config_file {
  my $configuration = shift;

  ### at this point the $configuration should know
  ### where the server is, and what ssh identity to use

  my $server = $configuration->{SERVER};
  my $file = Backup::canonical_filename($configuration->{SERVER_CONF_FILE},
					$configuration->{SERVER_BASEDIR});
  my $sshid = Backup::canonical_filename($configuration->{CLIENT_SSH_ID},
					 $configuration->{CLIENT_BASEDIR});

  my $pipe = "ssh -x -a -q -n -i $sshid $server cat $file";

  open (F, "$pipe|") or log_fatal "Could not run $pipe";

  my @data;
  chomp(@data = <F>);

  close F or log_fatal "Could not close the pipe.";

  Backup::parse_config(\@data, $configuration, "$server:$file");
}


##################################################
# the main client routine

sub handle {
  my $configuration = shift;

  ### read the config file to find out various things
 
  get_config_file($configuration);

  get_remote_config_file($configuration);

  log_verbose ("Configuration:\n" . ("-" x 70) . "\n" .
	       config_to_string($configuration) . "\n" .
	      ("-" x 70) . "\n");

  my $basedir = $configuration->{SERVER_BASEDIR};

  init_run_remote($configuration);
 
  if ($configuration->{BACKUP}) {
    ### get the date in suitable format FROM THE SERVER
  
    my $date = run_remote_with_output "date \'+%Y_%m_%d_%H_%M_%S\'";
    chomp $date;

    ### find the latest backup, if there is one

    my @backups = split "\n", (run_remote_with_output "ls -dt $basedir/backup_*");

    ### find the latest backup, if there is one,
    ### and make a fresh copy of it

    if ($#backups >= 0) {
      chomp(@backups);
      @backups = sort(@backups);

      log_verbose "The following backups were found:\n" .
	join("\n", @backups) . "\n\n";

      my $latest = $backups[-1];

      log_verbose "Latest backup is $latest\n\n";

      ### copy (or create) the directory in which we put the backup

      run_remote "cp -al $latest $basedir/inprogress_$date";
    }
    else {
      log_verbose "No backups were found. Creating an initial one.\n";

      run_remote "mkdir -p $basedir/inprogress_$date";
    }

    ### compute the rsync parameters

    my $sshid = Backup::canonical_filename($configuration->{CLIENT_SSH_ID}, $basedir);
    my $from = $configuration->{CLIENT_BASEDIR};
    my $to = $configuration->{SERVER} . ":$basedir/inprogress_$date";
    my $excludes = "";
    my $useropts = $configuration->{OPTIONS_RSYNC};

    foreach my $e (@{$configuration->{EXCLUDE}}) {
      if ($e =~ m|^\-(.*)|) {
	$excludes .= " --exclude \'$1\'";
      }
      elsif ($e =~ m|^\+(.*)|) {
	$excludes .= " --include \'$1\'";
      }
    }

    ### run rsync on the directory

    run "rsync -azHSx --delete $useropts $excludes -e \"ssh -i $sshid\" $from $to";

    ### rename the backup directory

    run_remote "mv $basedir/inprogress_$date $basedir/backup_$date";

    ### fix the "latest" soft link

    run_remote "if [ -h $basedir/latest ]; then rm $basedir/latest; fi";

    run_remote "ln -s backup_$date $basedir/latest";

  }

  ### now delete old backups if necessary

  if ($configuration->{DELETE}) {
    ### recompute the list of backups since we just made a new one
    
    my @backups = split "\n", (run_remote_with_output "ls -dt $basedir/backup_*");

    if ($#backups < 0) {
      log_verbose "No backups were found, nothing to delete.\n";
    }
    else {
      chomp(@backups);
      @backups = sort(@backups);

      log_verbose "The following backups were found:\n" .
	join("\n", @backups) . "\n\n";
      
      
      foreach my $b (@backups) {
	$b =~ s/^.*backup_(\d+)_(\d+)_(\d+)_(\d+)_(\d+)_(\d+)$/\1-\2-\3 \4:\5:\6/;
      }

      sort(@backups);

      ### get the list of the backups that need to be KEPT

      my $kept = Backup::kept_backups(\@backups, $configuration);

      my %lookup;

      foreach my $f (@$kept) {
	$f=~ s|(\d+)-(\d+)-(\d+)\ (\d+):(\d+):(\d+)|$basedir/backup_\1_\2_\3_\4_\5_\6|;
	$lookup{$f} = 1;
      }

      log_verbose "The following backups must be kept:\n" .
	join("\n", (sort (keys %lookup))) . "\n\n";

      ### remove 1 non-kept backup

      @backups = split "\n", (run_remote_with_output "ls -dt $basedir/backup_*");
      chomp(@backups);
    
      foreach my $b (@backups) {
	if ($lookup{$b} != 1) {
	  log_message "Removing the backup $b\n";
	  my $f = $b;
	  $f =~ s|backup_(\d+_\d+_\d+_\d+_\d+_\d+)$|deleting_\1|;
	  run_remote "mv $b $f";
	  run_remote "rm -rf $f &";
	  last;
	}
      }
    }
  }

  log_success "";

}

##################################################
# make perl happy

1;

##################################################
# the end
