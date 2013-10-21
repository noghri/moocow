#!/bin/bash
curl -L http://cpanmin.us | perl - --sudo App::cpanminus

declare -a IRCMODS=('Component::IRC' 'Component::IRC::State' 'Component::IRC::Plugin::AutoJoin' 'Component::IRC::Plugin::Connector' 'Component::IRC::Plugin::NickReclaim' 'Component::IRC::Plugin::CTCP');

for var in "${IRCMODS[@]}"
do
    echo "cpanm --sudo POE::${var}"
done

cpmann --sudo Getopt::Std;
cpmann --sudo WebService::GData::YouTube;
cpmann --sudo DBI;
cpmann --sudo POSIX;
cpmann --sudo Config::Any;
cpmann --sudo Config::Any::INI;
cpmann --sudo Cache::FileCache;
cpmann --sudo WWW::Wunderground::API;
cpmann --sudo Data::Dumper;
cpmann --sudo HTML::TableExtract;
cpmann --sudo LWP::UserAgent::WithCache;
cpmann --sudo IRC::Utils;

