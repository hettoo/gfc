#!/usr/bin/perl

use strict;
use warnings;

use Net::FTP;
use Cwd;
use File::Find;
use File::Basename;
use File::Copy;
use File::Path qw(make_path remove_tree);
use Digest::MD5;

my $ftp;
my $cwd;

my $local_changed = 0;
my $remote_changed = 0;

my $mode = shift @ARGV;
if (!defined $mode) {
    help();
}
if ($mode eq 'help') {
    help(0);
}

my $base = getcwd();
$base =~ s+/$++;
my $offset = '';
my $gfc_dir;
while (!defined $gfc_dir && $base ne '') {
    $gfc_dir = $base . '/.gfc/';
    if (!-d $gfc_dir) {
        undef $gfc_dir;
        if ($base ne '') {
            $offset = basename($base) . '/' . $offset;
            $base = dirname($base);
            $base =~ s+/$++;
        }
    }
}
$base .= '/';
if ($mode eq 'init') {
    if (defined $gfc_dir) {
        error("gfc dir already present: $gfc_dir");
    }
    $gfc_dir = getcwd();
    $gfc_dir =~ s+/$++;
    $gfc_dir .= '/.gfc/';
    mkdir $gfc_dir or error("unable to create $gfc_dir");
    exit;
} elsif (!defined $gfc_dir) {
    error("no gfc directory found, use gfc init first");
}

my @targets;
my @targets_full;
if (@ARGV) {
    for my $target (@ARGV) {
        push @targets, resolve_file($offset . $target);
        push @targets_full, $base . resolve_file($offset . $target);
    }
} else {
    push @targets, '';
    push @targets_full, $base;
}

my $fh;

my %config;
my $config_file = $gfc_dir . 'config';
assure_file($config_file);
open $fh, '<', $config_file or error("unable to open $config_file");
while (my $line = <$fh>) {
    if ($line =~ /^\s*([a-zA-Z0-9]+)\s*=\s?(.*)$/) {
        my $name = $1;
        my $value = $2;
        $config{$name} = $value;
    }
}
close $fh;

my $ignore_file = $gfc_dir . 'ignore';
my @ignore;
my @full_ignore;
assure_file($ignore_file);

my $local_file = $gfc_dir . 'local';
my %local_mdtm;
my %local_hash;
assure_file($local_file);

my $remote_file = $gfc_dir . 'remote';
my %remote_mdtm;
assure_file($remote_file);

my %found;
my %pushed_dir;

if ($mode eq 'test') {
    ftp_connect();
    print "Initial directory: $cwd\n";
} elsif ($mode eq 'status') {
    load_ignore();
    load_local();
    mode_status();
} elsif ($mode eq 'sim') {
    load_ignore();
    load_remote();
    load_local();
    mode_sim();
} elsif ($mode eq 'pull') {
    load_ignore();
    load_remote();
    load_local();
    mode_pull();
} elsif ($mode eq 'clone') {
    load_ignore();
    load_remote();
    load_local();
    mode_clone();
} elsif ($mode eq 'push') {
    load_ignore();
    load_local();
    load_remote();
    mode_push();
} elsif ($mode eq 'backup') {
    load_ignore();
    load_local();
    mode_backup();
} elsif ($mode eq 'reset') {
    load_ignore();
    mode_reset();
} elsif ($mode eq 'clean') {
    load_ignore();
    mode_clean();
} elsif ($mode eq 'ls') {
    mode_ls();
} elsif ($mode eq 'mv') {
    load_local();
    load_remote();
    mode_mv();
} elsif ($mode eq 'rm') {
    load_local();
    load_remote();
    mode_rm();
} elsif ($mode eq 'mkdir') {
    mode_mkdir();
} elsif ($mode eq 'rmdir') {
    mode_rmdir();
} elsif ($mode eq 'site') {
    mode_site();
} else {
    help();
}

quit();

sub ftp_cd {
    my ($sub) = @_;
    if (!defined $sub) {
        $sub = '/';
    }
    if ($sub !~ m+/$+) {
        $sub .= '/';
    }
    if ($cwd eq '/') {
        $cwd = '';
    }
    $cwd .= $sub;
    $ftp->mkdir($cwd, 1);
    $ftp->cwd($cwd) or error("could not change remote working directory to $cwd");
}

