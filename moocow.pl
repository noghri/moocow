#!/usr/bin/perl

use strict;
use warnings;
use POE qw(Component::IRC Component::IRC::State Component::IRC::Plugin::AutoJoin);
use LWP::UserAgent;
use Getopt::Std;
use WebService::GData::YouTube;
use DBI;
use POSIX;
use Config::Any;
use Config::Any::INI;
use Data::Dumper qw(Dumper);
$Config::Any::INI::MAP_SECTION_SPACE_TO_NESTED_KEY = 0;

my %opts;
my $confpath = "moocow.config";


getopts('h:f:', \%opts);

if(exists($opts{f}))
{
  $confpath = $opts{f};
}


parseconfig($confpath);


my $nickname = readconfig('nickname');
my $ircname  = readconfig('ircname');
my $server   = readconfig('server');
my $channels = readconfig('channels');
my $trigger  = readconfig('trigger');
my $dbpath   = readconfig('dbpath');

my %chans;

foreach my $c (split(',', $channels))
{
    my ($chan, $key) = split(/ /, $c);
    $key = "" if(!defined($key));
    $chans{$chan} = $key;
}



my $dbh = DBI->connect("dbi:SQLite:$dbpath")
  || die "Cannot connect: $DBI::errstr";

my $irc = POE::Component::IRC->spawn(
    nick    => $nickname,
    ircname => $ircname,
    server  => $server,
) or die "Oh noooo! $!";

my %cmd_hash;

$cmd_hash{"flip"}      = sub { coinflip(@_); };
$cmd_hash{"wz"}        = sub { weather(@_); };
$cmd_hash{"entertain"} = sub { entertain(@_); };
$cmd_hash{"quote"}     = sub { quote(@_); };
$cmd_hash{"addquote"}  = sub { addquote(@_); };
$cmd_hash{"moo"}       = sub { moo(@_); };
$cmd_hash{"tu"}        = sub { gogl(@_); };
$cmd_hash{"u2"}        = sub { youtube(@_); };
$cmd_hash{"help"}      = sub { help(@_); };
$cmd_hash{"codeword"}  = sub { codeword(@_); };

