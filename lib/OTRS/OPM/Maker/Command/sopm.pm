package OTRS::OPM::Maker::Command::sopm;

use strict;
use warnings;

# ABSTRACT: Build .sopm file based on metadata

use File::Find::Rule;
use File::Basename;
use File::Spec;
use IO::File;
use JSON;
use Path::Class ();
use XML::LibXML;
use XML::LibXML::PrettyPrint;

use OTRS::OPM::Maker -command;

our $VERSION = 1.03;

sub abstract {
    return "build sopm file based on metadata";
}

sub usage_desc {
    return "opmbuild sopm [--config <json_file>] <path_to_module>";
}

sub opt_spec {
    return (
        [ 'config=s', 'JSON file that provides all the metadata' ],
    );
}

sub validate_args {
    my ($self, $opt, $args) = @_;

    if ( !$opt->{config} ) {
        my @json_files = File::Find::Rule->file->name( '*.json' )->in( $args->[0] || '.' );

        @json_files > 1 ?
            $self->usage_error( 'found more than one json file, please specify the config file to use' ) :
            do{ $opt->{config} = $json_files[0] };
    }
    
    my $config = Path::Class::File->new( $opt->{config} );
    my $json = JSON->new->relaxed;
    my $json_text = $config->slurp;
    $self->usage_error( 'config file has to be in JSON format: ' . $@ ) if ! eval{ $json->decode( $json_text ); 1; };
}

sub execute {
    my ($self, $opt, $args) = @_;
    
    my $config    = Path::Class::File->new( $opt->{config} );
    my $json_text = $config->slurp;
    my $object    = JSON->new->relaxed;
    my $json      = $object->decode( $json_text );
    my $name      = $json->{name};

    chdir $args->[0] if $args->[0];

    # check needed info
    for my $needed (qw(name version framework)) {
        if ( !$json->{$needed} ) {
            print STDERR "Need $needed in config file";
            exit 1;
        }
    }
    
    my @xml_parts;

    {
        for my $framework ( @{ $json->{framework} } ) {
            push @xml_parts, "    <Framework>$framework</Framework>";
        }
    }

    if ( $json->{requires} ) {
        {
            for my $name ( sort keys %{ $json->{requires}->{package} } ) {
                push @xml_parts, sprintf '    <PackageRequired Version="%s">%s</PackageRequired>', $json->{requires}->{package}, $name;
            }
        }
        
        {
            for my $name ( sort keys %{ $json->{requires}->{module} } ) {
                push @xml_parts, sprintf '    <ModuleRequired Version="%s">%s</ModuleRequired>', $json->{requires}->{module}, $name;
            }
        }
    }

    push @xml_parts, sprintf "    <Vendor>%s</Vendor>", $json->{vendor}->{name} || '';
    push @xml_parts, sprintf "    <URL>%s</URL>", $json->{vendor}->{url} || '';

    if ( $json->{description} ) {
        for my $lang ( sort keys %{ $json->{description} } ) {
            push @xml_parts, sprintf '    <Description Lang="%s">%s</Description>', $lang, $json->{description}->{$lang};
        }
    }

    if ( $json->{license} ) {
        push @xml_parts, sprintf '    <License>%s</License>', $json->{license};
    }

    {
        my @files = File::Find::Rule->file->in( '.' );

        # remove "hidden" files from list;
        @files = grep{ 
            ( substr( $_, 0, 1 ) ne '.' ) &&
            $_ !~ m{[\\/]\.} 
        }sort @files;

        push @xml_parts, 
            sprintf "    <Filelist>\n%s\n    </Filelist>",
                join "\n", map{ my $permission = $_ =~ /^bin/ ? 755 : 644; qq~        <File Permission="$permission" Location="$_" />~ }@files;
    }

    my %actions = (
        Install   => 'post',
        Uninstall => 'pre',
        Upgrade   => 'post',
    );

    my %subaction_code = (
        TableCreate => \&_TableCreate,
        Insert      => \&_Insert,
        TableDrop   => \&_TableDrop,
    );

    ACTION:
    for my $action ( @{ $json->{database} || [] } ) {
        next ACTION if !$actions{ $action->{type} };

        my $action_type = $action->{type};
        my $order       = $actions{ $action->{type} };

        my @actions;

        SUBACTION:
        for my $subaction ( @{ $action->{actions} || [] } ) {
            my $type    = $subaction->{type};

            next SUBACTION if !$subaction_code{$type};
            push @actions, $subaction_code{$type}->($subaction);
        }

        push @xml_parts,
            sprintf qq~    <Database$action_type Type="$order">
%s
    </Database$action_type>~, join "\n", @actions;
    }

    for my $code ( @{ $json->{code} || [] } ) {
        $code->{type} = 'Code' . $code->{type};
        push @xml_parts, _CodeTemplate( $code->{type}, $code->{version}, $code->{function} || $code->{type} );
    }
    
    my $xml = sprintf qq~<?xml version="1.0" encoding="utf-8" ?>
<otrs_package version="1.0">
    <CVS>\$Id: %s.sopm,v 1.1.1.1 2011/04/15 07:49:58 rb Exp \$</CVS>
    <Name>%s</Name>
    <Version>%s</Version>
%s
</otrs_package>
~, 
    $name,
    $name,
    $json->{version},
    join( "\n", @xml_parts );

    my $fh = IO::File->new( $name . '.sopm', 'w' );
    $fh->print( $xml );
    $fh->close;
}