sub ftp_connect {
    if (defined $ftp) {
        return;
    }
    $ftp = Net::FTP->new($config{'host'}) or error("could not connect: $!");
    $ftp->login($config{'user'}, $config{'password'}) or error("could not login: $!");
    $cwd = $ftp->pwd();
    if ($cwd !~ m+/$+) {
        $cwd .= '/';
    }
    ftp_cd($config{'dir'});
    $ftp->binary() or error("could not change to binary mode");
}

sub quit {
    my ($fake) = @_;
    if ($local_changed) {
        save_local();
    }
    if ($remote_changed) {
        save_remote();
    }
    if (defined $ftp) {
        $ftp->quit();
    }
    if (!$fake) {
        exit;
    }
}

sub error {
    my ($message) = @_;
    quit(1);
    die 'Error: ' . $message . "\n";
}

sub load_ignore {
    open $fh, '<', $ignore_file or error("unable to read $ignore_file");
    while (my $line = <$fh>) {
        chomp $line;
        if ($line =~ s+^/++) {
            push @full_ignore, $line;
        } else {
            push @ignore, $line;
        }
    }
    close $fh;
}

sub load_local {
    open $fh, '<', $local_file or error("unable to read $local_file");
    while (my $line = <$fh>) {
        if ($line =~ /^(\d+?) (.+?) (.+)$/) {
            my $mdtm = int($1);
            my $hash = $2;
            my $file = $3;
            $local_mdtm{$file} = $mdtm;
            $local_hash{$file} = $hash;
        }
    }
    close $fh;
}

sub save_local {
    open $fh, '>', $local_file or error("unable to write $local_file");
    while (my ($file, $mdtm) = each %local_mdtm) {
        if (defined $mdtm) {
            my $hash = $local_hash{$file};
            print $fh "$mdtm $hash $file\n";
        }
    }
    close $fh;
}

sub load_remote {
    open $fh, '<', $remote_file or error("unable to read $remote_file");
    while (my $line = <$fh>) {
        if ($line =~ /^(\d+?) (.+)$/) {
            my $mdtm = int($1);
            my $file = $2;
            $remote_mdtm{$file} = $mdtm;
        }
    }
    close $fh;
}

sub save_remote {
    open $fh, '>', $remote_file or error("unable to write $remote_file");
    while (my ($file, $mdtm) = each %remote_mdtm) {
        if (defined $mdtm) {
            print $fh "$mdtm $file\n";
        }
    }
    close $fh;
}

sub pattern_match {
    my ($string, $pattern) = @_;
    if ($string eq $pattern) {
        return 1;
    }
    if (length $pattern == 0) {
        return 0;
    }
    my $p = substr $pattern, 0, 1;
    if ($p eq '*') {
        if (pattern_match($string, (substr $pattern, 1)) || (length $string > 0 && pattern_match((substr $string, 1), $pattern))) {
            return 1;
        }
    }
    return (substr $string, 0, 1) eq $p && pattern_match((substr $string, 1), (substr $pattern, 1));
}

sub file_match {
    my ($file, $pattern) = @_;
    $file =~ s+/$++;
    $pattern =~ s+/(\*/?)*$++;
    my @p = split /\//, $pattern;
    my @f = split /\//, $file;
    if (@f < @p) {
        return 0;
    }
    for my $i (0 .. $#p) {
        if (!pattern_match($f[$i], $p[$i])) {
            return 0;
        }
    }
    return 1;
}

sub matches_target {
    my ($file) = @_;
    for my $target (@targets) {
        if (file_match($file, $target)) {
            return 1;
        }
    }
    return 0;
}

