#!/usr/bin/perl
#
# **** License ****
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License version 2 as
# published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful, but
# WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
# General Public License for more details.
#
# A copy of the GNU General Public License is available as
# `/usr/share/common-licenses/GPL' in the Debian GNU/Linux distribution
# or on the World Wide Web at `http://www.gnu.org/copyleft/gpl.html'.
# You can also obtain it by writing to the Free Software Foundation,
# Free Software Foundation, Inc., 51 Franklin St, Fifth Floor, Boston,
# MA 02110-1301, USA.
#
# This code was originally developed by Vyatta, Inc.
# Portions created by Vyatta are Copyright (C) 2007 Vyatta, Inc.
# All Rights Reserved.
#
# Author: Stephen Hemminger
# Date: September 2008
# Description: Script to setup bonding interfaces
#
# **** End License ****
#

use lib "/opt/vyatta/share/perl5/";
use Vyatta::Interface;
use Getopt::Long;

use strict;
use warnings;

my %modes = (
    "round-robin"           => 0,
    "active-backup"         => 1,
    "xor-hash"              => 2,
    "broadcast"             => 3,
    "802.3ad"               => 4,
    "transmit-load-balance" => 5,
    "adaptive-load-balance" => 6,
);

sub set_mode {
    my ( $intf, $mode ) = @_;
    my $val = $modes{$mode};
    die "Unknown bonding mode $mode\n" unless defined($val);

    open my $fm, '>', "/sys/class/net/$intf/bonding/mode"
      or die "Error: $intf is not a bonding device:$!\n";
    print {$fm} $val, "\n";
    close $fm
      or die "Error: $intf can not set mode $val:$!\n";
}

sub get_slaves {
    my $intf = shift;

    open my $f, '<', "/sys/class/net/$intf/bonding/slaves"
      or die "$intf is not a bonding interface";
    my $slaves = <$f>;
    close $f;
    return unless $slaves;

    chomp $slaves;
    return split( ' ', $slaves );
}

sub add_slave {
    my ( $intf, $slave ) = @_;

    open my $f, '>', "/sys/class/net/$intf/bonding/slaves"
      or die "$intf is not a bonding interface";

    print {$f} "+$slave\n";
    close $f;
}

sub remove_slave {
    my ( $intf, $slave ) = @_;

    open my $f, '>', "/sys/class/net/$intf/bonding/slaves"
      or die "$intf is not a bonding interface";

    print {$f} "-$slave\n";
    close $f;
}

# Go dumpster diving to figure out which ethernet interface (if any)
# gave it's address to be used by all bonding devices.
sub primary_slave {
    my ( $intf, $bond_addr ) = @_;

    open my $p, '<', "/proc/net/bonding/$intf"
      or die "Can't open /proc/net/bonding/$intf : $!";

    my ( $dev, $match );
    while ( my $line = <$p> ) {
        chomp $line;
        if ( $line =~ m/^Slave Interface: (.*)$/ ) {
            $dev = $1;
        }
        elsif ( $line =~ m/^Permanent HW addr: (.*)$/ ) {
            if ( $1 eq $bond_addr ) {
                $match = $dev;
                last;
            }
        }
    }
    close $p;

    return $match;
}

sub if_down {
    my $intf = shift;
    system "ip link set dev $intf down"
      and die "Could not set $intf up ($!)\n";
}

sub if_up {
    my $intf = shift;
    system "ip link set dev $intf up"
      and die "Could not set $intf up ($!)\n";
}

sub change_mode {
    my ( $intf, $mode ) = @_;
    my $interface = new Vyatta::Interface($intf);
    die "$intf is not a valid interface" unless $interface;
    my $primary = primary_slave( $intf, $interface->hw_address() );

    my @slaves = get_slaves($intf);
    foreach my $slave (@slaves) {
        if_down($slave);
        remove_slave( $intf, $slave ) unless ( $primary && $slave eq $primary );
    }
    if ($primary) {
	if_down($primary);
	remove_slave( $intf, $primary );
    }

    my $bond_up = $interface->up();
    if_down($intf) if $bond_up;
    set_mode( $intf, $mode );
    if_up($intf) if $bond_up;

    foreach my $slave ( @slaves ) {
	add_slave( $intf, $slave );
    }
}

sub usage {
    print "Usage: $0 --dev=bondX --mode={mode}\n";
    print "       $0 --dev=bondX --add-port=ethX\n";
    print "       $0 --dev=bondX --remove-port=ethX\n";
    print print "modes := ", join( ',', sort( keys %modes ) ), "\n";

    exit 1;
}

my ( $dev, $mode, $add_port, $rem_port );

GetOptions(
    'dev=s'    => \$dev,
    'mode=s'   => \$mode,
    'add=s'    => \$add_port,
    'remove=s' => \$rem_port,
) or usage();

die "$0: device not specified\n" unless $dev;

change_mode( $dev, $mode )	if $mode;
add_slave( $dev, $add_port )	if $add_port;
remove_slave( $dev, $rem_port ) if $rem_port;
