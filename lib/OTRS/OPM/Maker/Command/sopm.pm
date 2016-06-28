package OTRS::OPM::Maker::Command::sopm;

use strict;
use warnings;

# ABSTRACT: Build .sopm file based on metadata

use Carp;
use File::Find::Rule;
use File::Basename;
use File::Spec;
use IO::File;
use JSON;
use List::Util qw(first);
use Path::Class ();
use XML::LibXML;
use XML::LibXML::PrettyPrint;

use OTRS::OPM::Maker -command;
use OTRS::OPM::Maker::Utils::OTRS3;
use OTRS::OPM::Maker::Utils::OTRS4;

our $VERSION = 1.34;

sub abstract {
    return "build sopm file based on metadata";
}

sub usage_desc {
    return "opmbuild sopm [--config <json_file>] [--cvs] <path_to_module>";
}

sub opt_spec {
    return (
        [ 'config=s', 'JSON file that provides all the metadata' ],
        [ 'cvs'     , 'Add CVS tag to .sopm' ],
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
    
    if ( !$opt->{config} ) {
        $self->usage_error( 'Please specify the config file to use' );
    }
    
    my $config = Path::Class::File->new( $opt->{config} );
    my $json = JSON->new->relaxed;
    my $json_text = $config->slurp;
    $self->usage_error( 'config file has to be in JSON format: ' . $@ ) if ! eval{ $json->decode( $json_text ); 1; };
}

sub execute {
    my ($self, $opt, $args) = @_;

    if ( !$opt->{config} ) {
        print $self->usage->text;
        return;
    }
    
    my $config    = Path::Class::File->new( $opt->{config} );
    my $json_text = $config->slurp;
    my $object    = JSON->new->relaxed;
    my $json      = $object->decode( $json_text );
    my $name      = $json->{name};

    chdir $args->[0] if $args->[0];

    # check needed info
    for my $needed (qw(name version framework)) {
        if ( !$json->{$needed} ) {
            carp "Need $needed in config file";
            exit 1;
        }
    }
    
    my @xml_parts;
    my %major_versions;

    {
        for my $framework ( @{ $json->{framework} } ) {
            push @xml_parts, "    <Framework>$framework</Framework>";

            my $major_version = (split /\./, $framework)[0];
            $major_versions{$major_version}++;
        }

        if ( 2 <= keys %major_versions ) {
            carp "Two major versions declared in framework settings. Those might be incompatible.\n";
        }
    }

    my %utils_versions = (
        '3' => 'OTRS3',
        '4' => 'OTRS4',
        '5' => 'OTRS4',
    );

    my ($max) = sort{ $b <=> $a }keys %major_versions;
    my $mod   = $utils_versions{$max} || $utils_versions{3};
    my $utils = 'OTRS::OPM::Maker::Utils::' . $mod;

    if ( $json->{requires} ) {
        {
            for my $name ( sort keys %{ $json->{requires}->{package} } ) {
                push @xml_parts, sprintf '    <PackageRequired Version="%s">%s</PackageRequired>', $json->{requires}->{package}->{$name}, $name;
            }
        }
        
        {
            for my $name ( sort keys %{ $json->{requires}->{module} } ) {
                push @xml_parts, sprintf '    <ModuleRequired Version="%s">%s</ModuleRequired>', $json->{requires}->{module}->{$name}, $name;
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

    # create filelist
    {
        my @files = File::Find::Rule->file->in( '.' );

        # remove "hidden" files from list; and do not list .sopm
        @files = grep{ 
            ( substr( $_, 0, 1 ) ne '.' ) &&
            $_ !~ m{[\\/]\.} &&
            $_ ne $json->{name} . '.sopm'
        }sort @files;

        if ( $json->{exclude_files} and 'ARRAY' eq ref $json->{exclude_files} ) {
            for my $index ( reverse 0 .. $#files ) {
                my $file     = $files[$index];
                my $excluded = first {
                    eval{ $file =~ /$_\z/ };
                }@{ $json->{exclude_files} };

                splice @files, $index, 1 if $excluded;
            }
        }

        $utils->filecheck( \@files );

        push @xml_parts, 
            sprintf "    <Filelist>\n%s\n    </Filelist>",
                join "\n", map{ my $permission = $_ =~ /^bin/ ? 755 : 644; qq~        <File Permission="$permission" Location="$_" />~ }@files;
    }

    if ( $json->{changes_file} && -f $config->dir . "/" . $json->{changes_file} ) {
        my $changes_file = Path::Class::File->new( $config->dir, $json->{changes_file} );
        my $lines        = $changes_file->slurp( iomode => '<:encoding(UTF-8)' );

        my @entries = grep{ ( $_ // '' ) ne '' }split m{
            (?:\s+)?
            (                         # headline with version and date
                ^
                \d+\.\d+ (?:\.\d+)?   # version
                \s+ - \s+
                \d{4}-\d{2}-\d{2} \s  # date
                \d{2}:\d{2}:\d{2}     # time
            )
            \s+
        }xms, $lines;

        while ( @entries ) {
            my ($header, $desc) = ( shift(@entries), shift(@entries) );

            my ($version, $date) = split /\s+-\s+/, $header // '';

            $desc =~ s{\s+\z}{};

            push @xml_parts, sprintf qq~    <ChangeLog Version="%s" Date="%s"><![CDATA[ %s ]]></ChangeLog>~, $version, $date, $desc;
        }
    }

    # changelog
    {
        CHANGE:
        for my $change ( @{ $json->{changes} || [] } ) {
            my $version = '';
            my $date    = '';
            my $info    = '';

            if ( !ref $change ) {
                $info = $change;
            }
            elsif ( 'HASH' eq ref $change ) {
                $info    = $change->{message};
                $version = sprintf( ' Version="%s"', $change->{version} ) if $change->{version};
                $date    = sprintf( ' Date="%s"', $change->{date} )       if $change->{date};
            }

            next CHANGE if !length $info;

            push @xml_parts, sprintf "    <ChangeLog%s%s>%s</ChangeLog>", $version, $date, $info;
        }
    }

    my %actions = (
        Install   => 'post',
        Uninstall => 'pre',
        Upgrade   => 'post',
    );

    my %action_code = (
        TableCreate      => \&_TableCreate,
        Insert           => \&_Insert,
        TableDrop        => \&_TableDrop,
        ColumnAdd        => \&_ColumnAdd,
        ColumnDrop       => \&_ColumnDrop,
        ColumnChange     => \&_ColumnChange,
        ForeignKeyCreate => \&_ForeignKeyCreate,
        ForeignKeyDrop   => \&_ForeignKeyDrop,
        UniqueDrop       => \&_UniqueDrop,
        UniqueCreate     => \&_UniqueCreate,
    );
    
    my %tables_to_delete;
    my %db_actions;

    my $table_counter = 0;

    ACTION:
    for my $action ( @{ $json->{database} || [] } ) {
        my $tmp_version = $action->{version};
        my @versions    = ref $tmp_version ? @{$tmp_version} : ($tmp_version);

        VERSION:
        for my $version ( @versions ) {
            my $action_type = $version ? 'Upgrade' : 'Install';
            my $op          = $action->{type};

            if ( $action->{uninstall} ) {
                $action_type = 'Uninstall';
            }

            next VERSION if !$action_code{$op};
            
            if ( $op eq 'TableCreate' ) {
                my $table = $action->{name};
                $tables_to_delete{$table} = $table_counter++;
            }
            elsif ( $op eq 'TableDrop' ) {
                my $table = $action->{name};
                delete $tables_to_delete{$table};
            }
        
            $action->{version} = $version;    
            push @{ $db_actions{$action_type} }, $action_code{$op}->($action);
        }
    }
    
    if ( %tables_to_delete ) {
        for my $table ( sort { $tables_to_delete{$b} <=> $tables_to_delete{$a} }keys %tables_to_delete ) {
            push @{ $db_actions{Uninstall} }, _TableDrop({ name => $table });
        }
    }

    for my $action_type ( qw/Install Upgrade Uninstall/ ) {
        
        next if !$db_actions{$action_type};
        
        my $order = $actions{$action_type};
        
        push @xml_parts,
            sprintf qq~    <Database$action_type Type="$order">
%s
    </Database$action_type>~, join "\n", @{ $db_actions{$action_type} };
    }
    
    for my $code ( @{ $json->{code} || [] } ) {
        $code->{type} = 'Code' . $code->{type};
        push @xml_parts, $utils->packagesetup(
            $code->{type},
            $code->{version},
            $code->{function} || $code->{type},
        );
    }

    for my $intro ( @{ $json->{intro} || [] } ) {
        push @xml_parts, _IntroTemplate( $intro );
    }

    my $cvs = "";
    if ( $opt->{cvs} ) {
        $cvs = sprintf qq~\n    <CVS>\$Id: %s.sopm,v 1.1.1.1 2011/04/15 07:49:58 rb Exp \$</CVS>~, $name;
    }
    
    my $xml = sprintf q~<?xml version="1.0" encoding="utf-8" ?>
<otrs_package version="1.0">
    <!-- GENERATED WITH OTRS::OPM::Maker::Command::sopm (%s) -->%s
    <Name>%s</Name>
    <Version>%s</Version>
%s
</otrs_package>
~, 
    $VERSION,
    $cvs,
    $name,
    $json->{version},
    join( "\n", @xml_parts );

    my $fh = IO::File->new( $name . '.sopm', 'w' ) or die $!;
    $fh->print( $xml );
    $fh->close;
}

sub _IntroTemplate {
    my ($intro) = @_;

    my $version = $intro->{version} ? ' Version="' . $intro->{version} . '"' : '';
    my $type    = $intro->{type};
    my $text    = ref $intro->{text} ? join( "<br />\n", @{ $intro->{text} } ) : $intro->{text};
    my $phase   = $intro->{time} || "post";
    my $lang    = $intro->{lang} ? ' Lang="' . $intro->{lang} . '"' : '';
    my $title   = $intro->{title} ? ' Title="' . $intro->{title} . '"' : '';

    return qq~    <Intro$type Type="$phase"$lang$title$version><![CDATA[
            $text
    ]]></Intro$type>~;
}

sub _Insert {
    my ($action) = @_;


    my $table   = $action->{name};
    my $version = $action->{version};

    my $version_string = $version ? ' Version="' . $version . '"' : '';

    my $string = '        <Insert Table="' . $table . '"' . $version_string . ">\n";

    COLUMN:
    for my $column ( @{ $action->{columns} || [] } ) {
        my $value = ref $column->{value} ? join( "\n", @{ $column->{value} } ) : $column->{value};
        $string .= sprintf '            <Data Key="%s"%s>%s</Data>' . "\n",
            $column->{name},
            ( $column->{type} ? 
                (' Type="' . $column->{type} . '"', '<![CDATA[' . $value . ']]>' ) : 
                ("", $value)
            );
    }

    $string .= '        </Insert>';

    return $string; 
}

sub _TableDrop {
    my ($action) = @_;

    my $table = $action->{name};

    return '        <TableDrop Name="' . $table . '" />';
}

sub _TableCreate {
    my ($action) = @_;

    my $table   = $action->{name};
    my $version = $action->{version};

    my $version_string = $version ? ' Version="' . $version . '"' : '';

    my $string = '        <TableCreate Name="' . $table . '"' . $version_string . ">\n";

    COLUMN:
    for my $column ( @{ $action->{columns} || [] } ) {
        my $type = _TypeCheck( $column->{type}, 'TableCreate' );
        $string .= sprintf '            <Column Name="%s" Required="%s" Type="%s"%s%s%s />' . "\n",
            $column->{name},
            $column->{required},
            $type,
            ( $column->{size} ? ' Size="' . $column->{size} . '"' : "" ),
            ( $column->{auto_increment} ? ' AutoIncrement="true"' : "" ),
            ( $column->{primary_key} ? ' PrimaryKey="true"' : "" ),
    }

    UNIQUE:
    for my $unique ( @{ $action->{unique} || [] } ) {
        my $table = $unique->{name};
        $string .= '            <Unique Name="' . ($unique->{id} || join( "_", @{$unique->{columns} || ["unique$table"] } ) ) . '">' . "\n";

        for my $column ( @{ $unique->{columns} || [] } ) {
            $string .= '                <UniqueColumn Name="' . $column . '" />' . "\n";
        }

        $string .= '            </Unique>' . "\n";
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

sub _ColumnAdd {
    my ($action) = @_;

    my $table   = $action->{name};
    my $version = $action->{version};

    my $version_string = $version ? ' Version="' . $version . '"' : '';

    my $string = '        <TableAlter Name="' . $table . '"' . $version_string . ">\n";

    COLUMN:
    for my $column ( @{ $action->{columns} || [] } ) {
        my $type = _TypeCheck( $column->{type}, 'ColumnAdd' );
        $string .= sprintf '            <ColumnAdd Name="%s" Required="%s" Type="%s"%s%s%s />' . "\n",
            $column->{name},
            $column->{required},
            $type,
            ( $column->{size} ? ' Size="' . $column->{size} . '"' : "" ),
            ( $column->{auto_increment} ? ' AutoIncrement="true"' : "" ),
            ( $column->{primary_key} ? ' PrimaryKey="true"' : "" ),
    }

    $string .= '        </TableAlter>';

    return $string;
}

sub _ColumnDrop {
    my ($action) = @_;

    my $table   = $action->{name};
    my $version = $action->{version};

    my $version_string = $version ? ' Version="' . $version . '"' : '';

    my $string = '        <TableAlter Name="' . $table . '"' . $version_string . ">\n";

    COLUMN:
    for my $column ( @{ $action->{columns} || [] } ) {
        $string .= sprintf qq~            <ColumnDrop Name="%s" />\n~, $column;
    }

    $string .= '        </TableAlter>';

    return $string;
}

sub _ForeignKeyCreate {
    my ($action) = @_;

    my $table   = $action->{name};
    my $version = $action->{version};

    my $version_string = $version ? ' Version="' . $version . '"' : '';

    my $string = '        <TableAlter Name="' . $table . '"' . $version_string . ">\n";

    COLUMN:
    for my $reference ( @{ $action->{references} || [] } ) {
        $string .= sprintf '            <ForeignKeyCreate ForeignTable="%s">
                <Reference Local="%s" Foreign="%s" />
            </ForeignKeyCreate>' . "\n",
            $reference->{name},
            $reference->{local},
            $reference->{foreign};
    }

    $string .= '        </TableAlter>';

    return $string;
}

sub _ForeignKeyDrop {
    my ($action) = @_;

    my $table   = $action->{name};
    my $version = $action->{version};

    my $version_string = $version ? ' Version="' . $version . '"' : '';

    my $string = '        <TableAlter Name="' . $table . '"' . $version_string . ">\n";

    COLUMN:
    for my $reference ( @{ $action->{references} || [] } ) {
        $string .= sprintf '            <ForeignKeyDrop ForeignTable="%s">
                <Reference Local="%s" Foreign="%s" />
            </ForeignKeyDrop>' . "\n",
            $reference->{name},
            $reference->{local},
            $reference->{foreign};
    }

    $string .= '        </TableAlter>';

    return $string;
}

sub _UniqueCreate {
    my ($action) = @_;

    my $table   = $action->{name};
    my $version = $action->{version};

    my $version_string = $version ? ' Version="' . $version . '"' : '';

    my $string = '        <TableAlter Name="' . $table . '"' . $version_string . ">\n";
    $string   .= sprintf qq~            <UniqueCreate Name="%s">\n~, $action->{unique_name};

    COLUMN:
    for my $column ( @{ $action->{columns} || [] } ) {
        $string .= sprintf qq~                <UniqueColumn Name="%s" />\n~,
            $column;
    }

    $string .= qq~            </UniqueCreate>\n~;
    $string .= '        </TableAlter>';

    return $string;
}

sub _UniqueDrop {
    my ($action) = @_;

    my $table   = $action->{name};
    my $version = $action->{version};

    my $version_string = $version ? ' Version="' . $version . '"' : '';

    my $string = '        <TableAlter Name="' . $table . '"' . $version_string . ">\n";

    $string .= sprintf qq~            <UniqueDrop Name="%s" />\n~,
        $action->{unique_name};

    $string .= '        </TableAlter>';

    return $string;
}

sub _ColumnChange {
    my ($action) = @_;

    my $table   = $action->{name};
    my $version = $action->{version};

    my $version_string = $version ? ' Version="' . $version . '"' : '';

    my $string = '        <TableAlter Name="' . $table . '"' . $version_string . ">\n";

    COLUMN:
    for my $column ( @{ $action->{columns} || [] } ) {
        my $type = _TypeCheck( $column->{type}, 'ColumnChange' );
        $string .= sprintf '            <ColumnChange NameNew="%s" NameOld="%s" Required="%s" Type="%s"%s%s%s />' . "\n",
            $column->{new_name},
            $column->{old_name},
            $column->{required},
            $type,
            ( $column->{size} ? ' Size="' . $column->{size} . '"' : "" ),
            ( $column->{auto_increment} ? ' AutoIncrement="true"' : "" ),
            ( $column->{primary_key} ? ' PrimaryKey="true"' : "" ),
    }

    $string .= '        </TableAlter>';

    return $string;
}

sub _TypeCheck {
    my ($type, $action) = @_;

    my %types = (
        DATE     => 1,
        SMALLINT => 1,
        BIGINT   => 1,
        INTEGER  => 1,
        DECIMAL  => 1,
        VARCHAR  => 1,
        LONGBLOB => 1,
    );

    if ( !$types{$type} ) {
        croak "$type is not allowed in $action. Allowed types: ", join ', ', sort keys %types;
    }

    return $type;
}

1;

=head1 DESCRIPTION

SOPM files are used for OTRS addon creation. They define some metadata like the vendor, their URL, packages required or required Perl modules. 
It is an XML file and it's no fun to create it. It not uncommon that the list of files included in the addon is not updated before the addon is built and released.

That's why this package exists. You can define the metadata and stuff like database changes in a JSON file and the file list is created automatically. And you don't have to write the XML tags repeatedly.

=head1 INSTALLATION PHASES

When an OTRS addon is installed, it happens in several phases

=over 4

=item 1 CodeInstall - type "pre"

=item 2 DatabaseInstall - type "pre"

=item 3 Files are installed

=item 4 Include SysConfig

=item 5 DatabaseInstall - type "post"

=item 6 CodeInstall - type "post"

=back

These types are important in some cases and you'll see them later.

=head1 CONFIGURATION

You can configure this command with a JSON file.

=head2 A simple add on

This configuration file defines only the metadata.

 {
    "name": "Test",
    "version": "0.0.3",
    "framework": [
        "3.0.x"
    ],
    "vendor": {
        "name":  "Perl-Services.de",
        "url": "http://www.perl-services.de"
    },
    "license": "GNU AFFERO GENERAL PUBLIC LICENSE Version 3, November 2007",
    "description" : {
        "en": "Test sopm command"
    }
 }

And this .sopm will be created (assuming the file exists)

  <?xml version="1.0" encoding="utf-8" ?>
  <otrs_package version="1.0">
    <!-- GENERATED WITH OTRS::OPM::Maker::Command::sopm (1.27) -->
    <Name>Test</Name>
    <Version>0.0.3</Version>
    <Framework>3.0.x</Framework>
    <Vendor>Perl-Services.de</Vendor>
    <URL>http://www.perl-services.de</URL>
    <Description Lang="en">Test sopm command</Description>
    <License>GNU AFFERO GENERAL PUBLIC LICENSE Version 3, November 2007</License>
    <Filelist>
        <File Permission="644" Location="01_simple_json.t" />
        <File Permission="644" Location="02_intro.t" />
    </Filelist>
  </otrs>

=head2 Support more than one framework version

If the module runs on several framework version, you can define them in the list of frameworks

    "framework": [
        "3.0.x",
        "3.1.x",
        "3.2.x",
        "3.2.x"
    ],

And they will all be listed in the .sopm

    <Framework>3.0.x</Framework>
    <Framework>3.1.x</Framework>
    <Framework>3.2.x</Framework>
    <Framework>3.3.x</Framework>

=head2 Required packages and modules

Some addons depend on other addons and/or Perl modules. So it has to define those prerequesits.

    "requires": {
        "package" : {
            "TicketOverviewHooked" : "3.2.1"
        },
        "module" : {
            "Digest::MD5" : "0.01"
        }
    },

Creates those tags

    <PackageRequired Version="3.2.1">TicketOverviewHooked</PackageRequired>
    <ModuleRequired Version="0.01">Digest::MD5</ModuleRequired>

=head2 Database changes

=head3 Create new table

=head3 Insert stuff

=head3 Change Column

=cut