sub _CodeTemplate {
    my ($type, $version, $function) = @_;

    $version = $version ? ' Version="' . $version . '"' : '';

    return qq~    <$type Type="post"$version><![CDATA[
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

sub _Insert {
    my ($action) = @_;


    my $table   = $action->{name};
    my $version = $action->{version};

    my $version_string = $version ? ' Version="' . $version . '"' : '';

    my $string = '        <Insert Table="' . $table . '"' . $version_string . ">\n";

    COLUMN:
    for my $column ( @{ $action->{columns} || [] } ) {
        $string .= sprintf '            <Data Key="%s"%s>%s</Data>' . "\n",
            $column->{name},
            ( $column->{type} ? ' Type="' . $column->{type} . '"' : "" ),
            $column->{value};
    }

    $string .= '        </Insert>';

    return $string; 
}

sub _TableDrop {
    my ($action) = @_;

    my $table = $action->{name};

    return '        <TableDrop Name="' . $table . '" />' . "\n";
}

sub _TableCreate {
    my ($action) = @_;

    my $table   = $action->{name};
    my $version = $action->{version};

    my $version_string = $version ? ' Version="' . $version . '"' : '';

    my $string = '        <TableCreate Name="' . $table . '"' . $version_string . ">\n";

    COLUMN:
    for my $column ( @{ $action->{columns} || [] } ) {
        $string .= sprintf '            <Column Name="%s" Required="%s" Type="%s"%s%s%s />' . "\n",
            $column->{name},
            $column->{required},
            $column->{type},
            ( $column->{size} ? ' Size="' . $column->{size} . '"' : "" ),
            ( $column->{auto_increment} ? ' AutoIncrement="true"' : "" ),
            ( $column->{primary_key} ? ' PrimaryKey="true"' : "" ),
    }

    KEY:
    for my $key ( @{ $action->{keys} || [] } ) {
        my $table = $key->{name};
        $string .= '            <ForeignKey ForeignTable="' . $table . '">' . "\n";

        for my $reference ( @{ $key->{references} || [] } ) {
            my $local   = $reference->{local};
            my $foreign = $reference->{foreign};
            $string .= '                <Reference Local="' . $local . '" Foreign="' . $foreign . '" />' . "\n";
        }

        $string .= '            </ForeignKey>' . "\n";
    }

    $string .= '        </TableCreate>';

    return $string;
}

1;

=head1 CONFIGURATION

You can configure this command with a JSON file:

=cut