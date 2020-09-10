package OTRS::OPM::Maker::Utils::OTRS3;

# ABSTRACT: Provide helper functions for OTRS <= 3

use strict;
use warnings;

sub packagesetup {
    my ($class, $type, $version, $function, $runtype) = @_;

    $version = $version ? ' Version="' . $version . '"' : '';

    $runtype //= 'post';

    return qq~    <$type Type="$runtype"$version><![CDATA[
        # define function name
        my \$FunctionName = '$function';

        # create the package name
        my \$CodeModule = 'var::packagesetup::' . \$Param{Structure}->{Name}->{Content};

        # load the module
        if ( \$Self->{MainObject}->Require(\$CodeModule) ) {

            # create new instance
            my \$CodeObject = \$CodeModule->new( %{\$Self} );

            if (\$CodeObject) {

                # start methode
                if ( !\$CodeObject->\$FunctionName(%{\$Self}) ) {
                    \$Self->{LogObject}->Log(
                        Priority => 'error',
                        Message  => "Could not call method \$FunctionName() on \$CodeModule.pm."
                    );
                }
            }

            # error handling
            else {
                \$Self->{LogObject}->Log(
                    Priority => 'error',
                    Message  => "Could not call method new() on \$CodeModule.pm."
                );
            }
        }

    ]]></$type>~;
}

sub filecheck {
    return 1;
}

1;

=head1 METHODS

=head2 packagesetup

=head2 filecheck

=cut
