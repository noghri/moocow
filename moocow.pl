#!/usr/bin/perl

use strict;
use warnings;
use POE qw(Component::IRC Component::IRC::State Component::IRC::Plugin::AutoJoin Component::IRC::Plugin::Connector Component::IRC::Plugin::NickReclaim Component::IRC::Plugin::CTCP);
use Getopt::Std;
use WebService::GData::YouTube;
use DBI;
use POSIX;
use Config::Any;
use Config::Any::INI;
use Cache::FileCache;
use WWW::Wunderground::API;
use Data::Dumper;
use HTML::TableExtract;
use LWP::UserAgent::WithCache;

$Config::Any::INI::MAP_SECTION_SPACE_TO_NESTED_KEY = 0;

my %opts;
my $confpath = "moocow.config";

getopts( 'h:f:', \%opts );

if ( exists( $opts{f} ) ) {
    $confpath = $opts{f};
}

parseconfig($confpath);

my $nickname = readconfig('nickname');
my $ircname  = readconfig('ircname');
my $server   = readconfig('server');
my $channels = readconfig('channels');
my $trigger  = readconfig('trigger');
my $dbpath   = readconfig('dbpath');
my $autourl  = readconfig('autourl');

# for WORD game
my $word_on = 0;   # !word game
my $word_ans = ""; # the actual answer
my %wordppl; # everyone who tries for score keeping
my $word_s = "";

# sub-routines
sub say($$);
sub word(@);
sub hack(@);

if($autourl =~ /(true|1|yes)/) {
    $autourl = 1;
} else {
  $autourl = 0;
}

my %chans;



foreach my $c ( split( ',', $channels ) ) {
    my ( $chan, $key ) = split( / /, $c );
    $key = "" if ( !defined($key) );
    $chans{$chan} = $key;
}

my $dbh = DBI->connect("dbi:SQLite:$dbpath")
  || die "Cannot connect: $DBI::errstr";

