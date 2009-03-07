# -*- perl -*-

package Backup;

use Exporter ();
@ISA = qw(Exporter);

# These are exported by default
@EXPORT = qw(config_to_string init_run run log_success log_message
             log_fatal log_verbose log_init);

# These are exported on request
@EXPORT_OK = qw();

use IO::File;
use strict;


##################################################
# here we store the logged information

my $log_string = "";
my $log_verbose;
my $log_quiet;
my $log_file;
my $log_handle;
my $log_onfail;
my $log_onsucc;

##################################################
# initialize logging

sub log_init {
  my $configuration = shift;

  $log_verbose = $configuration->{VERBOSE};
  $log_quiet = $configuration->{QUIET};
  $log_verbose = $configuration->{VERBOSE};
  $log_onfail = $configuration->{EMAIL_FAIL};
  $log_onsucc = $configuration->{EMAIL_SUCC};

  if ($configuration->{LOG}) {
    if ($configuration->{MODE} eq "client") {
      $log_file = Backup::canonical_filename($configuration->{LOG_FILE},
					     $configuration->{CLIENT_BASEDIR});
    }
    elsif ($configuration->{MODE} eq "server") {
      $log_file = Backup::canonical_filename($configuration->{LOG_FILE},
					     $configuration->{SERVER_BASEDIR});
    }

    # open the log file, but do not abort if open fails
    
    $log_handle = new IO::File "> $log_file";
    if (!defined($log_handle)) {
      print STDERR "WARNING: Cannot open log file \"$log_file\" (continuing anyway)\n";
      $log_handle->close;
    }

  }

  my $now = localtime;
  log_message ($configuration->{VERSION} . " started on $now\n");
}


##################################################
# log a verbose message

sub log_verbose {
  if ($log_verbose) {
    my $msg = shift;
    $log_string .= $msg;
    if (defined($log_file)) { print $log_handle $msg; }
    if (!$log_quiet) { $| = 1; print $msg; }
  }
}

##################################################
# log an important message

sub log_message {
  my $msg = shift;

  $log_string .= $msg;

  if (defined($log_file)) { print $log_handle $msg; }

  if (!$log_quiet) { $| = 1; print $msg; }
}

##################################################
# log a fatal failure (send email, and die)

sub log_fatal {
  my $msg = shift;
  my $now = localtime;

  $msg .= "\nBackup failed at $now.\n";

  $log_string .= $msg;

  if (defined($log_file)) { print $log_handle $msg; $log_handle->close; }

  if (!$log_quiet) {
    $| = 1; print $msg;
  }

  if (defined($log_onfail)) {
    open (MAIL, "| mail -s \"Backup Failure\" $log_onfail");
    print MAIL $log_string;
    close MAIL;
  }

  exit 1;
}

##################################################
# log a final success (close logfile, send email, quit)

sub log_success {
  my $msg = shift;
  my $now = localtime;

  $msg .= "\nFinised successfully at $now.\n";

  $log_string .= $msg;

  if (defined($log_file)) { print $log_handle $msg; $log_handle->close; }

  if (!$log_quiet) { $| = 1; print $msg; }

  if (defined($log_onsucc)) {
    open (MAIL, "| mail -s \"Backup Success\" $log_onsucc");
    print MAIL $log_string;
    close MAIL;
  }

  exit 0;
}

##################################################
### convert confguration to a string

sub config_to_string {
  my $configuration = shift;

  my $str = "";

  foreach my $k (sort(keys %$configuration)) {
    if ($k eq "EXCLUDE") {
      $str .= "$k = [" . join(",", @{$configuration->{$k}}) . "]\n";
    }
    else {
      $str .= "$k = " . $configuration->{$k} . "\n";
    }
  }

  return $str;
}


##################################################
### canonical form of a file name

sub canonical_filename {
  my ($file, $base) = @_;

  if (substr($file, 0, 1) eq "/") {
    return $file;
  }
  else {
    return $base . "/" . $file;
  }

}


##################################################
### parse the config file

