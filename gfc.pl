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
my $gfc_dir;
while (!defined $gfc_dir && $base ne '') {
    $gfc_dir = $base . '/.gfc/';
    if (!-d $gfc_dir) {
        undef $gfc_dir;
        if ($base ne '') {
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
    die 'No gfc directory found, use gfc init first';
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
$ftp->cwd($cwd) or die "Could not change remote working directory to $cwd";

my $local_file = $gfc_dir . 'local';
my %local_mdtm;
my %local_hash;
assure_file($local_file);

my $remote_file = $gfc_dir . 'remote';
my %remote_mdtm;
assure_file($remote_file);

if ($mode eq 'status') {
    load_local();
    mode_status();
} elsif ($mode eq 'pull') {
    load_remote();
    load_local();
    mode_pull();
    save_remote();
    save_local();
} elsif ($mode eq 'push') {
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
        my $hash = $local_hash{$file};
        print $fh "$mdtm $hash $file\n";
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
        print $fh "$mdtm $file\n";
    }
    close $fh;
}

sub filter_file {
    my ($file) = @_;
    return $file ne '.' && $file ne '..' && $file ne '.gfc' && $file ne '.git' && $file !~ /\.(.*)\.sw.$/ && $file !~ /~$/;
}

sub mode_status {
    find({'wanted' => \&status_file, 'preprocess' => \&local_filter}, $base);
}

sub mode_push {
    find({'wanted' => \&push_file, 'preprocess' => \&local_filter}, $base);
}

sub local_filter {
    my(@files) = @_;
    my $dir = $File::Find::dir;
    my @result;
    for my $file (@files) {
        if (filter_file($file)) {
            push @result, $file;
        }
    }
    return @result;
}

sub status_file {
    my $file = $File::Find::name;
    if ($file . '/' eq $base) {
        return;
    }
    my $remote = substr $file, (length $base), length $file;
    my $is_dir = -d $file;
    if (!$is_dir) {
        my $mdtm = (stat $file)[9];
        if ($mdtm != $local_mdtm{$remote}) {
            my $hash = md5_file($file);
            if ($hash ne $local_hash{$remote}) {
                print "Modified: $remote\n";
            }
        }
    }
}

sub push_file {
    my $file = $File::Find::name;
    if ($file . '/' eq $base) {
        return;
    }
    my $remote = substr $file, (length $base), length $file;
    my $is_dir = -d $file;
    if ($is_dir) {
        $ftp->mkdir($remote);
    } else {
        my $mdtm = (stat $file)[9];
        if ($mdtm != $local_mdtm{$remote}) {
            my $hash = md5_file($file);
            if ($hash ne $local_hash{$remote}) {
                print "Pushing $remote\n";
                $ftp->put($file, $remote) or die "Unable to put $remote";
                $local_mdtm{$remote} = $mdtm;
                $local_hash{$remote} = $hash;
                my $mdtm_remote = $ftp->mdtm($remote) or die "Unable to get modification time for $remote";
                $mdtm_remote = int($mdtm_remote);
                $remote_mdtm{$remote} = $mdtm_remote;
            }
        }
    }
}

sub mode_pull {
    find_remote('', \&pull_file);
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
        if ($mdtm != $remote_mdtm{$file}) {
            print "Pulling $file\n";
            $ftp->get($file, $local) or die "Unable to get $file";
            $remote_mdtm{$file} = $mdtm;
            my $mdtm_local = (stat $local)[9];
            my $hash = md5_file($local);
            $local_mdtm{$file} = $mdtm_local;
            $local_hash{$file} = $hash;
        }
    }
}

sub find_remote {
    my ($sub, $callback) = @_;
    my @lines = keys %{{ map { $_ => 1 } $ftp->dir($sub . '*'), $ftp->dir($sub . '.*') }};
    for my $line (@lines) {
        if ($line =~ /(.).+\s(.+?)\/?$/) {
            my $type = $1;
            my $file = $2;
            if (filter_file($file)) {
                $file = $sub . $file;
                &$callback($file, $type eq 'd');
                find_remote($file . '/', $callback);
            }
        }
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