my $irc = POE::Component::IRC->spawn(
    nick    => $nickname,
    ircname => $ircname,
    server  => $server,
    Debug   => 1,
    Flood   => 0,
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
$cmd_hash{"wze"}       = sub { weather_extended(@_); };
$cmd_hash{"nhl"}       = sub { nhl_standings(@_); };
$cmd_hash{"word"}       = sub { word(@_); };
$cmd_hash{"hack"}       = sub { hack(@_); };

POE::Session->create(
    package_states => [ main => [qw(_default _start irc_001 irc_public irc_ctcp_version)], ],
    inline_states  => { },
    heap => { irc => $irc },
);

$poe_kernel->run();

sub _start {
    my $heap = $_[HEAP];

    # retrieve our component's object from the heap where we stashed it
    my $irc = $heap->{irc};
    $irc->plugin_add( 'AutoJoin', POE::Component::IRC::Plugin::AutoJoin->new( Channels => \%chans ) );
    $irc->plugin_add( 'Connector', POE::Component::IRC::Plugin::Connector->new(delay => 60, reconnect => 5));
    $irc->plugin_add('NickReclaim', POE::Component::IRC::Plugin::NickReclaim->new( poll => 30));
    $irc->plugin_add('CTCP', POE::Component::IRC::Plugin::CTCP->new(
                      version => "moocow 0.01 - its perl!",
                      userinfo => "I am a cow, not a user!",
                      clientinfo => "moocow - its perl!",
                      source => "grass"));
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
    # for the !word game
    if($word_on && $what eq $word_ans){ # !word game
            $irc->yield( privmsg => $where->[0] => "That's right! :D");
            my $whop = $who;
            $whop =~ s/!.*//;
            $wordppl{$whop} = ($wordppl{$whop} + 1);
            $word_ans = "";
            $word_s = "";
            $word_on = 0;
    }
    if($what =~ m/^hack/i){
        hack();
    }
    if($autourl)
    {
      if ( my ($youtube) = $what =~ /^(http:\/\/(www\.youtube\.com|youtube\.com|youtu\.be)\/.*)/ ) { 
        youtube($youtube, $channel, $nick);
      }
      elsif ( my ($gogl) = $what =~ /^(http:\/\/.*)/ ) {
        gogl( $gogl, $channel, $nick );
      }
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
    return;
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
    my $query    = q{SELECT quote, usermask, timestamp, quoteid FROM quotes WHERE channel = ?};
    my $sth;

    if ( defined($quotecmd) && $quotecmd ne '' ) {
        $query = $query . q{ AND LOWER(quote) LIKE ? LIMIT 1; };
        $sth   = $dbh->prepare($query);
        $sth->bind_param( 1, $channel );
        $sth->bind_param( 2, "%$quotecmd%" );

    }
    else {
        $query = $query . q{ ORDER BY RANDOM() LIMIT 1; };
        $sth   = $dbh->prepare($query);
        $sth->bind_param( 1, $channel );
        warn if ($@);
    }

    $sth->execute() || die("Unable to execute $@");

    if ($@) {
        $irc->yield( privmsg => $channel => "Error reading quote: " . $@ );
        return;
    }

    my $count = 0;
    while ( defined( my $res = $sth->fetchrow_hashref ) ) {

        my $qt = $res->{'quote'};
        my $um = $res->{'usermask'};
        my $id = $res->{'quoteid'};
        my $ts = strftime( "%Y-%m-%d %H:%M:%S", localtime( $res->{'timestamp'} ) );
        $irc->yield( privmsg => $channel => "Quote[$id] $qt [$um] [$ts]" );
        ++$count;

        # only return one result for now...
        return;
    }

    if ( $count == 0 ) {
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
        $irc->yield( privmsg => $channel => "Error inserting quote: " . $sth->err );
    }
    else {
        if ( $sth->rows > 0 ) {
            $irc->yield( privmsg => $channel => "Quote has been added, fool!" );
        }
    }
}

sub weather_extended {
    my @prams  = @_;
    my $zip    = $prams[0];
    my $chan   = $prams[1];
    my $apikey = readconfig('apikey');

    my $wun = new WWW::Wunderground::API(location => $zip, api_key => $apikey, auto_api => 1,  cache=>Cache::FileCache->new({ namespace=>'moocow_wundercache', default_expires_in=>2400 }));

    if($wun->response->error->description)
    {
        $irc->yield(privmsg => $chan => "No results: " . $wun->response->error->description);
        return;
    }
    
    if($wun->response->results)
    {
        $irc->yield(privmsg => $chan => "Too many results for location $zip");
        return;
    }

    my $cond = $wun->conditions;
    my $updated = $cond->observation_time;
    $updated =~ s/Last Updated on //;
    my $location = $cond->display_location->city;
    my $weather = $cond->weather;
    my $temp = $cond->temperature_string;
    my $feels = $cond->feelslike_string;
    my $uv = $cond->UV;
    my $humid = $cond->relative_humidity;
    my $pressin = $cond->pressure_in;
    my $pressmb = $cond->pressure_mb;
    my $wind = $cond->wind_string;
    $wind =~ s/From the //;
    my $dew = $cond->dewpoint_string;
    my $precip = $cond->precip_today_string;
    #Harpers Ferry, WV; Updated: 3:00 PM EDT on October 17, 2013; Conditions: Overcast; Temperature: 71.2°F (21.8°C); UV: 1/16 Humidity: 75%; Pressure: 29.79 in/2054 hPa (Falling); Wind: SSE at 5.0 MPH (8 KPH)
    $irc->yield(privmsg => $chan => "WX $location Updated: $updated Conditions: $weather: Temp: $temp Feels like: $feels Dewpoint: $dew UV: $uv Humidity: $humid: Pressure: ${pressin}/in/${pressmb} MB Wind: $wind Precip: $precip");
#    my $resp = $wun->r->full_location . "Updated: $obs"
    return;


}

sub weather {

    my @prams  = @_;
    my $zip    = $prams[0];
    my $chan   = $prams[1];
    my $apikey = readconfig('apikey');

    my $wun = new WWW::Wunderground::API(location => $zip, api_key => $apikey, auto_api => 1,  cache=>Cache::FileCache->new({ namespace=>'moocow_wundercache', default_expires_in=>2400 }));

    if($wun->response->error->description)
    {
        $irc->yield(privmsg => $chan => "No results: " . $wun->response->error->description);
        return;
    }
    
    if($wun->response->results)
    {
        $irc->yield(privmsg => $chan => "Too many results for location $zip");
        return;
    }
#    print Dumper($wun->conditions);
    my $city = $wun->conditions->observation_location->full;
    my $temp = $wun->conditions->temperature_string;
    my $humidity = $wun->conditions->relative_humidity;
    my $wind_speed = $wun->conditions->wind_string;
    my $weather = $wun->conditions->weather;
    my $forecast = $wun->forecast->txt_forecast->forecastday->[0]{fcttext};

    $irc->yield( privmsg => $chan => "Weather for $city: Conditions $weather Temp: $temp Humidity: $humidity Wind: $wind_speed"); 
    $irc->yield( privmsg => $chan => "$forecast");
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

my $ini;

sub parseconfig {
    my $path = $_[0];
    $ini = Config::Any::INI->load($path) || die("Unable to parse config file $path: $!");
}

sub readconfig {

    my @prams = @_;
    my $configitem;

    my $configtext = $prams[0];
    if ( !exists( $ini->{$configtext} ) ) {
        die("Config file entry: $configtext is missing!");
    }
    return $ini->{$configtext};
}

sub gogl {

    my @prams   = @_;
    my $url     = $prams[0];
    my $channel = $prams[1];
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
        if ( $line =~ /\"id\": \"(.*)\"/ ) 
        { 
          $irc->yield(privmsg => $channel => "$1");
          last;
        }
    }
    my $title = title($url);
    
    $irc->yield(privmsg => $channel => title($url)) if(defined($title));


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
    return undef;
}

sub youtube{
        my $u2 = $3 if($_[0] =~ m/^.*youtu(\.)?be(\.com\/watch\?v=|\/)(.*)/i);
        my $yt = new WebService::GData::YouTube();
        say($_[1],"YouTube: \x02".$yt->get_video_by_id($u2)->title()."\x02 Duration: \x02".$yt->get_video_by_id($u2)->duration."\x02 seconds Views: \x02".$yt->get_video_by_id($u2)->view_count."\x02");
        gogl(@_);
}

sub say($$){ # just to minimize typing
        $irc->yield(privmsg => $_[0] => $_[1]); # needs to be changed to $channel
        return;
}

sub word(@){ # !word game
        $wordppl{$_[2]} = 0 if(!exists($wordppl{$_[2]}));
        if($_[0] eq "reset"){ # because there is no timer function
                say($_[1],"the word has been reset by ".$_[2]." answer was: " .$word_ans);
                $word_on = 0;
                $word_ans = "";
                return;
        }elsif($_[0] =~ m/^score(s)?/){ # show your score
                my $scores = "";
                while(my($k,$v) = each(%wordppl)){
                        $scores .= $k.": ".$v.", ";
                }
                $scores =~ s/, $//;
                say($_[1],$scores);
                return;
        }elsif($word_on){ # boolean
                say($_[1],"the game is already running with word: (" . $word_s . "), try \"!word reset\" to start over");
                return;
        }else{
                my $no = int(rand(`wc -l /home/trevelyn/words.txt | awk '{print \$1}'`));
                $word_ans = `sed '$no q;d' /home/trevelyn/words.txt`;
                chomp $word_ans; # answer
                my @word = split(//,$word_ans);
                my $sw = ""; # scrambled word
                until($#word == -1){
                        my $rn = int(rand($#word));
                        $sw .= $word[$rn];
                        splice(@word,$rn,1);
                }
                $word_s = $sw;
                say($_[1],$sw);
                $word_on = 1;
        }
        return;
}

sub hack(@){
    say($_[1],"hack the planet!");
}

sub help {

    my @prams = @_;
    my $chan  = $prams[1];
    my $nick  = $prams[2];

    $irc->yield( privmsg => $nick => "!tu <url>: Shorten a url" );
    $irc->yield( privmsg => $nick => "!u2 <url>: youtube info" );
    $irc->yield( privmsg => $nick => "!flip: coin flip" );
    $irc->yield( privmsg => $nick => "!wz <zip>: Weather for zip" );
    $irc->yield( privmsg => $nick => "!entertain: Massive entertainment." );
    $irc->yield( privmsg => $nick => "!codeword <codeword>: Special codeword actions." );
    $irc->yield( privmsg => $nick => "!quote: Display random quote" );
    $irc->yield( privmsg => $nick => "!addquote <quote>: add a new quote" );
    $irc->yield( privmsg => $nick => "!nhl: nhl standings" );
    $irc->yield( privmsg => $nick => "!word: word scramble game" );
    $irc->yield( privmsg => $nick => "!moo: moo." );
}

sub nhl_standings {

    my @prams = @_;
    my $division = $prams[0];
    my $chan  = $prams[1];
    my $nick  = $prams[2];

    return if($division eq "");

    my $url = "http://www.nhl.com/ice/m_standings.htm?type=DIV";

    my $ua = LWP::UserAgent::WithCache->new({'namespace' => 'moocowlwp_cache', 'default_expires_in' => 3600} );
    $ua->timeout(5);
    my $req = HTTP::Request->new( GET => $url );
    my $res = $ua->request($req);

    my @headers = ("$division", 'GP', 'W', 'L', '.+' );

    my $te = HTML::TableExtract->new( debug=> 0, subtables => 0, automap => 0, headers => [@headers]) || die("Unable create object: $!");

    $te->parse($res->content) || die("Error: $!");
    
    my $header = sprintf("%-7s %-20s %-3s %-3s %-3s %-3s %-3s", "Place", "Team", "GP", "W", "L", "OTL", "P");

    foreach my $ts ($te->tables) {
        $irc->yield( privmsg => $chan => $header);    
	foreach my $row ($ts->rows) {
		chomp(@$row);
		my $team = @{$row}[1];
		$team =~ s/\n//g;
		my $line = sprintf("%-7s %-20s %-3s %-3s %-3s %-3s %-3s", @{$row}[0], $team, @{$row}[2], @{$row}[3],  @{$row}[4], @{$row}[5], @{$row}[6]);
                $irc->yield(privmsg => $chan => $line);
	}

    }

}