sub parse_config {
  my $data = shift;
  my $configuration = shift;
  my $file = shift;
  my $lineno = 0;
  my $l;

  foreach my $line (@$data) {
    $lineno++;

    # skip comments and empty lines
    next if (($line =~ m/^\#/) or ($line =~ m/^\s*$/));

    # line matches 'keyword = value(s)' or 'keyword value(s)'
    if ($line =~ m/^\s*([a-zA-Z0-9_\-]+)\s*=?\s*(.*)$/) {
      my $opt = lc $1;
      my $val = $2;

      if ($opt eq "exclude") {
	my @dirs = split(" ", $val);

	foreach my $d (@dirs) {
	  $d = "-" . $d;
	}

	push @{$configuration->{EXCLUDE}}, @dirs;
      }
      if ($opt eq "include") {
	my @dirs = split(" ", $val);

	foreach my $d (@dirs) {
	  $d = "+" . $d;
	}

	push @{$configuration->{EXCLUDE}}, @dirs;
      }
      elsif ($opt eq "keep") {
	my @keeplist = split(" ", $val);
	if ($#keeplist != 4) {
	  log_fatal "$file, line $lineno: the \'keep\' directive requires precisely 5 arguments.\n";
	}

	($configuration->{KEEP_DAILY},
	 $configuration->{KEEP_WEEKLY},
	 $configuration->{KEEP_MONTHLY},
	 $configuration->{KEEP_HALFYEARLY},
	 $configuration->{KEEP_YEARLY}) = @keeplist;
      }
      elsif ($opt eq "sshid") {
	$configuration->{SERVER_SSH_ID} = $val;
      }
      elsif ($opt eq "secondary_sshid") {
        $configuration->{SECONDARY_SSH_ID} = $val;
      }
      elsif ($opt eq "client") {
	($configuration->{CLIENT},
	 $configuration->{CLIENT_BASEDIR}) = parse_ssh_location($val);
      }
      elsif ($opt eq "secondary") {
	($configuration->{SECONDARY},
	 $configuration->{SECONDARY_BASEDIR}) = parse_ssh_location($val);
      }
      elsif ($opt eq "rsync-options") {
	$configuration->{OPTIONS_RSYNC} .= " $val";
      }
    }
    else {
      log_fatal "$file, line $lineno: syntax error\n";
    }
  }
}

##################################################
# run a command locally

my $dry_run;

sub init_run {
  my $configuration = shift;

  $dry_run = $configuration->{DRY_RUN};

  if ($dry_run) {
    log_message "\n\n\********************THIS IS A DRY-RUN********************\n\n";
  }
}

sub run {
  my $command = shift;

  log_message "\n$command\n";
  if (!$dry_run) {
    log_message `$command 2>&1` . "\n";
    my $status = $? >> 8;
    if ($status == 24) {
      # a file disappeared during backup
      log_message "\nSome files disappeared during the backup process.\n"
    }
    elsif ($status) {
      # the process died in an unexpected way
      log_fatal "\nThe last command failed with exit status $status.\n";
    }
  }
}


##################################################
##################################################
# Routines for computing which backups should be
# kept

##################################################
# Auxiliary routine for kept_backups

sub get_newest_oldest {
  my ($dates, $start, $end) = @_;

  ### from the SORTED list of $dates, extract the newest and
  ### the oldest date that is in the interval [$start, $end).

  my ($new, $old);

  foreach my $d (@$dates) {
    if (($start le $d) && ($d le $end)) {
      if (!defined($new) || ($d le $new)) { $new = $d; }
      if (!defined($old) || ($d ge $old)) { $old = $d; }
    }
  }

  my @res;
  if (defined($new)) { push @res, $new; }
  if (defined($old) && ($old ne $new)) { push @res, $old; }
  return @res;
}

##################################################
# Compute which backups should be kept

sub kept_backups {
  my ($backups, $configuration) = @_;

  ### the assumption here is that $backups is a ref to a SORTED
  ### array of backups. The backups are given as strings in the
  ### form "yyyy-mm-dd hh:mm:ss". This seems to be the form that
  ### makes the 'date' command happiest.

  ### Each backup falls in one "time slot". We keep the youngest and 
  ### the oldest backup in each slot.

  ### We avoid using the system clock to figure out which backups
  ### should be kept. Instead we use the latest backup as the "current time".
  ### This way we are protected from accidents caused by bogus system clocks.

  ### What the heck, people are idiots, let's sort $backups

  @$backups = sort @$backups;

  ### Get the "current" time from the latest backup


  $backups->[-1] =~ m/^(\d+)-(\d+)-(\d+).*/;

  my $c = "date --date=\"$1-$2-$3 day\" +%Y-%m-%d";

  chomp(my $now = `$c`);

  ### daily slots

  my $k_daily = $configuration->{KEEP_DAILY};
  my @daily;

  for (my $i = 0; $i < $k_daily;) {
    chomp(my $end = `date --date="$now $i day ago" +%Y-%m-%d`);
    $i++;
    chomp(my $start = `date --date="$now $i day ago" +%Y-%m-%d`);

    push @daily, get_newest_oldest($backups, $start, $end);
  }

  ### weekly slots

  my $k_weekly = $configuration->{KEEP_WEEKLY};
  my @weekly;

  for (my $i = 0; $i < $k_weekly;) {
    chomp(my $end = `date --date="$now $i week ago" +%Y-%m-%d`);
    $i++;
    chomp(my $start = `date --date="$now $i week ago" +%Y-%m-%d`);

    push @weekly, get_newest_oldest($backups, $start, $end);
  }

  ### monthly slots

  my $k_monthly = $configuration->{KEEP_MONTHLY};
  my @monthly;

  for (my $i = 0; $i < $k_monthly;) {
    chomp(my $end = `date --date="$now $i month ago" +%Y-%m-%d`);
    $i++;
    chomp(my $start = `date --date="$now $i month ago" +%Y-%m-%d`);

    push @monthly, get_newest_oldest($backups, $start, $end);
  }

  ### halfyearly slots

  my $k_halfyearly = $configuration->{KEEP_HALFYEARLY};
  my @halfyearly;

  for (my $i = 0; $i < $k_halfyearly; $i++) {
    my $j = 6 * $i;
    chomp(my $end = `date --date="$now $j month ago" +%Y-%m-%d`);
    $j += 6;
    chomp(my $start = `date --date="$now $j month ago" +%Y-%m-%d`);

    push @halfyearly, get_newest_oldest($backups, $start, $end);
  }

  ### yearly slots

  my $k_yearly = $configuration->{KEEP_YEARLY};
  my @yearly;

  for (my $i = 0; $i < $k_yearly;) {
    chomp(my $end = `date --date="$now $i year ago" +%Y-%m-%d`);
    $i++;
    chomp(my $start = `date --date="$now $i year ago" +%Y-%m-%d`);

    push @yearly, get_newest_oldest($backups, $start, $end);
  }

  return [@daily, @weekly, @monthly, @halfyearly, @yearly];
}

##################################################
### parse ssh location

sub parse_ssh_location {
  my $s = shift;

  if ($s =~ m/^(.*):(.*)$/) {
    return ($1, $2);
  }
  else {
    log_fatal "Could not parse '$s'. Expected form was user\@host:directory\n";
  }
}

##################################################
# make perl happy

1;

##################################################
# the end
