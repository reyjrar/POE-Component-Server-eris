use strict;
use warnings;
package POE::Component::Server::eris;

use POE qw(
	Component::Server::TCP
);

# ABSTRACT: POE eris message dispatcher

our $VERSION = '0.8';

=head1 SYNOPSIS

POE session for integration with your central logging infrastructure
By itself, this module is useless.  It is designed to take an stream of data
from anything that can generate a POE Event.  Examples for syslog-ng and
rsyslog are included in the examples directory!

    use POE qw(
		Component::Server::TCP
		Component::Server::eris
	);

	# Message Dispatch Service
    my $SESSION = POE::Component::Server::eris->spawn(
			ListenAddress		=> 'localhost',		 	#default
			ListenPort			=> '9514',			 	#default
	);

	# $SESSION = { alias => 'eris_dispatcher', ID => POE::Session->ID };


	# Take Input from a TCP Socket
	my $input_log_session_id = POE::Component::Server::TCP->spawn(

		# An event will post incoming messages to:
		# $poe_kernel->post( eris_dispatch => dispatch_message => $msg );
		# 		 or
		# $poe_kernel->post( $SESSION->{alias} => dispatch_message => $msg );
    	...

	);

	POE::Kernel->run();

=head1 EXPORT

POE::Component::Server::eris does not export any symbols.

=cut

# Precompiled Regular Expressions
my %_PRE = (
	program => qr/\s+\d+:\d+:\d+\s+\S+\s+([^:\s]+)(:|\s)/,
);


=head1 FUNCTIONS

=head2 spawn

Creates the POE::Session for the eris correlator.

Parameters:
	ListenAddress			=> 'localhost', 		#default
	ListenPort				=> '9514',		 		#default

=cut

sub spawn {
	my $type = shift;

	#
	# Param Setup
	my %args = (
		ListenAddress	=> 'localhost',
		ListenPort		=> 9514,
		@_
	);

	# TCP Session Master
	my $tcp_sess_id = POE::Component::Server::TCP->new(
			Alias		=> 'eris_client_server',
			Address		=> $args{ListenAddress},
			Port		=> $args{ListenPort},

			Error				=> \&server_error,
			ClientConnected		=> \&client_connect,
			ClientInput			=> \&client_input,

			ClientDisconnected	=> \&client_term,
			ClientError			=> \&client_term,

			InlineStates		=> {
				client_print		=> \&client_print,
			},
	);

	# Dispatcher Master Session
	my $dispatch_id = POE::Session->create(
		inline_states => {
			_start					=> \&dispatcher_start,
			_stop					=> sub { print "SESSION ", $_[SESSION]->ID, " stopped.\n"; },
			register_client			=> \&register_client,
			subscribe_client		=> \&subscribe_client,
			unsubscribe_client		=> \&unsubscribe_client,
			fullfeed_client			=> \&fullfeed_client,
			dispatch_message		=> \&dispatch_message,
			broadcast				=> \&broadcast,
			hangup_client			=> \&hangup_client,
			server_shutdown			=> \&server_shutdown,
			match_client			=> \&match_client,
			nomatch_client			=> \&nomatch_client,
            regex_client            => \&regex_client,
            noregex_client          => \&noregex_client,
			debug_client			=> \&debug_client,
			nobug_client			=> \&nobug_client,
			debug_message			=> \&debug_message,
		},
	);

	return { alias => 'eris_dispatch' => ID => $dispatch_id };
}

=head2 INTERNAL Subroutines (Events)

=head3 debug

Controls Debugging Output to the controlling terminal

=cut

sub debug {
	my $msg = shift;
	chomp($msg);
	$poe_kernel->post( 'eris_dispatch' => 'debug_message' => $msg );
	print "[debug] $msg\n";
}
#--------------------------------------------------------------------------#

=head3 dispatcher_start

Sets the alias and creates in-memory storages

=cut

sub dispatcher_start {
	my ($kernel, $heap) = @_[KERNEL, HEAP];

	$kernel->alias_set( 'eris_dispatch' );

	$heap->{subscribers} = { };
	$heap->{full} = { };
	$heap->{debug} = { };
	$heap->{match} = { };
}
#--------------------------------------------------------------------------#

