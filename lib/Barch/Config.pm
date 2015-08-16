package Barch::Config;
use Moo;
use Config::Tiny;

has configfile => (
    is       => 'ro',
    required => 1,
);

sub read {
    my $self = shift;
    my $file = $self->configfile;
    -e $file or die "$file: file not found";

    my $conf = Config::Tiny->read($file);
    $self->check_config($conf);

    return $conf;
}

sub check_config {
    my ( $self, $conf ) = @_;

    # required sections
    my @sections = ('default', 'global', 'snapshots', 'duplicity', 'advanced');
    my $conf_ok  = 0;

    foreach my $section (@sections){
        if ( ! first { $section eq $_ } keys %{$conf} ){
            print "$section section is missing.\nCheck you configuration file\n";
            exit 2;
        }}

    foreach my $section ( keys %{$conf} ) {
        foreach my $parameter ( keys %{ $conf->{$section} } ){
            if(
                $parameter =~ /[\@#\-%&\$*+()]/ ||
                $conf->{$section}{$parameter} =~ /[#\-%&\$*+()]/
            ){
                print "[$section]\n";
                print "\t$parameter = $conf->{$section}{$parameter}\n";
                $conf_ok = 1;
            }}
    }

    print "[WARN] Custom config file $conf->{advanced}{custom} not found\n"
        if( $conf->{advanced}{custom} && !-e "$conf->{advanced}{custom}" );

    $conf_ok or die "Config [ERROR]\n";

    print "Config [OK]\n";
}

1;
