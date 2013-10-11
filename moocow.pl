#!/usr/bin/perl

 use strict;
 use warnings;
 use POE qw(Component::IRC);
 use LWP::UserAgent;

 my $nickname = 'moocow_';
 my $ircname  = 'moooooooooo';
 my $server   = 'irc.teksavvy.ca';

 my @channels = ('#threerivers');

 my $irc = POE::Component::IRC->spawn(
    nick => $nickname,
    ircname => $ircname,
    server  => $server,
 ) or die "Oh noooo! $!";

 POE::Session->create(
     package_states => [
         main => [ qw(_default _start irc_001 irc_public) ],
     ],
     heap => { irc => $irc },
 );

 $poe_kernel->run();

 sub _start {
     my $heap = $_[HEAP];

     # retrieve our component's object from the heap where we stashed it
     my $irc = $heap->{irc};

     $irc->yield( register => 'all' );
     $irc->yield( connect => { } );
     return;
 }

 sub irc_001 {
     my $sender = $_[SENDER];

     # Since this is an irc_* event, we can get the component's object by
     # accessing the heap of the sender. Then we register and connect to the
     # specified server.
     my $irc = $sender->get_heap();

     print "Connected to ", $irc->server_name(), "\n";

     # we join our channels
     $irc->yield( join => $_ ) for @channels;
     return;
 }

 sub irc_public {
     my ($sender, $who, $where, $what) = @_[SENDER, ARG0 .. ARG2];
     my $nick = ( split /!/, $who )[0];
     my $channel = $where->[0];

     if ( my ($moo) = $what =~ /^!moo/ ) {
         $irc->yield( privmsg => $channel => "$nick: mooooooo" );
     }
     if ( my ($entertain) = $what =~ /^!entertain/ ) {
         $irc->yield( ctcp => $channel => "ACTION punches KtuLi in the throat." );
     }
     if ( my ($weather) = $what =~ /^.wz (.*)/ ) {
        weather($weather,$channel);
     }
     return;
 }

 # We registered for all events, this will produce some debug info.
 sub _default {
     my ($event, $args) = @_[ARG0 .. $#_];
     my @output = ( "$event: " );

     for my $arg (@$args) {
         if ( ref $arg eq 'ARRAY' ) {
             push( @output, '[' . join(', ', @$arg ) . ']' );
         }
         else {
             push ( @output, "'$arg'" );
         }
     }
     print join ' ', @output, "\n";
     return;
 }

sub weather {

my @prams = @_;

my $zip = $prams[0];
my $chan = $prams[1];
my $apikey = "bdf8d52c20b509c5";
my $url = "http://api.wunderground.com/api/$apikey/conditions/q/$zip.json";

my $ua = LWP::UserAgent->new;
my $req = HTTP::Request->new(GET => $url);
my $res = $ua->request($req);

my $tmp="";
my $conditions;
my $temp;
my $humidity;
my $wind_speed;
my $wind_dir;

my @data = split /\n/, $res->content;

foreach my $line(@data) {

   chomp($line);
   if( ($tmp) = $line =~ /weather\":\"(.*)\"/ ) { $conditions = $tmp; }
   if( ($tmp) = $line =~ /temperature_string\":\"(.*)\"/ ) { $temp = $tmp;}
   if( ($tmp) = $line =~ /relative_humidity\":\"(.*)\"/ ) { $humidity = $tmp;}
   if( ($tmp) = $line =~ /wind_string\":\"(.*)\"/ ) { $wind_speed = $tmp;}
   if( ($tmp) = $line =~ /wind_dir\":\"(.*)\"/ ) { $wind_dir = $tmp;}
   
}
   $irc->yield( privmsg => $chan => "Weather for $zip: Conditions: $conditions Temp: $temp Humidity: $humidity Wind Speed: $wind_speed Wind Direction: $wind_dir" );

}
