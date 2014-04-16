#!/usr/bin/perl

use strict;
use warnings;

use Test::More;

use File::Spec;
use File::Basename;

use_ok 'OTRS::OPM::Maker::Command::sopm';

my $dir  = File::Spec->rel2abs( dirname __FILE__ );
my $json = File::Spec->catfile( $dir, 'Test.json' );
my $sopm = File::Spec->catfile( $dir, 'Test.sopm' );

OTRS::OPM::Maker::Command::sopm::execute( undef, { config => $json }, [ $dir ] );

ok -e $sopm;

my $content = do{ local (@ARGV, $/) = $sopm; <> };
my $check   = q~<?xml version="1.0" encoding="utf-8" ?>
<otrs_package version="1.0">
    <CVS>$Id: Test.sopm,v 1.1.1.1 2011/04/15 07:49:58 rb Exp $</CVS>
    <Name>Test</Name>
    <Version>0.0.3</Version>
    <Framework>3.0.x</Framework>
    <Framework>3.1.x</Framework>
    <Framework>3.2.x</Framework>
    <PackageRequired Version="3.2.1">TicketOverviewHooked</PackageRequired>
    <ModuleRequired Version="0.01">Digest::MD5</ModuleRequired>
    <Vendor>Perl-Services.de</Vendor>
    <URL>http://www.perl-services.de</URL>
    <Description Lang="en">Test sopm command</Description>
    <License>GNU AFFERO GENERAL PUBLIC LICENSE Version 3, November 2007</License>
    <Filelist>
        <File Permission="644" Location="01_simple_json.t" />
        <File Permission="644" Location="02_intro.t" />
        <File Permission="644" Location="03_database.t" />
        <File Permission="644" Location="Database.json" />
        <File Permission="644" Location="Intro.json" />
        <File Permission="644" Location="Test.json" />
    </Filelist>
    <DatabaseInstall Type="post">
        <TableCreate Name="opar_test">
            <Column Name="id" Required="true" Type="INTEGER" AutoIncrement="true" PrimaryKey="true" />
            <Column Name="object_id" Required="true" Type="INTEGER" />
            <Column Name="object_type" Required="true" Type="VARCHAR" Size="55" />
            <ForeignKey ForeignTable="system_user">
                <Reference Local="object_id" Foreign="id" />
            </ForeignKey>
        </TableCreate>
        <Insert Table="ticket_history_type">
            <Data Key="name" Type="Quote"><![CDATA[teest]]></Data>
            <Data Key="comments" Type="Quote"><![CDATA[test]]></Data>
            <Data Key="valid_id">1</Data>
            <Data Key="create_time" Type="Quote"><![CDATA[2012-10-18 00:00:00]]></Data>
            <Data Key="create_by">1</Data>
            <Data Key="change_time" Type="Quote"><![CDATA[2012-10-18 00:00:00]]></Data>
            <Data Key="change_by">1</Data>
        </Insert>
    </DatabaseInstall>
    <DatabaseUpgrade Type="post">
        <Insert Table="ticket_history_type" Version="0.0.2">
            <Data Key="name" Type="Quote"><![CDATA[teest]]></Data>
            <Data Key="comments" Type="Quote"><![CDATA[test]]></Data>
            <Data Key="valid_id">1</Data>
            <Data Key="create_time" Type="Quote"><![CDATA[2012-10-18 00:00:00]]></Data>
            <Data Key="create_by">1</Data>
            <Data Key="change_time" Type="Quote"><![CDATA[2012-10-18 00:00:00]]></Data>
            <Data Key="change_by">1</Data>
        </Insert>
    </DatabaseUpgrade>
    <DatabaseUninstall Type="pre">
        <TableDrop Name="opar_test" />
    </DatabaseUninstall>
</otrs_package>
~;

is $content, $check;

unlink $sopm;
ok !-e $sopm;


done_testing();