sub filter_file {
    my ($file, $dir) = @_;
    if ($file eq '.' || $file eq '..' || $file eq '.gfc' || $file eq '.git' || $file eq '.gitignore' || $file eq '.gitmodules' || $file =~ /^\.(.*)\.sw.$/ || $file =~ /~$/ || $file =~ m+/\.$+ || $file =~ /\.gfc_backup$/) {
        return 0;
    }
    for my $ignore (@full_ignore) {
        if (file_match($file, $ignore)) {
            return 0;
        }
    }
    my $full_file = $dir . $file;
    my $result = 1;
    for my $ignore (@ignore) {
        my $real = $ignore;
        my $negated = $real =~ s/^!//;
        if (file_match($full_file, $base . $real)) {
            $result = $negated;
        }
    }
    return $result;
}

sub remove_local {
    my ($remote, $physical) = @_;
    my $file = $base . $remote;
    if ($physical && -e $file) {
        unlink $file;
    }
    undef $local_mdtm{$remote};
    undef $local_hash{$remote};
    $local_changed = 1;
}

sub local_mdtm {
    my ($file, $only_if_cached) = @_;
    if ($only_if_cached && !defined $local_mdtm{$file}) {
        return undef;
    }
    return (stat $base . $file)[9];
}

sub local_hash {
    my ($file, $only_if_cached) = @_;
    if ($only_if_cached && !defined $local_hash{$file}) {
        return undef;
    }
    my $ctx = Digest::MD5->new;
    $file = $base . $file;
    open my $fh, '<', $file or error("unable to read $file");
    $ctx->addfile($fh);
    close $fh;
    return $ctx->hexdigest;
}

sub remote_mdtm {
    my ($file, $only_if_cached) = @_;
    if ($only_if_cached && !defined $remote_mdtm{$file}) {
        return undef;
    }
    my $mdtm = $ftp->mdtm($file) or error("unable to get modification time for $file");
    return int($mdtm);
}

sub remove_remote {
    my ($file, $physical) = @_;
    if ($physical) {
        $ftp->delete($file);
    }
    undef $remote_mdtm{$file};
    $remote_changed = 1;
}

sub update_remote {
    my ($file, $mdtm) = @_;
    if (!defined $mdtm) {
        $mdtm = remote_mdtm($file);
    }
    $remote_mdtm{$file} = $mdtm;
    $remote_changed = 1;
}

sub update_local {
    my ($remote, $mdtm, $hash) = @_;
    if (!defined $mdtm) {
        $mdtm = local_mdtm($remote);
    }
    if (!defined $hash) {
        $hash = local_hash($remote);
    }
    $local_mdtm{$remote} = $mdtm;
    $local_hash{$remote} = $hash;
    $local_changed = 1;
}

sub mode_status {
    find({'wanted' => \&status_file, 'preprocess' => \&local_filter}, @targets_full);
    for my $file (keys %local_mdtm) {
        if (matches_target($file) && !defined $found{$file} && filter_file($file, $base)) {
            print "Deleted: $file\n";
        }
    }
}

sub mode_push {
    find({'wanted' => \&push_file, 'preprocess' => \&local_filter}, @targets_full);
    for my $file (keys %local_mdtm) {
        if (matches_target($file) && !defined $found{$file} && filter_file($file, $base)) {
            print "> Deleting $file\n";
            ftp_connect();
            my $mdtm_remote;
            $mdtm_remote = remote_mdtm($file, 1);
            if (defined $remote_mdtm{$file} && $mdtm_remote != $remote_mdtm{$file}) {
                error("$file has changed on the server, pull first");
            }
            remove_remote($file, 1);
            remove_local($file, 0);
        }
    }
}

sub mode_backup {
    find({'wanted' => \&backup_file, 'preprocess' => \&local_filter}, @targets_full);
}

sub backup_file {
    my $file = $File::Find::name;
    my $remote;
    if ($file . '/' eq $base) {
        $remote = '';
    } else {
        $remote = substr $file, (length $base);
    }
    if (!-d $file) {
        my $mdtm = local_mdtm($remote, 1);
        if (!defined $local_mdtm{$remote} || $mdtm != $local_mdtm{$remote}) {
            my $hash = local_hash($remote, 1);
            if (!defined $local_hash{$remote} || $hash ne $local_hash{$remote}) {
                print "= Backing up $remote\n";
                copy($file, $file . '.gfc_backup');
            }
        }
    }
}

