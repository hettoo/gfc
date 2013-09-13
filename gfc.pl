#!/usr/bin/perl

use strict;
use warnings;

use Net::FTP;
use Cwd;
use File::Find;
use File::Basename;
use Digest::MD5;

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
        die "gfc dir already present: $gfc_dir";
    }
    $gfc_dir = getcwd();
    $gfc_dir =~ s+/$++;
    $gfc_dir .= '/.gfc/';
    mkdir $gfc_dir or die "Unable to create $gfc_dir";
    exit;
} elsif (!defined $gfc_dir) {
    die "No gfc directory found, use gfc init first\n";
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
open $fh, '<', $config_file or die "Unable to open $config_file";
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

if ($mode eq 'status') {
    load_ignore();
    load_local();
    mode_status();
    exit;
}

my $ftp = Net::FTP->new($config{'host'}) or die "Could not connect: $!";
$ftp->login($config{'user'}, $config{'password'}) or die "Could not login: $!";
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
$ftp->cwd($cwd) or die "Could not change remote working directory to $cwd";
$ftp->binary();

if ($mode eq 'pull') {
    load_ignore();
    load_remote();
    load_local();
    mode_pull();
    save_remote();
    save_local();
} elsif ($mode eq 'push') {
    load_ignore();
    load_local();
    load_remote();
    mode_push();
    save_local();
    save_remote();
} elsif ($mode eq 'help') {
    help(0);
} else {
    help();
}

$ftp->quit();
exit;

sub load_ignore {
    open $fh, '<', $ignore_file or die "Unable to read $ignore_file";
    while (my $line = <$fh>) {
        chomp $line;
        push @ignore, $line;
    }
    close $fh;
}

sub load_local {
    open $fh, '<', $local_file or die "Unable to read $local_file";
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
    open $fh, '>', $local_file or die "Unable to write $local_file";
    while (my ($file, $mdtm) = each %local_mdtm) {
        if (defined $mdtm) {
            my $hash = $local_hash{$file};
            print $fh "$mdtm $hash $file\n";
        }
    }
    close $fh;
}

sub load_remote {
    open $fh, '<', $remote_file or die "Unable to read $remote_file";
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
    open $fh, '>', $remote_file or die "Unable to write $remote_file";
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
            my $mdtm_remote;
            if (defined $remote_mdtm{$file}) {
                $mdtm_remote = $ftp->mdtm($file) or die "Unable to get modification time for $file";
                $mdtm_remote = int($mdtm_remote);
            }
            if (defined $remote_mdtm{$file} && $mdtm_remote != $remote_mdtm{$file}) {
                die "$file has changed on the server, pull first\n";
            }
            $ftp->delete($file);
            undef $remote_mdtm{$file};
            undef $local_mdtm{$file};
            undef $local_hash{$file};
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
    my $is_dir = -d $file;
    if ($is_dir) {
        $ftp->mkdir($remote, 1);
    } else {
        my $mdtm = (stat $file)[9];
        if (!defined $local_mdtm{$remote} || $mdtm != $local_mdtm{$remote}) {
            my $hash = md5_file($file);
            if (!defined $local_hash{$remote} || $hash ne $local_hash{$remote}) {
                print "> Pushing $remote\n";
                my $mdtm_remote;
                if (defined $remote_mdtm{$remote}) {
                    $mdtm_remote = $ftp->mdtm($remote) or die "Unable to get modification time for $remote";
                    $mdtm_remote = int($mdtm_remote);
                }
                if (defined $remote_mdtm{$remote} && $mdtm_remote != $remote_mdtm{$remote}) {
                    die "$remote has changed on the server, pull first\n";
                } else {
                    $ftp->put($file, $remote) or die "Unable to put $remote";
                    $mdtm_remote = $ftp->mdtm($remote) or die "Unable to get modification time for $remote";
                    $mdtm_remote = int($mdtm_remote);
                    $local_mdtm{$remote} = $mdtm;
                    $local_hash{$remote} = $hash;
                    $remote_mdtm{$remote} = $mdtm_remote;
                }
            }
        }
    }
}

sub mode_pull {
    find_remote(\&pull_file, @targets);
    for my $file (keys %remote_mdtm) {
        if (matches_target($file) && !defined $found{$file}) {
            if (defined $local_mdtm{$file}) {
                print "< Deleting $file\n";
                unlink $base . $file;
                undef $local_mdtm{$file};
                undef $local_hash{$file};
            }
            undef $remote_mdtm{$file};
        }
    }
}

sub pull_file {
    my ($file, $is_dir) = @_;
    my $local = $base . $file;
    if ($is_dir) {
        if (!-d $local) {
            mkdir $local or die "Unable to create directory $local";
        }
    } else {
        my $mdtm = $ftp->mdtm($file) or die "Unable to get modification time for $file";
        $mdtm = int($mdtm);
        if (!defined $remote_mdtm{$file} || $mdtm != $remote_mdtm{$file}) {
            print "< Pulling $file\n";
            $ftp->get($file, $local) or die "Unable to get $file";
            $remote_mdtm{$file} = $mdtm;
            my $mdtm_local = (stat $local)[9];
            my $hash = md5_file($local);
            $local_mdtm{$file} = $mdtm_local;
            $local_hash{$file} = $hash;
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
    open my $fh, '<', $file or die "Unable to read $file\n";
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
        open $fh, '>>', $file or die "Unable to create $file";
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
