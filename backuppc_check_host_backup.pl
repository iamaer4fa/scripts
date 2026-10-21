#!/usr/bin/perl
use strict;
use warnings;
use lib "/usr/share/backuppc/lib"; # Adjust this path if needed
use BackupPC::Lib;
use JSON::PP;
use CGI qw(:standard);

# 1. Set the content type for JSON output
print header('application/json');

# 2. Get the host identifier from the URL query string
# Accept either a registered hostname or an IP address.
my $host_input = param('host');
my $host = $host_input;

# 3. Handle missing host parameter
unless ($host) {
    print JSON::PP->new->utf8->canonical->encode({
        host        => undef,
        registered  => JSON::PP::false,
        message     => "No hostname was provided. Please use ?host=<hostname>",
        status_code => "MISSING_HOST"
    }), "\n";
    exit;
}

# 4. Initialize the BackupPC library
my $bpc = BackupPC::Lib->new();
unless ($bpc) {
    print JSON::PP->new->utf8->canonical->encode({
        host        => $host,
        registered  => JSON::PP::false,
        message     => "Failed to initialize BackupPC::Lib. Check server logs.",
        status_code => "BACKUPPC_INIT_FAILED"
    }), "\n";
    exit;
}

# 4a. Resolve an IP address to a registered BackupPC hostname
#if (defined $host && $host =~ /^\d{1,3}(?:\.\d{1,3}){3}$/) {
#    my $hosts = $bpc->HostInfoRead();
#
#    if (ref($hosts) eq 'HASH') {
#        my @matches = grep {
#            ref($hosts->{$_}) eq 'HASH'
#            && defined $hosts->{$_}{hostIP}
#            && $hosts->{$_}{hostIP} eq $host
#        } keys %$hosts;
#
#        if (@matches == 1) {
#            $host = $matches[0];
#        }
#    }
#}

# If an IP address was supplied, find the registered BackupPC
# hostname whose DNS-resolved address matches it.
if (defined $host && $host =~ /^\d{1,3}(?:\.\d{1,3}){3}$/) {
    my $hosts = $bpc->HostInfoRead();

    if (ref($hosts) eq 'HASH') {
        HOST_SEARCH:
        for my $registered_host (keys %$hosts) {
            my @addresses = `/usr/bin/getent ahostsv4 "$registered_host" 2>/dev/null`;
            for my $line (@addresses) {
                if ($line =~ /^\s*(\d{1,3}(?:\.\d{1,3}){3})\s/
                    && $1 eq $host_input) {
                    $host = $registered_host;
                    last HOST_SEARCH;
                }
            }
        }
    }
}



# 5. Read the backup history and host state
my @backups  = $bpc->BackupInfoRead($host);
my %hostinfo = $bpc->HostInfoRead($host);

# 6. Initialize the result hash with friendly defaults
my $result = {
    host                    => $host,
    registered              => JSON::PP::false,
    backup_status           => "not_registered",
    status_code             => "NOT_REGISTERED",
    message                 => "This host is not registered in BackupPC. No backups have ever been configured for it.",
    last_backup             => undef,
    last_successful_backup  => undef,
    backup_type             => undef,
    backup_age_minutes      => undef,
    backup_number           => undef,
    backup_size             => undef,
    backup_state            => undef,
    last_error              => undef,
    last_attempt_result     => undef,
    xfer_errors             => undef,
    num_full                => undef,
    num_incr                => undef,
};

# Helper: format a Unix timestamp into ISO 8601
sub format_time {
    my $t = shift;
    return undef unless $t;
    my ($sec, $min, $hour, $mday, $mon, $year) = localtime($t);
    $year += 1900;
    $mon  += 1;
    return sprintf("%04d-%02d-%02dT%02d:%02d:%02d", $year, $mon, $mday, $hour, $min, $sec);
}

# 7. If the host has any backups, populate real data
if (@backups) {
    $result->{registered} = JSON::PP::true;

    # Sort backups by number descending
    my @sorted = sort { $b->{num} <=> $a->{num} } @backups;
    my $most_recent = $sorted[0];

    # Basic info from the most recent attempt
    $result->{backup_number} = $most_recent->{num};
    $result->{backup_type}   = $most_recent->{type};
    $result->{backup_size}   = $most_recent->{sizeNew} // $most_recent->{size};
    $result->{xfer_errors}   = $most_recent->{xferErrs} // 0;
    $result->{last_backup}   = format_time($most_recent->{startTime});

    # Find the last SUCCESSFUL backup
    my $last_successful;
    foreach my $b (@sorted) {
        if ($b->{endTime} && (!$b->{xferErrs} || $b->{xferErrs} == 0)) {
            $last_successful = $b;
            last;
        }
    }
    if ($last_successful) {
        $result->{last_successful_backup} = format_time($last_successful->{startTime});
        my $age = int((time() - $last_successful->{startTime}) / 60);
        $result->{backup_age_minutes} = $age;
    }

    # Count fulls and incrementals
    my $fulls = 0;
    my $incrs = 0;
    foreach my $b (@backups) {
        $fulls++ if ($b->{type} // '') eq 'full';
        $incrs++ if ($b->{type} // '') eq 'incr';
    }
    $result->{num_full} = $fulls;
    $result->{num_incr} = $incrs;

    # Host-level state and last error
    $result->{backup_state}        = $hostinfo{state}            // "Unknown";
    $result->{last_error}          = $hostinfo{lastError}        // undef;
    $result->{last_attempt_result} = $hostinfo{lastBackupResult} // undef;

    # --- Status determination ---

    # Priority 1: Backup is currently running
    if (defined $hostinfo{state} && $hostinfo{state} eq 'Backup') {
        $result->{backup_status} = "in_progress";
        $result->{status_code}   = "IN_PROGRESS";
        $result->{message}       = "Backup is currently running for this host.";
    }
    # Priority 2: Last attempt had transfer errors
    elsif ($most_recent->{xferErrs} && $most_recent->{xferErrs} > 0) {
        $result->{backup_status} = "failed";
        $result->{status_code}   = "BACKUP_FAILED";
        $result->{message}       = $hostinfo{lastError}
            ? "Last attempt failed: $hostinfo{lastError}"
            : "Last attempt failed with $most_recent->{xferErrs} transfer errors.";
    }
    # Priority 3: Last attempt completed successfully
    elsif ($most_recent->{endTime}) {
        $result->{backup_status} = "success";
        $result->{status_code}   = "OK";
        $result->{message}       = "Last attempt completed successfully.";
    }
    # Priority 4: Ambiguous — no end time, not running, no errors
    else {
        $result->{backup_status} = "unknown";
        $result->{status_code}   = "UNKNOWN";
        $result->{message}       = "Last attempt did not complete, but BackupPC is not reporting it as active.";
    }

    # Downgrade to STALE if the last successful backup is over 24 hours old
    if (
        ($result->{status_code} eq "OK") &&
        defined $result->{backup_age_minutes} &&
        $result->{backup_age_minutes} > 1440
    ) {
        $result->{status_code} = "STALE";
        $result->{message}     = "Last backup succeeded, but it is more than 24 hours old.";
    }

    # If the host exists but has never had a successful backup, mark it
    if (!$last_successful && $result->{status_code} eq "OK") {
        $result->{status_code}   = "NEVER_SUCCEEDED";
        $result->{message}       = "BackupPC knows this host, but no successful backup has ever completed.";
        $result->{backup_status} = "failed";
    }
}

# 8. Output the result as JSON
print JSON::PP->new->utf8->canonical->encode($result), "\n";