sub mode_reset {
    find({'wanted' => \&reset_file, 'preprocess' => \&filter_backup}, @targets_full);
}

sub reset_file {
    my $file = $File::Find::name;
    my $remote;
    if ($file . '/' eq $base) {
        $remote = '';
    } else {
        $remote = substr $file, (length $base), length $file;
    }
    if (!-d $file) {
        my $origin = $file;
        my $remote_origin = $remote;
        $origin =~ s/\.gfc_backup$//;
        $remote_origin =~ s/\.gfc_backup$//;
        if ($file ne $origin) {
            print "= Resetting $remote_origin\n";
            move($file, $origin);
        }
    }
}

sub mode_clean {
    find({'wanted' => \&clean_file, 'preprocess' => \&filter_backup}, @targets_full);
}

sub clean_file {
    my $file = $File::Find::name;
    my $remote;
    if ($file . '/' eq $base) {
        $remote = '';
    } else {
        $remote = substr $file, (length $base), length $file;
    }
    if (!-d $file) {
        my $origin = $file;
        my $remote_origin = $remote;
        $origin =~ s/\.gfc_backup$//;
        $remote_origin =~ s/\.gfc_backup$//;
        if ($file ne $origin) {
            print "= Resetting $remote_origin\n";
            unlink $file;
        }
    }
}

sub filter_backup {
    my(@files) = @_;
    my $dir = $File::Find::dir;
    if ($dir !~ m+/$+) {
        $dir .= '/';
    }
    my @result;
    for my $file (@files) {
        if (-d $dir . $file || $file =~ /\.gfc_backup$/) {
            push @result, $file;
        }
    }
    return @result;
}

sub local_filter {
    my(@files) = @_;
    my $dir = $File::Find::dir;
    if ($dir !~ m+/$+) {
        $dir .= '/';
    }
    my @result;
    for my $file (@files) {
        if (filter_file($file, $dir)) {
            push @result, $file;
        }
    }
    return @result;
}

sub status_file {
    my $file = $File::Find::name;
    my $remote;
    if ($file . '/' eq $base) {
        $remote = '';
    } else {
        $remote = substr $file, (length $base), length $file;
    }
    $found{$remote} = 1;
    if (!-d $file) {
        my $mdtm = local_mdtm($remote, 1);
        if (!defined $local_mdtm{$remote} || $mdtm != $local_mdtm{$remote}) {
            my $hash = local_hash($remote, 1);
            if (!defined $local_hash{$remote}) {
                print "Added: $remote\n";
            } elsif ($hash ne $local_hash{$remote}) {
                print "Modified: $remote\n";
            }
        }
    }
}

sub push_file {
    my $file = $File::Find::name;
    my $remote;
    if ($file . '/' eq $base) {
        $remote = '';
    } else {
        $remote = substr $file, (length $base), length $file;
    }
    $found{$remote} = 1;
    if (!-d $file) {
        my $mdtm = local_mdtm($remote);
        if (!defined $local_mdtm{$remote} || $mdtm != $local_mdtm{$remote}) {
            my $hash = local_hash($remote);
            if (!defined $local_hash{$remote} || $hash ne $local_hash{$remote}) {
                print "> Pushing $remote (" . (-s $file) . ")\n";
                ftp_connect();
                my $dir = dirname($remote);
                if (!$pushed_dir{$dir}) {
                    $ftp->mkdir($dir, 1);
                    $pushed_dir{$dir} = 1;
                }
                my $mdtm_remote = remote_mdtm($remote, 1);
                if (defined $remote_mdtm{$remote} && $mdtm_remote != $remote_mdtm{$remote}) {
                    error("$remote has changed on the server, pull first");
                } else {
                    $ftp->put($file, $remote) or error("unable to put $remote");
                    if (!defined $local_hash{$remote}) {
                        $ftp->site("CHMOD 644 $remote") or error("unable to chmod $remote");
                    }
                    update_remote($remote);
                    update_local($remote, $mdtm, $hash);
                }
            }
        }
    }
}