POE::Session->create(
    package_states => [ main => [qw(_default _start irc_001 irc_public irc_ctcp_version)], ],
    inline_states  => {
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
    $irc->plugin_add('AutoJoin', POE::Component::IRC::Plugin::AutoJoin->new( Channels => \%chans ));
    $irc->yield( register => 'all' );
    $irc->yield( connect  => {} );
    return;
}

sub irc_001 {
    my $sender = $_[SENDER];

    # Since this is an irc_* event, we can get the component's object by
    # accessing the heap of the sender. Then we register and connect to the
    # specified server.
    my $irc = $sender->get_heap();

    print "Connected to ", $irc->server_name(), "\n";

    return;
}

sub irc_public {

    my ( $sender, $who, $where, $what ) = @_[ SENDER, ARG0 .. ARG2 ];
    my $nick = ( split /!/, $who )[0];
    my $channel = $where->[0];

    if ( my ($youtube) = $what =~ /^(http:\/\/youtu.be\/.*)/ ) { 
      youtube($youtube, $channel, $nick);
    }
    elsif ( my ($youtube) = $what =~ /^(http:\/\/www.youtube.com\/.*)/ ) { 
      youtube($youtube, $channel, $nick);
    }
    elsif ( my ($gogl) = $what =~ /^http:\/\/(.*)/ ) {
      $irc->yield( privmsg => $channel => gogl($gogl,$channel, $nick));
      $irc->yield( privmsg => $channel => title($gogl,$channel));
    }
                  

    return if ( $what !~ /^$trigger(.*)/ );

    my @cmd = split / +/, $1;
    chomp(@cmd);
    my $cmd = shift @cmd;
    my $cmdargs = join( " ", @cmd );
    if ( exists $cmd_hash{$cmd} ) {
        $cmd_hash{$cmd}->( $cmdargs, $channel, $nick );
    }
    

    return;
}

sub irc_ctcp_version {
    my ( $sender, $who, $where, $what ) = @_[ SENDER, ARG0 .. ARG2 ];
    $who =~ s/^(.*)!.*$/$1/ or die "Weird who: $who";
    $irc->yield( ctcp => $who => "VERSION moocow 0.01 - its perl!" );
    return;
}


# We registered for all events, this will produce some debug info.
sub _default {
    my ( $event, $args ) = @_[ ARG0 .. $#_ ];
    my @output = ("$event: ");

    for my $arg (@$args) {
        if ( ref $arg eq 'ARRAY' ) {
            push( @output, '[' . join( ', ', @$arg ) . ']' );
        }
        else {
            push( @output, "'$arg'" );
        }
    }
    print join ' ', @output, "\n";
    return;
}

sub quote {
    my @prams    = @_;
    my $quotecmd = $prams[0];
    my $channel  = $prams[1];
    my $query =
      q{SELECT quote, usermask, timestamp, quoteid FROM quotes WHERE channel = ?};
    my $sth;

    if (defined($quotecmd) && $quotecmd ne '' ) {
        $query = $query . q{ AND LOWER(quote) LIKE ? LIMIT 1; };
        $sth   = $dbh->prepare($query);
        $sth->bind_param( 1, $channel );
        $sth->bind_param( 2, "%$quotecmd%" );

    }
    else {
        $query = $query . q{ ORDER BY RANDOM() LIMIT 1; };
        $sth = $dbh->prepare($query);
        $sth->bind_param( 1, $channel );
        warn if ($@);
    }

    $sth->execute() || die("Unable to execute $@");

    if ($@) {
        $irc->yield( privmsg => $channel => "Error reading quote: " . $@ );
        return;
    }

    my $count = 0;
    while(defined (my $res = $sth->fetchrow_hashref))
    {

        my $qt = $res->{'quote'};
        my $um = $res->{'usermask'};
        my $id = $res->{'quoteid'};
        my $ts = strftime("%Y-%m-%d %H:%M:%S", localtime($res->{'timestamp'}));
        $irc->yield( privmsg => $channel => "Quote[$id] $qt [$um] [$ts]" );
        ++$count;
        # only return one result for now...
        return;
    }

    if($count == 0) {
        $irc->yield( privmsg => $channel => "No matching quotes" );
    }
}

sub addquote {
    my @prams   = @_;
    my $quote   = $prams[0];
    my $channel = $prams[1];
    my $who     = $prams[2];

    my $query =
'INSERT INTO quotes(quote, usermask, channel, timestamp) VALUES (?, ?, LOWER(?), strftime(\'%s\',\'now\'))';
    my $sth = $dbh->prepare($query);
    if ($@) {
        $irc->yield( privmsg => $channel => "Error inserting quote: " . $@ );
        return;
    }
    $sth->bind_param( 1, $quote );
    $sth->bind_param( 2, $who );
    $sth->bind_param( 3, $channel );
    DBI::dump_results($sth);
    $sth->execute();
    if ($@) {
        $irc->yield(
            privmsg => $channel => "Error inserting quote: " . $sth->err );
    }
    else {
        if ( $sth->rows > 0 ) {
            $irc->yield( privmsg => $channel => "Quote has been added, fool!" );
        }
    }
}

sub weather {

    my @prams  = @_;
    my $zip    = $prams[0];
    my $chan   = $prams[1];
    my $apikey = readconfig('apikey');
    my $url = "http://api.wunderground.com/api/$apikey/conditions/q/$zip.json";

    my $ua = LWP::UserAgent->new;
    $ua->timeout(10);
    my $req = HTTP::Request->new( GET => $url );
    my $res = $ua->request($req);
    if ( is_valid_zipcode($zip) == 1 ) {
        $irc->yield( privmsg => $chan => "invalid zip $zip" );
    }
    else {

        my $tmp = "";
        my $conditions;
        my $temp;
        my $humidity;
        my $wind_speed;
        my $wind_dir;
        my $full_city;
        my $high;
        my $low;

        my @data = split /\n/, $res->content;

        foreach my $line (@data) {

            chomp($line);
            if ( ($tmp) = $line =~ /weather\":\"(.*)\"/ ) {
                $conditions = $tmp;
            }
            if ( ($tmp) = $line =~ /temperature_string\":\"(.*)\"/ ) {
                $temp = $tmp;
            }
            if ( ($tmp) = $line =~ /relative_humidity\":\"(.*)\"/ ) {
                $humidity = $tmp;
            }
            if ( ($tmp) = $line =~ /wind_string\":\"(.*)\"/ ) {
                $wind_speed = $tmp;
            }
            if ( ($tmp) = $line =~ /wind_dir\":\"(.*)\"/ ) { $wind_dir = $tmp; }
            if ( ($tmp) = $line =~ /full\":\"(.*)\"/ ) { $full_city = $tmp; }

        }
        $irc->yield( privmsg => $chan =>
"Weather for $full_city: Conditions: $conditions Temp: $temp Humidity: $humidity Wind Speed: $wind_speed Wind Direction: $wind_dir"
        );
    }
}

sub is_valid_zipcode {

    my @prams = @_;

    my $zip = $prams[0];

    if ( $zip =~ /^[0-9]{5}(?:-[0-9]{4})?$/ ) {
        return 0;
    }

    elsif (
        uc($zip) =~
        /^[ABCEGHJKLMNPRSTVXY]{1}\d{1}[A-Z]{1} *\d{1}[A-Z]{1}\d{1}$/ )
    {
        return 0;
    }

    return 1;
}

sub coinflip {
    my @prams   = @_;
    my $channel = $prams[1];
    my $result;
    my $range      = 1000;
    my $random_num = int( rand($range) );

    if ( $random_num % 2 == 0 ) {
        $result = "Heads!";
    }
    else {
        $result = "Tails!";
    }
    $irc->yield( privmsg => $channel => "$result" );
}

sub codeword {
    my @prams   = @_;
    my $codeword = $prams[0];
    my $channel = $prams[1];
    my $kickee  = $prams[2];
    my $kickres = "Don't try to make up codewords!";
 
    if ($codeword =~ /pink-ribbons/i) {
      $kickee = "jchawk";
      $kickres = "PINK RIBBONS!";
    } elsif ($codeword =~ /slacker/i) {
      $kickee = "ktuli";
      $kickres = "SLACKER!";
    } elsif ($codeword =~ /dirtbag/i) {
      $kickee = "noghri";
      $kickres = "DIRTBAG!";
    } elsif ($codeword =~ /wonderbread/i) {
      $kickee = "tonyj";
      $kickres = "WONDERBREAD!!!";
    }

    $irc->yield(kick => $channel => $kickee => $kickres);
}

sub entertain {
    my @prams   = @_;
    my $channel = $prams[1];
    $irc->yield( ctcp => $channel => "ACTION punches KtuLi in the throat." );
}

sub moo {
    my @prams   = @_;
    my $channel = $prams[1];
    my $nick    = $prams[2];
    $irc->yield( privmsg => $channel => "$nick: mooooooo" );
}


# config file format

#[bot]
#nickname = nick
#username = username
#password = password
#gecos = gecos




my $ini;
sub parseconfig {
    my $path = $_[0];
    $ini = Config::Any::INI->load($path) || die("Unable to parse config file $path: $!");
#    my %ini = %{
    print Dumper($ini); 
#    exit;
}

sub readconfig {

    my @prams = @_;
    my $configitem;

    my $configtext = $prams[0];
    if(!exists($ini->{$configtext}))
    {
      die("Config file entry: $configtext is missing!");
    }
    return $ini->{$configtext};
}

sub bot_reconnect {
    my $kernel = $_[KERNEL];
    $kernel->delay( autoping => undef );
    $kernel->delay( _start   => 10 );
}

sub gogl {

    my @prams   = @_;
    my $url     = $prams[0];
    my $goglurl = "https://www.googleapis.com/urlshortener/v1/url";

    my $ua = LWP::UserAgent->new;
    $ua->timeout(10);
    my $req = HTTP::Request->new( POST => $goglurl );
    $req->content_type('application/json');
    $req->content("{\"longUrl\": \"$url\"}");

    my $res = $ua->request($req);
    my @data = split /\n/, $res->content;

    foreach my $line (@data) {

        chomp($line);
        if ( $line =~ /\"id\": \"(.*)\"/ ) { return $1; }

    }

}

sub title {

    my @prams = @_;
    my $url   = $prams[0];

    my $ua = LWP::UserAgent->new;
    $ua->timeout(10);
    my $req = HTTP::Request->new( GET => $url );
    my $res = $ua->request($req);

    my @data = split /\n/, $res->content;
    foreach my $line (@data) {

        if ( my ($title) = $line =~ m/<title>([a-zA-Z\/][^>]+)<\/title>/si ) {
            return ($title);
        }

    }

}

sub youtube {

    my @prams  = @_;
    my $u2link = $prams[0];
    my $chan   = $prams[1];

    my $shorturl = gogl($u2link);

    if ($u2link =~ /youtube/i) {
      $u2link =~ /http:\/\/www.youtube.com\/watch\?v=(.*)/;
    } elsif ($u2link =~ /youtu\.be/i) {
      $u2link =~ /http:\/\/youtu.be\/(.*)/;
    }
    my $u2 = $1;

    my $yt = new WebService::GData::YouTube();

    my $video = $yt->get_video_by_id($u2);

    my $count    = $video->view_count();
    my $duration = $video->duration();
    my $title    = $video->title();

    $irc->yield( privmsg => $chan =>
          "YouTube: $title Duration: $duration s Views: $count" );

}


sub help {

    my @prams = @_;
    my $chan = $prams[1];
    my $nick = $prams[2];

    $irc->yield( privmsg => $nick => "!tu <url>: Shorten a url" );
    $irc->yield( privmsg => $nick => "!u2 <url>: youtube info" );
    $irc->yield( privmsg => $nick => "!flip: coin flip" );
    $irc->yield( privmsg => $nick => "!wz <zip>: Weather for zip" );
    $irc->yield( privmsg => $nick => "!entertain: Massive entertainment." );
    $irc->yield( privmsg => $nick => "!codeword <codeword>: Special codeword actions." );
    $irc->yield( privmsg => $nick => "!quote: Display random quote" );
    $irc->yield( privmsg => $nick => "!addquote <quote>: add a new quote" );
    $irc->yield( privmsg => $nick => "!moo: moo." );
}
