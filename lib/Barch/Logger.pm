package Barch::Logger;
use Moo;
use Sys::Syslog;

# FIXME: convert to AnyEvent::Log

has debug => (
    is       => 'ro',
    required => 1,
);

has log_facility => (
    is       => 'ro',
    required => 1,
);

has verbose => (
    is       => 'ro',
    required => 1,
);

# Initialize logging
sub log {
    my( $self, $msg, $ident, $priority ) = @_;
    $msg or return;

    # defaults
    $priority = $priority || "info";
    $ident    = $ident || 'Main';
    $ident    = "Barch-$ident";

    $priority eq 'debug' && $self->debug
        or return;

    $msg = "[$ident] [" . uc($priority) . "] $msg";

    # start log
    openlog $ident, "pid,cons", $self->logfacility;

    # write to log
    syslog( $priority, $msg );
    print "$msg\n" if $self->verbose;

    closelog();
}

1;