sub mode_sim {
    ftp_connect();
    find_remote(\&sim_file, @targets);
    for my $file (keys %remote_mdtm) {
        if (matches_target($file) && !defined $found{$file} && filter_file($file, $base)) {
            if (-e $base . $file) {
                print "Deleted: $file\n";
            }
        }
    }
}

sub mode_pull {
    ftp_connect();
    find_remote(\&pull_file, @targets);
    for my $file (keys %remote_mdtm) {
        if (matches_target($file) && !defined $found{$file} && filter_file($file, $base)) {
            print "< Deleting $file\n";
            remove_local($file, 1);
            remove_remote($file, 0);
        }
    }
}

sub mode_clone {
    mode_pull();
    %found = ();
    find({'wanted' => \&clone_file, 'preprocess' => \&local_filter}, @targets_full);
    for my $file (keys %local_mdtm) {
        if (matches_target($file) && !defined $found{$file} && filter_file($file, $base)) {
            print "< Unreferencing $file\n";
            remove_local($file, 0);
        }
    }
}

sub clone_file {
    my $file = $File::Find::name;
    my $remote;
    if ($file . '/' eq $base) {
        $remote = '';
    } else {
        $remote = substr $file, (length $base), length $file;
    }
    if (!-d $file) {
        my $mdtm = local_mdtm($remote);
        if (!defined $local_mdtm{$remote} || $mdtm != $local_mdtm{$remote}) {
            my $hash = local_hash($remote, 1);
            if (!defined $local_hash{$remote} || $hash ne $local_hash{$remote}) {
                print "< Cleaning up $remote\n";
                remove_local($remote, 1);
            }
        }
        $found{$remote} = 1;
    }
}

sub sim_file {
    my ($file, $full, $is_dir) = @_;
    if (!$is_dir) {
        my $mdtm = remote_mdtm($file);
        if (!defined $remote_mdtm{$file} || $mdtm != $remote_mdtm{$file}) {
            if (!-e $base . $file) {
                print "Added: $file\n";
            } else {
                print "Modified: $file\n";
            }
        }
        $found{$file} = 1;
    }
}

sub pull_file {
    my ($file, $full, $is_dir) = @_;
    if (!$is_dir) {
        my $mdtm = remote_mdtm($file);
        if (!defined $remote_mdtm{$file} || $mdtm != $remote_mdtm{$file}) {
            my $size = $ftp->size($file);
            print "< Pulling $file ($size)\n";
            my $local = $base . $file;
            make_path(dirname($local));
            $ftp->get($file, $local) or error("unable to get $file");
            update_remote($file, $mdtm);
            update_local($file);
        }
        $found{$file} = 1;
    }
}

sub mode_ls {
    ftp_connect();
    if (!@ARGV) {
        @targets = $offset;
    }
    for my $target (@targets) {
        print "$cwd$target:\n";
        find_remote_single(\&ls_file, $target, 1);
    }
}

sub ls_file {
    my ($file, $full, $is_dir) = @_;
    print "$full\n";
}

sub mode_mv {
    ftp_connect();
    if (@targets < 2) {
        error("source and destination required");
    }
    my $destination = pop @targets;
    my $is_dir = $destination =~ s+/$++ || -d $base . $destination;
    if ($is_dir && $destination ne '') {
        $destination .= '/';
    }
    for my $target (@targets) {
        my $result = $destination;
        if ($is_dir) {
            $result .= basename($target);
        }
        my $parent = dirname($result);
        $ftp->mkdir($parent, 1);
        $ftp->rename($target, $result) or error("unable to move $target to $result on the server");
        for my $remote (keys %remote_mdtm) {
            if (file_match($remote, $target)) {
                my $mdtm = $remote_mdtm{$remote};
                remove_remote($remote, 0);
                $remote_mdtm{$result} = $mdtm;
            }
        }
        move($base . $target, $base . $result) or error("unable to move $target to $result");
        for my $local (keys %local_mdtm) {
            if (file_match($local, $target)) {
                my $mdtm = $local_mdtm{$local};
                my $hash = $local_hash{$local};
                remove_local($local, 0);
                $local_mdtm{$result} = $mdtm;
                $local_hash{$result} = $hash;
            }
        }
    }
}

