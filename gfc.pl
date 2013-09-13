#!/usr/bin/perl

use strict;
use warnings;

use Net::FTP;
use Cwd;
use File::Find;
use File::Basename;
use Digest::MD5;

my $ftp;

my $local_changed = 0;
my $remote_changed = 0;

my $mode = shift @ARGV;
if (!defined $mode) {
    help();
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

if ($mode eq 'status') {
    load_ignore();
    load_local();
    mode_status();
    exit;
}

if ($mode eq 'pull') {
    load_ignore();
    load_remote();
    load_local();
    mode_pull();
} elsif ($mode eq 'push') {
    load_ignore();
    load_local();
    load_remote();
    mode_push();
} elsif ($mode eq 'help') {
    help(0);
} else {
    help();
}

quit();

sub ftp_connect {
    if (defined $ftp) {
        return;
    }
    $ftp = Net::FTP->new($config{'host'}) or error("could not connect: $!");
    $ftp->login($config{'user'}, $config{'password'}) or error("could not login: $!");
    my $cwd = $ftp->pwd();
    if ($cwd !~ m+/$+) {
        $cwd .= '/';
    }
    if (!defined $config{'dir'}) {
        $config{'dir'} = '/';
    }
    if ($config{'dir'} !~ m+/$+) {
        $config{'dir'} .= '/';
    }
    $cwd .= $config{'dir'};
    $ftp->mkdir($cwd, 1);
    $ftp->cwd($cwd) or error("could not change remote working directory to $cwd");
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
        push @ignore, $line;
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

sub file_match {
    my ($file, $pattern) = @_;
    $pattern =~ s+/$++;
    if (length $file < length $pattern) {
        return 0;
    }
    if ($file eq $pattern) {
        return 1;
    }
    my $parent = dirname($file);
    if ($parent eq '.') {
        $parent = '';
    }
    return file_match($parent, $pattern);
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
    if ($file ne '.' && $file ne '..' && $file ne '.gfc' && $file ne '.git' && $file !~ /\.(.*)\.sw.$/ && $file !~ /~$/) {
        my $full_file = $dir . $file;
        for my $ignore (@ignore) {
            if (file_match($full_file, $base . $ignore)) {
                return 0;
            }
        }
        return 1;
    }
    return 0;
}

sub mode_status {
    find({'wanted' => \&status_file, 'preprocess' => \&local_filter}, @targets_full);
    for my $file (keys %local_mdtm) {
        if (!defined $found{$file}) {
            print "Deleted: $file\n";
        }
    }
}

sub mode_push {
    find({'wanted' => \&push_file, 'preprocess' => \&local_filter}, @targets_full);
    for my $file (keys %local_mdtm) {
        if (matches_target($file) && !defined $found{$file}) {
            print "> Deleting $file\n";
            ftp_connect();
            my $mdtm_remote;
            if (defined $remote_mdtm{$file}) {
                $mdtm_remote = $ftp->mdtm($file) or error("unable to get modification time for $file");
                $mdtm_remote = int($mdtm_remote);
            }
            if (defined $remote_mdtm{$file} && $mdtm_remote != $remote_mdtm{$file}) {
                error("$file has changed on the server, pull first");
            }
            $ftp->delete($file);
            undef $remote_mdtm{$file};
            $remote_changed = 1;
            undef $local_mdtm{$file};
            undef $local_hash{$file};
            $local_changed = 1;
        }
    }
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
    my $is_dir = -d $file;
    if (!$is_dir) {
        my $mdtm = (stat $file)[9];
        if (!defined $local_mdtm{$remote} || $mdtm != $local_mdtm{$remote}) {
            my $hash = md5_file($file);
            if (!defined $local_hash{$remote}) {
                print "New: $remote\n";
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
        my $mdtm = (stat $file)[9];
        if (!defined $local_mdtm{$remote} || $mdtm != $local_mdtm{$remote}) {
            my $hash = md5_file($file);
            if (!defined $local_hash{$remote} || $hash ne $local_hash{$remote}) {
                print "> Pushing $remote\n";
                ftp_connect();
                my $dir = dirname($remote);
                if (!$pushed_dir{$dir}) {
                    $ftp->mkdir($dir, 1);
                    $pushed_dir{$dir} = 1;
                }
                my $mdtm_remote;
                if (defined $remote_mdtm{$remote}) {
                    $mdtm_remote = $ftp->mdtm($remote) or error("unable to get modification time for $remote");
                    $mdtm_remote = int($mdtm_remote);
                }
                if (defined $remote_mdtm{$remote} && $mdtm_remote != $remote_mdtm{$remote}) {
                    error("$remote has changed on the server, pull first");
                } else {
                    $ftp->put($file, $remote) or error("unable to put $remote");
                    $mdtm_remote = $ftp->mdtm($remote) or error("unable to get modification time for $remote");
                    $mdtm_remote = int($mdtm_remote);
                    $local_mdtm{$remote} = $mdtm;
                    $local_hash{$remote} = $hash;
                    $local_changed = 1;
                    $remote_mdtm{$remote} = $mdtm_remote;
                    $remote_changed = 1;
                }
            }
        }
    }
}

sub mode_pull {
    ftp_connect();
    find_remote(\&pull_file, @targets);
    for my $file (keys %remote_mdtm) {
        if (matches_target($file) && !defined $found{$file}) {
            if (defined $local_mdtm{$file}) {
                print "< Deleting $file\n";
                unlink $base . $file;
                undef $local_mdtm{$file};
                undef $local_hash{$file};
                $local_changed = 1;
            }
            undef $remote_mdtm{$file};
            $remote_changed = 1;
        }
    }
}

sub pull_file {
    my ($file, $is_dir) = @_;
    my $local = $base . $file;
    if ($is_dir) {
        if (!-d $local) {
            mkdir $local or error("unable to create directory $local");
        }
    } else {
        my $mdtm = $ftp->mdtm($file) or error("unable to get modification time for $file");
        $mdtm = int($mdtm);
        if (!defined $remote_mdtm{$file} || $mdtm != $remote_mdtm{$file}) {
            print "< Pulling $file\n";
            $ftp->get($file, $local) or error("unable to get $file");
            $remote_mdtm{$file} = $mdtm;
            $remote_changed = 1;
            my $mdtm_local = (stat $local)[9];
            my $hash = md5_file($local);
            $local_mdtm{$file} = $mdtm_local;
            $local_hash{$file} = $hash;
            $local_changed = 1;
        }
        $found{$file} = 1;
    }
}

sub find_remote_single {
    my ($callback, $sub) = @_;
    my $subdir = $sub =~ m+/$+ || $sub eq '' ? $sub : $sub . '/';
    my @lines = keys %{{ map { $_ => 1 } $ftp->dir($sub), $ftp->dir($subdir . '.*') }};
    for my $line (@lines) {
        if ($line =~ /(.).+\s(.+?)\/?$/) {
            my $type = $1;
            my $file = $2;
            if (filter_file($file, $base . $sub)) {
                if ($sub =~ m+/$+ || $sub eq '') {
                    $file = $subdir . $file;
                } else {
                    $file = $sub;
                }
                my $is_dir = $type eq 'd';
                &$callback($file, $is_dir);
                if ($is_dir) {
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

sub md5_file {
    my ($file) = @_;
    my $ctx = Digest::MD5->new;
    open my $fh, '<', $file or error("unable to read $file");
    $ctx->addfile($fh);
    close $fh;
    return $ctx->hexdigest;
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
    print "Usage: $0 <mode> [arguments]\n";
    exit $signal;
}
