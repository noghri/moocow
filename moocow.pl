#!/usr/bin/perl

 use strict;
 use warnings;
 use POE qw(Component::IRC);
 use LWP::UserAgent;
 use WebService::GData::YouTube;

 my $nickname = readconfig('nickname');
 my $ircname  = readconfig('ircname');
 my $server   = readconfig('server');
 my @channels = readconfig('channels');
 my $trigger = readconfig('trigger');

 my $irc = POE::Component::IRC->spawn(
    nick => $nickname,
    ircname => $ircname,
    server  => $server,
 ) or die "Oh noooo! $!";

my $cmd_actions ||= {
       wz => sub { weather(@_) },
       flip   => sub { coinflip(@_) },
       entertain => sub { entertain(@_) },
       moo => sub { moo(@_) },
       http => sub { gogl(@_); title(@_) }
   };

my @cmd_regex_array = map { qr{$_} } ("${trigger}(flip)",
                                      "${trigger}(wz) (.*)\$",
                                      "${trigger}(entertain)",
                                      "${trigger}(moo)",
                                      "(http):\/\/(.*)"
                                      );

 POE::Session->create(
     package_states => [
         main => [ qw(_default _start irc_001 irc_public) ],
     ],
 inline_states => {
    irc_disconnected => \&bot_reconnect,
    irc_error        => \&bot_reconnect,
    irc_socketerr    => \&bot_reconnect,
  },
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

     foreach my $re (@cmd_regex_array) {
         if (my ($arg)= $what =~ $re) {
              $cmd_actions->{$arg}->($2, $channel, $nick );
        }
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
my $apikey = readconfig('apikey');
my $url = "http://api.wunderground.com/api/$apikey/conditions/q/$zip.json";

my $ua = LWP::UserAgent->new;
$ua->timeout(10);
my $req = HTTP::Request->new(GET => $url);
my $res = $ua->request($req);
if (is_valid_zipcode($zip) == 1){
     $irc->yield( privmsg => $chan => "invalid zip $zip");
}
else {

    my $tmp="";
    my $conditions;
    my $temp;
    my $humidity;
    my $wind_speed;
    my $wind_dir;
    my $full_city;
    my $high;
    my $low;

    my @data = split /\n/, $res->content;

   foreach my $line(@data) {

       chomp($line);
       if( ($tmp) = $line =~ /weather\":\"(.*)\"/ ) { $conditions = $tmp; }
       if( ($tmp) = $line =~ /temperature_string\":\"(.*)\"/ ) { $temp = $tmp;}
       if( ($tmp) = $line =~ /relative_humidity\":\"(.*)\"/ ) { $humidity = $tmp;}
       if( ($tmp) = $line =~ /wind_string\":\"(.*)\"/ ) { $wind_speed = $tmp;}
       if( ($tmp) = $line =~ /wind_dir\":\"(.*)\"/ ) { $wind_dir = $tmp;}
       if( ($tmp) = $line =~ /full\":\"(.*)\"/ ) { $full_city = $tmp;}

    }
   $irc->yield( privmsg => $chan => "Weather for $full_city: Conditions: $conditions Temp: $temp Humidity: $humidity Wind Speed: $wind_speed Wind Direction: $wind_dir" );
   }
}


sub is_valid_zipcode {

    my @prams = @_;

    my $zip = $prams[0];

    if ($zip =~ /^[0-9]{5}(?:-[0-9]{4})?$/) {
        return 0;
    }

   elsif (uc($zip) =~ /^[ABCEGHJKLMNPRSTVXY]{1}\d{1}[A-Z]{1} *\d{1}[A-Z]{1}\d{1}$/) {
        return 0;
    }

    return 1;
}


sub coinflip {
    my @prams = @_;
    my $channel = $prams[1];
    my $result;
    my $range = 1000;
    my $random_num = int(rand($range));

    if ($random_num % 2 == 0) {
        $result = "Heads!";
    }
    else {
        $result = "Tails!";
   }
   $irc->yield( privmsg => $channel => "$result");
}

sub entertain {
    my @prams = @_;
    my $channel = $prams[1];
    $irc->yield( ctcp => $channel => "ACTION punches KtuLi in the throat." );
}

sub moo {
    my @prams = @_;
    my $channel = $prams[1];
    my $nick = $prams[2];
    $irc->yield( privmsg => $channel => "$nick: mooooooo" );
}

sub readconfig {

    my @prams = @_;
    my $configitem;

    my $configtext = $prams[0];

    open(FILE, "<", "moocow.config")
        or die "Cannot open config file: $!";

    while(<FILE>) {

        if($_ =~ /^$configtext = (.*)/) { close(FILE); return $1; }

    }

}

sub bot_reconnect {
  my $kernel = $_[KERNEL];
  $kernel->delay(autoping => undef);
  $kernel->delay(_start => 10);
}

sub gogl {
    
    my @prams = @_;
    my $url = $prams[0];
    my $goglurl = "https://www.googleapis.com/urlshortener/v1/url";

    my $ua = LWP::UserAgent->new;
    $ua->timeout(10);
    my $req = HTTP::Request->new(POST => $goglurl);
    $req->content_type('application/json');
    $req->content("{\"longUrl\": \"$url\"}");

    my $res = $ua->request($req);
    my @data = split /\n/, $res->content;

    foreach my $line(@data) {

       chomp($line);
       if ($line =~ /\"id\": \"(.*)\"/) { return $1; }

    }

}

sub title {

    my @prams = @_;
    my $url = $prams[0];
    
    my $ua = LWP::UserAgent->new;
    $ua->timeout(10);
    my $req = HTTP::Request->new(GET => $url);
    my $res = $ua->request($req);

    my @data = split /\n/, $res->content;
    foreach my $line(@data) {

        if(my ($title) = $line =~ m/<title>([a-zA-Z\/][^>]+)<\/title>/si) { return($title); }

    }

}

sub youtube {

    my @prams = @_;
    my $u2link=$prams[0];
    my $chan=$prams[1];

    my $shorturl = gogl($u2link);

    $u2link =~ /http:\/\/www.youtube.com\/watch\?v=(.*)/;
    my $u2=$1;

    my $yt = new WebService::GData::YouTube();

    my $video = $yt->get_video_by_id($u2);

    my $count = $video->view_count();
    my $duration = $video->duration();
    my $title = $video->title();

    $irc->yield( privmsg => $chan => "YouTube: $title Duration: $duration s Views: $count");


}