sub mode_rm {
    ftp_connect();
    if (@ARGV < 1) {
        error("target required");
    }
    for my $target (@targets) {
        my $is_dir = $target =~ s+/$++ || -d $base . $target;
        if ($is_dir) {
            $ftp->rmdir($target, 1) or error("unable to remove $target on the server");
        } else {
            $ftp->delete($target) or error("unable to remove $target on the server");
        }
        for my $remote (keys %remote_mdtm) {
            if (file_match($remote, $target)) {
                remove_remote($remote, 1);
            }
        }
        if ($is_dir) {
            remove_tree($base . $target) or error("unable to remove $target");
        } else {
            unlink $base . $target or error("unable to remove $target");
        }
        for my $local (keys %local_mdtm) {
            if (file_match($local, $target)) {
                remove_local($local, 1);
            }
        }
    }
}

sub mode_mkdir {
    ftp_connect();
    for my $target (@targets) {
        $ftp->mkdir($target, 1) or error("unable to mkdir $target on the server");
        make_path($base . $target) or error("unable to mkdir $target");
    }
}

sub mode_rmdir {
    ftp_connect();
    for my $target (@targets) {
        $ftp->rmdir($target) or error("unable to rmdir $target on the server");
        rmdir $base . $target or error("unable to rmdir $target");
    }
}

sub mode_site {
    ftp_connect();
    ftp_cd($offset);
    $ftp->site("@ARGV") or error("site command failed");
}

sub find_remote_single {
    my ($callback, $sub, $no_recurse) = @_;
    my $subdir = $sub =~ m+/$+ || $sub eq '' ? $sub : $sub . '/';
    my @lines = keys %{{ map { $_ => 1 } $ftp->dir($sub), $ftp->dir($subdir . '.*') }};
    for my $line (@lines) {
        chomp $line;
        if ($line =~ /(.).+\s[\d:]+\s(.+?)\/?$/) {
            my $type = $1;
            my $file = $2;
            if (filter_file($file, $base . $sub)) {
                if ($sub =~ m+/$+ || $sub eq '') {
                    $file = $subdir . $file;
                } else {
                    $file = $sub;
                }
                my $is_dir = $type eq 'd';
                &$callback($file, $line, $is_dir);
                if (!$no_recurse && $is_dir) {
                    find_remote_single($callback, $file . '/');
                }
            }
        }
    }
}

sub find_remote {
    my ($callback, @list) = @_;
    for my $sub (@list) {
        find_remote_single($callback, $sub);
    }
}

sub resolve_file {
    my ($file) = @_;
    while ($file =~ s#(^|/)\./##g || $file =~ s#(^|/)\.$##g) {
    }
    while ($file =~ s#[^/]+/\.\./##g || $file =~ s#[^/]+/\.\.$##g) {
    }
    return $file;
}

sub assure_file {
    my ($file) = @_;
    if (!-e $file) {
        open $fh, '>>', $file or error("unable to create $file");
        close $fh;
    }
}

sub help {
    my ($signal) = @_;
    if (!defined $signal) {
        $signal = 1;
    }
    print <<EOT;
Usage: $0 <mode> [arguments]

MODES
    test
        Connect to the server and print the resulting working directory.

    status
        Show files changed since the last push.

    sim
        Show files changed on the server since the last pull.

    pull
        Pull files changed on the server from the server.

    clone
        Pull files changed locally and on the server from the server.

    push
        Push local changes to the server. Fails when a file was also changed on
        the server.

    backup
        Backup changed and new files.

    reset
        Reset backed up files.

    clean
        Clean up backup files.

    ls <directories>
        List directories on the server.

    mv <files> <destination>
        Move files locally and on the server to destination.

    rm <files>
        Remove files locally and on the server recursively.

    mkdir <directories>
        Create directories locally and on the server.

    rmdir <directories>
        Remove empty directories locally and on the server.

    site <command>
        Submit a custom SITE command to the server.

    help
        Show this message and exit.
EOT
    exit $signal;
}