=head3 dispatch_message

Based on clients connected and their feed settings, distribute this message

=cut

sub dispatch_message {
	my ($kernel,$heap,$msg) = @_[KERNEL,HEAP,ARG0];


    my %recv = ();

	foreach my $sid ( keys %{ $heap->{full} } ) {
		$kernel->post( $sid => 'client_print' => $msg );
        $recv{$sid} = 1;
	}

	# Program based subscriptions
	if( my ($program) = map { lc } ($msg =~ /$_PRE{program}/) ) {
		# remove the sub process and PID from the program
		$program =~ s/\(.*//g;
		$program =~ s/\[.*//g;

		debug("DISPATCHING MESSAGE [$program]");

		if( exists $heap->{subscribers}{$program} ) {
			foreach my $sid (keys %{ $heap->{subscribers}{$program} }) {
                next if exists $recv{$sid};
				$kernel->post( $sid => client_print => $msg );
                $recv{$sid} = 1;
			}
		}
		else {
			debug("Message discarded, no listeners.");
		}
	}

	# Match based subscriptions
	if( keys %{ $heap->{match} } ) {
		foreach my $word (keys %{ $heap->{match} } ) {
			if( index( $msg, $word ) != -1 ) {
				foreach my $sid ( keys %{ $heap->{match}{$word} } ) {
                    next if exists $recv{$sid};
					$kernel->post( $sid => client_print => $msg );
                    $recv{$sid} = 1;
				}
			}
		}
	}

	# Regex based subscriptions
	if( keys %{ $heap->{regex} } ) {
		foreach my $re (keys %{ $heap->{regex} } ) {
			if( $msg =~ /$re/ ) {
				foreach my $sid ( keys %{ $heap->{regex}{$re} } ) {
                    next if $recv{$sid};
					$kernel->post( $sid => client_print => $msg );
                    $recv{$sid} = 1;
				}
			}
		}
	}
    debug( "Dispatch message to " . scalar(keys %recv) . " clients.");
}

#--------------------------------------------------------------------------#

=head3 server_error

Handles errors related to the PoCo::TCP::Server

=cut

sub server_error {
	my ($syscall_name, $err_num, $err_str) = @_[ARG0..ARG2];
	debug( "SERVER ERROR: $syscall_name, $err_num, $err_str" );

	if( $err_num == 98 ) {
		# Address already in use, bail
		$poe_kernel->stop();
	}
}
#--------------------------------------------------------------------------#

=head3 register_client

Client Registration for the dispatcher

=cut

sub register_client {
	my ($kernel,$heap,$sid) = @_[KERNEL,HEAP,ARG0];

	$heap->{clients}{$sid} = 1;
}
#--------------------------------------------------------------------------#

=head3 debug_client

Enables debugging for the client requesting it

=cut

sub debug_client {
	my ($kernel,$heap,$sid) = @_[KERNEL,HEAP,ARG0];

	if( exists $heap->{full}{$sid} ) {  return;  }

	$heap->{debug}{$sid} = 1;
	$kernel->post( $sid => 'client_print' => 'Debugging enabled.' );
}
#--------------------------------------------------------------------------#

=head3 nobug_client

Disables debugging for a particular client

=cut

sub nobug_client {
	my ($kernel,$heap,$sid) = @_[KERNEL,HEAP,ARG0];

	delete $heap->{debug}{$sid}
		if exists $heap->{debug}{$sid};
	$kernel->post( $sid => 'client_print' => 'Debugging disabled.' );
}
#--------------------------------------------------------------------------#

=head3 fullfeed_client

Adds requesting client to the list of full feed clients

=cut

sub fullfeed_client {
	my ($kernel,$heap,$sid) = @_[KERNEL,HEAP,ARG0];

	# Remove from normal subscribers.
	foreach my $prog (keys %{ $heap->{subscribers} }) {
		delete $heap->{subscribers}{$prog}{$sid}
			if exists $heap->{subscribers}{$prog}{$sid};
	}

	# Remove from matches
	foreach my $word (keys %{ $heap->{match} }) {
		delete $heap->{match}{$word}{$sid}
			if exists $heap->{match}{$word}{$sid};
	}

    # Remove Regex Subscriptions
    $kernel->yield( noregex_client => $sid );

	# Turn off DEBUG
	if( exists $heap->{debug}{$sid} ) {
		delete $heap->{debug}{$sid};
	}

	# Add to fullfeed:
	$heap->{full}{$sid} = 1;

	$kernel->post( $sid => 'client_print' => 'Full feed enabled, all other functions disabled.');
}
#--------------------------------------------------------------------------#

=head3 subscribe_client

Handle program name subscription

=cut

sub subscribe_client {
	my ($kernel,$heap,$sid,$argstr) = @_[KERNEL,HEAP,ARG0,ARG1];

	if( exists $heap->{full}{$sid} ) {  return;  }

	my @progs = map { lc } split /[\s,]+/, $argstr;
	foreach my $prog (@progs) {
		$heap->{subscribers}{$prog}{$sid} = 1;
	}

	$kernel->post( $sid => 'client_print' => 'Subscribed to : ' . join(', ', @progs ) );
}
#--------------------------------------------------------------------------#

=head3 unsubscribe_client

Handle unsubscribe requests from clients

=cut

sub unsubscribe_client {
	my ($kernel,$heap,$sid,$argstr) = @_[KERNEL,HEAP,ARG0,ARG1];

	my @progs = map { lc } split /[\s,]+/, $argstr;
	foreach my $prog (@progs) {
		delete $heap->{subscribers}{$prog}{$sid};
	}

	$kernel->post( $sid => 'client_print' => 'Subscription removed for : ' . join(', ', @progs ) );
}
#--------------------------------------------------------------------------#

=head3 match_client

Handle requests for string matching from clients

=cut

sub match_client {
	my ($kernel,$heap,$sid,$argstr) = @_[KERNEL,HEAP,ARG0,ARG1];

	if( exists $heap->{full}{$sid} ) {  return;  }

	my @words = map { lc } split /[\s,]+/, $argstr;
	foreach my $word (@words) {
		$heap->{match}{$word}{$sid} = 1;
	}

	$kernel->post( $sid => 'client_print' => 'Receiving messages matching : ' . join(', ', @words ) );
}
#--------------------------------------------------------------------------#


=head3 nomatch_client

Remove a match based feed from a client

=cut

sub nomatch_client {
	my ($kernel,$heap,$sid,$argstr) = @_[KERNEL,HEAP,ARG0,ARG1];

	my @words = map { lc } split /[\s,]+/, $argstr;
	foreach my $word (@words) {
		delete $heap->{match}{$word}{$sid};
		# Remove the word from searching if this was the last client
		delete $heap->{match}{$word} unless keys %{ $heap->{match}{$word} };
	}


	$kernel->post( $sid => 'client_print' => 'No longer receving messages matching : ' . join(', ', @words ) );
}
#--------------------------------------------------------------------------#

=head3 regex_client

Handle requests for string regexes from clients

=cut

sub regex_client {
	my ($kernel,$heap,$sid,$argstr) = @_[KERNEL,HEAP,ARG0,ARG1];

	if( exists $heap->{full}{$sid} ) {  return;  }

    my $regex = undef;
    eval {
        $regex = qr{$argstr};
    };

    if( defined $regex ) {
        $heap->{regex}{$regex}{$sid} = 1;
	    $kernel->post( $sid => 'client_print' => "Receiving messages matching regex : $argstr" );
    }
    else {
	    $kernel->post( $sid => 'client_print' => "Invalid regular expression '$argstr', see perldoc perlre" );
    }
}
#--------------------------------------------------------------------------#


=head3 noregex_client

Remove a match based feed from a client

=cut

sub noregex_client {
	my ($kernel,$heap,$sid,$argstr) = @_[KERNEL,HEAP,ARG0,ARG1];

    foreach my $re ( keys %{ $heap->{regex} }) {
		delete $heap->{regex}{$re}{$sid}
		    if exists $heap->{regex}{$re}{$sid};

        if( scalar(keys %{ $heap->{regex}{$re} }) == 0 ) {
            delete $heap->{regex}{$re};
            debug( "REGEX was removed from regex hash.");
        }
	}

	$kernel->post( $sid => 'client_print' => 'No longer receving regex-based matches' );
}
#--------------------------------------------------------------------------#


=head3 hangup_client

This handles cleaning up from a client disconnect

=cut

sub hangup_client {
	my ($kernel,$heap,$sid) = @_[KERNEL,HEAP,ARG0];

	delete $heap->{clients}{$sid};

	foreach my $p ( keys %{ $heap->{subscribers} } ) {
		delete $heap->{subscribers}{$p}{$sid}
			if exists $heap->{subscribers}{$p}{$sid};
	}

	foreach my $word ( keys %{ $heap->{match} } ) {
		delete $heap->{match}{$word}{$sid}
			if exists $heap->{match}{$word}{$sid};
		# Remove the word from searching if this was the last client
		delete $heap->{match}{$word} unless keys %{ $heap->{match}{$word} };
	}


	if( exists $heap->{debug}{$sid} ) {
		delete $heap->{debug}{$sid};
	}

	if( exists $heap->{full}{$sid} ) {
		delete $heap->{full}{$sid};
	}

	debug("Client Termination Posted: $sid\n");

}
#--------------------------------------------------------------------------#

=head3 server_shutdown

Announce server shutdown, shut off PoCo::Server::TCP Session

=cut

sub server_shutdown {
	my ($kernel,$heap,$msg) = @_[KERNEL,HEAP,ARG0];

	$kernel->call( eris_dispatch => 'broadcast' => 'SERVER DISCONNECTING: ' . $msg );
	$kernel->call( eris_client_server => 'shutdown' );
	exit;
}
#--------------------------------------------------------------------------#

=head3 client_connect

PoCo::Server::TCP Client Establishment Code

=cut

sub client_connect {
	my ($kernel,$heap,$ses) = @_[KERNEL,HEAP,SESSION];

	my $KID = $kernel->ID();
	my $CID = $heap->{client}->ID;
	my $SID = $ses->ID;

	$kernel->post( eris_dispatch => register_client => $SID );

	$heap->{clients}{ $SID } = $heap->{client};
	#
	# Say hello to the client.
	$heap->{client}->put( "EHLO Streamer (KERNEL: $KID:$SID)" );
}

#--------------------------------------------------------------------------#

=head3 client_print

PoCo::Server::TCP Write to Client

=cut

sub client_print {
	my ($kernel,$heap,$ses,$mesg) = @_[KERNEL,HEAP,SESSION,ARG0];

	$heap->{clients}{$ses->ID}->put($mesg);
}
#--------------------------------------------------------------------------#

=head3 broadcast

PoCo::Server::TCP Broadcast Messages

=cut

sub broadcast {
	my ($kernel,$heap,$msg) = @_[KERNEL,HEAP,ARG0];

	foreach my $sid (keys %{ $heap->{clients} }) {
		$kernel->post( $sid => 'client_print' => $msg );
	}
}
#--------------------------------------------------------------------------#

=head3 debug_message

Send debug message to DEBUG clients

=cut

sub debug_message {
	my ($kernel,$heap,$msg) = @_[KERNEL,HEAP,ARG0];


	foreach my $sid (keys %{ $heap->{debug} }) {
		$kernel->post( $sid => client_print => '[debug] ' . $msg );
	}
}
#--------------------------------------------------------------------------#

=head3 client_input

Parse the Client Input for eris::dispatcher commands and enact those commands

=cut

sub client_input {
	my ($kernel,$heap,$ses,$msg) = @_[KERNEL,HEAP,SESSION,ARG0];
	my $sid = $ses->ID;

	if( !exists $heap->{dispatch}{$sid} ) {
		$heap->{dispatch}{$sid} = {
			fullfeed		=> {
				re			=> qr/^(fullfeed)/,
				callback	=> sub {
					$kernel->post( eris_dispatch => fullfeed_client => $sid );
				},
			},
			subscribe		=> {
				re			=> qr/^sub(?:scribe)? (.*)/,
				callback	=> sub {
					$kernel->post( eris_dispatch => subscribe_client => $sid, shift );
				},
			},
			unsubscribe 	=> {
				re			=> qr/^unsub(?:scribe)? (.*)/,
				callback	=> sub {
					$kernel->post( eris_dispatch => unsubscribe_client => $sid, shift );
				},
			},
			match 	=> {
				re			=> qr/^match (.*)/i,
				callback	=> sub {
					$kernel->post( eris_dispatch => match_client => $sid, shift );
				},
			},
			nomatch 	=> {
				re			=> qr/^nomatch (.*)/i,
				callback	=> sub {
					$kernel->post( eris_dispatch => nomatch_client => $sid, shift );
				},
			},
			debug 	=> {
				re			=> qr/^(debug)/i,
				callback	=> sub {
					$kernel->post( eris_dispatch => debug_client => $sid, shift );
				},
			},
			nobug 	=> {
				re			=> qr/^(no(de)?bug)/i,
				callback	=> sub {
					$kernel->post( eris_dispatch => nobug_client => $sid, shift );
				},
			},
            regex => {
				re			=> qr/^re(gex)? (.*)/i,
				callback	=> sub {
					$kernel->post( eris_dispatch => regex_client => $sid, shift );
				},
            },
			noregex 	=> {
				re			=> qr/^nore(gex)? (.*)/i,
				callback	=> sub {
					$kernel->post( eris_dispatch => noregex_client => $sid );
				},
			},
			#quit			=> {
			#	re			=> qr/(exit)|q(uit)?/,
			#	callback	=> sub {
			#			$kernel->post( $sid => 'client_print' => 'Terminating connection on your request.');
			#			$kernel->post( $sid => 'shutdown' );
			#	},
			#},
			#status			=> {
			#	re			=> qr/^status/,
			#	callback	=> sub {
			#		my $cnt = scalar( keys %{ $heap->{clients} } );
			#		my $subcnt = scalar( keys %{ $heap->{subscribers} });
			#		my $msg = "Currently $cnt connections, $subcnt subscribed.";
			#		$kernel->post( $sid, 'client_print', $msg );
			#	},
			#},
		};
	}

	#
	# Check for messages:
	my $handled = 0;
	my $dispatch = $heap->{dispatch}{$sid};
	foreach my $evt ( keys %{ $dispatch } ) {
		if( my($args) = ($msg =~ /$dispatch->{$evt}{re}/)) {
			$handled = 1;
			$dispatch->{$evt}{callback}->($args);
			last;
		}
	}

	if( !$handled ) {
		$kernel->post( $sid => client_print => 'UNKNOWN COMMAND, Ignored.' );
	}
}
#--------------------------------------------------------------------------#

=head3 client_term

PoCo::Server::TCP Client Termination

=cut

sub client_term {
	my ($kernel,$heap,$ses) = @_[KERNEL,HEAP,SESSION];
	my $sid = $ses->ID;

	delete $heap->{dispatch}{$sid};
	$kernel->post( eris_dispatch => hangup_client =>  $sid );

	debug("SERVER, client $sid disconnected.\n");
}


#--------------------------------------------------------------------------#

=head1 AUTHOR

Brad Lhotsky, C<< <brad.lhotsky at gmail.com> >>

=head1 BUGS

Please report any bugs or feature requests to
C<bug-poe-component-server-eris at rt.cpan.org>, or through the web interface at
L<http://rt.cpan.org/NoAuth/ReportBug.html?Queue=POE-Component-Server-eris>.
I will be notified, and then you'll automatically be notified of progress on
your bug as I make changes.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

    perldoc POE::Component::Server::eris

You can also look for information at:

=over 4

=item * Github

L<https://github.com/reyjrar/POE-Component-Server-eris>

=item * AnnoCPAN: Annotated CPAN documentation

L<http://annocpan.org/dist/POE-Component-Server-eris>

=item * CPAN Ratings

L<http://cpanratings.perl.org/d/POE-Component-Server-eris>

=item * RT: CPAN's request tracker

L<http://rt.cpan.org/NoAuth/Bugs.html?Dist=POE-Component-Server-eris>

=item * Search CPAN

L<http://search.cpan.org/dist/POE-Component-Server-eris>

=back

=head1 ACKNOWLEDGEMENTS

=head1 COPYRIGHT & LICENSE

Copyright 2007 Brad Lhotsky, all rights reserved.

This program is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

=cut

1;
