#!/usr/bin/env perl
#

use strict;
use warnings;


# POE System
use EV;
sub POE::Kernel::ASSERT_DEFAULT { 1; };
use POE qw(
	Wheel::ReadWrite
	Component::Server::eris
);

# TCP Session Master
POE::Component::Server::eris->spawn(
		ListenAddress	=> '127.0.0.1',
		ListenPort		=> 9514,
);

# Syslog-ng Stream Master
POE::Session->create(
		inline_states => {
			_start		=> \&stream_start,
			_stop		=> sub { print "SESSION ", $_[SESSION]->ID, " stopped.\n"; },

			stream_line		=> \&stream_line,
			stream_error	=> \&stream_error,
		},
);

#--------------------------------------------------------------------------#

#--------------------------------------------------------------------------#
# POE Main Loop
POE::Kernel->run();
exit 0;
#--------------------------------------------------------------------------#


#--------------------------------------------------------------------------#
# POE Event Functions
#--------------------------------------------------------------------------#

#--------------------------------------------------------------------------#
sub stream_start {
	my ($kernel, $heap) = @_[KERNEL, HEAP];

	$kernel->alias_set( 'stream' );

	#
	# Initialize the connection to STDIN as a POE::Wheel
	my $stdin = IO::Handle->new_from_fd( \*STDIN, 'r' );
	my $stderr = IO::Handle->new_from_fd( \*STDERR, 'w' );

	$heap->{stream} = POE::Wheel::ReadWrite->new(
		InputHandle		=> $stdin,
		OutputHandle	=> $stderr,
		InputEvent		=> 'stream_line',
		ErrorEvent		=> 'stream_error',
	);
}


#--------------------------------------------------------------------------#
sub stream_line {
	my ($kernel,$msg) = @_[KERNEL,ARG0];

	return unless length $msg;

	$kernel->post( eris_dispatch => dispatch_message => $msg );

}

#--------------------------------------------------------------------------#
sub stream_error {
	my ($kernel) = $_[KERNEL];

	debug("STREAM ERROR!!!!!!!!!!\n");
	$kernel->call( eris_dispatcher => server_shutdown => 'Stream lost' );
}
