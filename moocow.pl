#!/usr/bin/perl

use strict;
use warnings;
use POE qw(Component::IRC Component::IRC::State Component::IRC::Plugin::AutoJoin Component::IRC::Plugin::Connector Component::IRC::Plugin::NickReclaim Component::IRC::Plugin::CTCP Component::Client::HTTP);
use Getopt::Std;
use JSON::Any;
use DBI;
use POSIX;
use Config::Any;
use Config::Any::INI;
use Cache::FileCache;
use WWW::Wunderground::API;
use Data::Dumper;
use HTML::TableExtract;
use HTML::HeadParser;
use LWP::UserAgent::WithCache;
use IRC::Utils ':ALL';
use XML::RSS;
use LWP::Simple;
use Text::Aspell;
use Business::UPS;
use Regexp::Common qw/URI/;
use Fortune;
use File::stat;
use constant { MOOVER => q{$Id$} };

$Config::Any::INI::MAP_SECTION_SPACE_TO_NESTED_KEY = 0;

my %opts;
my $confpath = "moocow.config";

my %last_nhl;
my %last_gogl;
my %last_u2;

getopts( 'h:f:', \%opts );

if ( exists( $opts{f} ) ) {
    $confpath = $opts{f};
}

parseconfig($confpath);

my $nickname  = readconfig('nickname');
my $ircname   = readconfig('ircname');
my $server    = readconfig('server');
my $port      = readconfig('port');
my $usessl    = readconfig('usessl');
my $trigger   = readconfig('trigger');
my $dbpath    = readconfig('dbpath');
my $autourl   = readconfig('autourl');
my $master    = readconfig('master');
my $banexpire = readconfig('banexpire');
my $FORTUNE_DIR = readconfig('fortunedir');


# for WORD game
my $word_on  = 0;     # !word game
my $word_ans = "";    # the actual answer
my %wordppl;          # everyone who tries for score keeping
my $word_s = "";

#for TRIVIA game
my $trivia_on      = 0;
my $trivia_ans     = "";
my $trivia_timeout = 60;
my $trivia_chan    = "";

#for TIMEBOMB Game
my $tb_on      = 0;
my $tb_ans     = "";
my $tb_target  = "";
my $tb_timeout = 10;
my $tb_chan    = "";
my $tb_sender  = "";

# sub-routines
sub say($$);
sub word(@);
sub hack(@);

sub trivia(@);

if ( $autourl =~ /(true|1|yes)/ ) {
    $autourl = 1;
}
else {
    $autourl = 0;
}

my %chans;
my $autojoin;

#foreach my $c ( split( ',', $channels ) ) {
#    my ( $chan, $key ) = split( / /, $c );
#    $key = "" if ( !defined($key) );
#    $chans{$chan} = $key;
#}

my $q = q{SELECT channame, chankey FROM channel};

my $dbh = DBI->connect("dbi:SQLite:$dbpath")
  || die "Cannot connect: $DBI::errstr";

my $sth = $dbh->prepare($q)
  || die "Error: cannot get channel list " . $dbh->errstr;
$sth->execute() || die "Error: cannot get channel list " . $sth->errstr;

my $chanref = $dbh->selectall_hashref( $q, 'channame' );
foreach my $q ( keys(%$chanref) ) {
    my $key = $chanref->{$q}->{'chankey'};
    $key = "" if ( !defined($key) );
    $chans{$q} = $key;
}

my $irc = POE::Component::IRC::State->spawn(
    nick    => $nickname,
    ircname => $ircname,
    server  => $server,
    Port    => $port,
    UseSSL  => $usessl,
    Debug   => 1,
    Flood   => 0,
) or die "Oh noooo! $!";

POE::Component::Client::HTTP->spawn(	Alias => 'http_ua', 
                                        Agent     => 'Mozilla/4.0 (compatible; MSIE 7.0; Windows NT 6.0)', 
                                        Protocol  => 'HTTP/1.1',
                                        Timeout	  => 5,
                                        );

my %cmd_hash;

$cmd_hash{"flip"}      = sub { coinflip(@_); };
$cmd_hash{"joke"}      = sub { random_joke(@_); };
$cmd_hash{"fortune"}   = sub { random_fortune(@_); };
$cmd_hash{"entertain"} = sub { entertain(@_); };
$cmd_hash{"quote"}     = sub { quote(@_); };
$cmd_hash{"addquote"}  = sub { addquote(@_); };
$cmd_hash{"moo"}       = sub { moo(@_); };
$cmd_hash{"tu"}        = sub { gogl_title(@_); };
$cmd_hash{"u2"}        = sub { youtube(@_); };
$cmd_hash{"help"}      = sub { help(@_); };
$cmd_hash{"codeword"}  = sub { codeword(@_); };
$cmd_hash{"wz"}        = sub { weather_extended(@_); };
$cmd_hash{"wzd"}       = sub { weather_default(@_); };
$cmd_hash{"nhl"}       = sub { nhl_standings(@_); };
$cmd_hash{"words"}     = sub { word(@_); };
$cmd_hash{"hack"}      = sub { hack(@_); };
$cmd_hash{"spell"}     = sub { spell(@_); };
$cmd_hash{"start"}     = sub { start_trivia(@_); };
$cmd_hash{"stop"}      = sub { stop_trivia(@_); };
$cmd_hash{"tscore"}    = sub { trivia_score(@_); };
$cmd_hash{"tb"}        = sub { start_timebomb(@_); };
$cmd_hash{"cut"}       = sub { cut_timebomb(@_); };
$cmd_hash{"track"}     = sub { track_package(@_); };
$cmd_hash{"tr"}        = sub { track_package(@_); };
$cmd_hash{"google"}    = sub { google(@_); };

my %pmsg_cmd_hash;

$pmsg_cmd_hash{"help"}      = sub { help(@_); };
$pmsg_cmd_hash{"adduser"}   = sub { add_user(@_); };
$pmsg_cmd_hash{"deluser"}   = sub { del_user(@_); };
$pmsg_cmd_hash{"checkuser"} = sub { check_user(@_); };

$pmsg_cmd_hash{"addrss"}       = sub { addrss(@_); };
$pmsg_cmd_hash{"getrss"}       = sub { getrss(@_); };
$pmsg_cmd_hash{"listrss"}      = sub { listrss(@_); };
$pmsg_cmd_hash{"deleterss"}    = sub { deleterss(@_); };
$pmsg_cmd_hash{"addchan"}      = sub { addchan(@_); };
$pmsg_cmd_hash{"add_chanuser"} = sub { add_chanuser(@_); };
$pmsg_cmd_hash{"delchan"}      = sub { delchan(@_); };
$pmsg_cmd_hash{"listchan"}     = sub { listchan(@_); };

$pmsg_cmd_hash{"moduser"}       = sub { mod_user(@_); };
$pmsg_cmd_hash{"listusers"}     = sub { list_users(@_); };
$pmsg_cmd_hash{"mod_chanuser"}  = sub { mod_chanuser(@_); };
$pmsg_cmd_hash{"list_chanuser"} = sub { list_chanuser(@_); };
$pmsg_cmd_hash{"del_chanuser"}  = sub { del_chanuser(@_); };
$pmsg_cmd_hash{"listmask"}      = sub { listmask(@_); };
$pmsg_cmd_hash{"addmask"}       = sub { addmask(@_); };
$pmsg_cmd_hash{"delmask"}       = sub { delmask(@_); };

my %codewords;
$codewords{'pink-ribbons'} = { kickee => 'jchawk',   reason => 'PINK RIBBONS!' };
$codewords{'slacker'}      = { kickee => 'ktuli',    reason => 'SLACKER!' };
$codewords{'dirtbag'}      = { kickee => 'noghri',   reason => 'DIRTBAG!' };
$codewords{'wonderbread'}  = { kickee => 'tonjy',    reason => 'WONDERBREAD!!!' };
$codewords{'dongs'}        = { kickee => 'AndroSyn', reason => 'DONGS!!!' };
$codewords{'fired'}        = { kickee => 'genetik',  reason => 'Call the burn unit, \'cause you\'re FIRED!!!' };

POE::Session->create(
    package_states => [ main => [qw(_default _start irc_001 irc_public irc_msg irc_ctcp_version irc_nick_sync)], ],
    inline_states  => {
        ban_expire      => sub { ban_expire(@_); },
        trivia_expire   => sub { trivia_expire(@_); },
        timebomb_expire => sub { timebomb_expire(@_); },
        rss_timer       => sub { rss_timer(@_); }
    },
    heap => { irc => $irc },
);

$poe_kernel->run();

sub _start {
    my $heap   = $_[HEAP];
    my $kernel = $_[KERNEL];

    # retrieve our component's object from the heap where we stashed it
    my $irc = $heap->{irc};
    $autojoin = $irc->plugin_add( 'AutoJoin', POE::Component::IRC::Plugin::AutoJoin->new( Channels => \%chans, RejoinOnKick => 1 ) );
    $irc->plugin_add(
        'Connector',
        POE::Component::IRC::Plugin::Connector->new(
            delay     => 60,
            reconnect => 5
        )
    );
    $irc->plugin_add( 'NickReclaim', POE::Component::IRC::Plugin::NickReclaim->new( poll => 30 ) );
    $irc->plugin_add(
        'CTCP',
        POE::Component::IRC::Plugin::CTCP->new(
            version    => "moocow " . MOOVER . " - its perl!",
            userinfo   => "I am a cow, not a user!",
            clientinfo => "moocow - its perl!",
            source     => "grass"
        )
    );

    $kernel->delay( 'ban_expire', 60 );
    $kernel->delay( 'rss_timer',  900 );
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

sub ban_expire {

    my ( $kernel, $umask, $channel ) = @_[ KERNEL, ARG0, ARG1 ];

    for my $channel ( keys %{ $irc->channels() } ) {
        if ( $banexpire > 0 ) {
            my $banlist = $irc->channel_ban_list($channel);
            foreach my $q ( keys( %{$banlist} ) ) {
                my $tm      = time();
                my $bantime = $tm - $banlist->{$q}->{'SetAt'};
                if ( $bantime > $banexpire ) {
                    $irc->yield( mode => $channel => "-b $q" );
                }
            }

        }
    }

    $kernel->delay( 'ban_expire', 60 );

    return;

}

sub irc_nick_sync {

    my ( $nick, $channel ) = @_[ ARG0, ARG1 ];

    my $acl = chan_acl( $nick, $channel );
    my $uacl = acl($nick);

    return if ( !defined($acl) );

    return if ( !defined( $acl->{'access'} ) );

    if ( ( $acl->{'access'} eq "A" ) || ( $acl->{'access'} eq "O" ) ) {
        $irc->yield( mode => $channel => "+o $nick" );
    }
    elsif ( $acl->{'access'} eq "V" ) {
        $irc->yield( mode => $channel => "+v $nick" );
    }
    elsif ( $acl->{'access'} eq "B" ) {
        $irc->yield( mode => $channel => "+b $uacl->{'hostmask'}" );
        $irc->yield( kick => $channel => "$nick" );
    }

    return;

}

sub irc_msg {
    my ( $sender, $who, $where, $what ) = @_[ SENDER, ARG0 .. ARG2 ];
    my ( $nick, $user, $host ) = parse_user($who);

    return if ( $what !~ /^$trigger(.*)/ );
    my @cmd = split / +/, $1;
    chomp(@cmd);
    my $cmd = shift @cmd;
    my $cmdargs = join( " ", @cmd );
    if ( exists $pmsg_cmd_hash{$cmd} ) {
        $pmsg_cmd_hash{$cmd}->( $cmdargs, $nick, $nick, $who );
    }
}

sub irc_public {
    my ( $kernel, $sender, $who, $where, $what ) = @_[ KERNEL, SENDER, ARG0 .. ARG2 ];
    my $nick = ( split /!/, $who )[0];
    my $channel = $where->[0];

    # for the !word game
    if ( $word_on && $what eq $word_ans ) {    # !word game
        $irc->yield( privmsg => $where->[0] => "That's right! :D" );
        my $whop = $who;
        $whop =~ s/!.*//;
        $wordppl{$whop} = ( $wordppl{$whop} + 1 );
        $word_ans       = "";
        $word_s         = "";
        $word_on        = 0;
    }

    if ( $trivia_on && $what eq $trivia_ans ) {
        $irc->yield( privmsg => $channel => "Correct!!  $nick got that! The answer was $trivia_ans" );
        $trivia_on  = 0;
        $trivia_ans = "";
        score_trivia($nick);
    }

    # these techenically will catch the !tu !u2 urls, but the end result is the same for autourl
    if ($autourl) {
        if ( $what =~ /$RE{URI}{HTTP}{-scheme=>'https?'}{-keep}/ ) {
            my $url  = $1;
            my $host = $3;
            if ( $host =~ /^(www\.youtube\.com|youtube\.com|youtu\.be)$/ ) {
                youtube( $url, $channel, $nick, $who );
            }
            else {
                gogl_title( $url, $channel, $nick, $who );
            }
            return;
        }
    }

    return if ( $what !~ /^$trigger(.*)/ );

    my @cmd = split / +/, $1;
    chomp(@cmd);
    my $cmd = shift @cmd;
    my $cmdargs = join( " ", @cmd );
    if ( exists $cmd_hash{$cmd} ) {
        $cmd_hash{$cmd}->( $cmdargs, $channel, $nick, $who, $kernel );
    }

    return;
}

sub irc_ctcp_version {
    my ( $sender, $who, $where, $what ) = @_[ SENDER, ARG0 .. ARG2 ];
    $who =~ s/^(.*)!.*$/$1/ or die "Weird who: $who";
    $irc->yield( ctcp => $who => "VERSION moocow " . MOOVER . " - its perl!" );
    return;
}

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
        if ( !$sth ) {
            $irc->yield( privmsg => $channel => "Error looking up quote: " . $dbh->errstr );
            return;
        }
        $sth->bind_param( 1, $channel );
    }

    my $rv = $sth->execute();

    if ( !$rv ) {
        $irc->yield( privmsg => $channel => "Error reading quote: " . $sth->errstr );
        return;
    }

    my $count = 0;
    while ( defined( my $res = $sth->fetchrow_hashref ) ) {

        my $qt = $res->{'quote'};
        my $um = parse_user( $res->{'usermask'} );
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
    my $who     = $prams[3];

    my $query = 'INSERT INTO quotes(quote, usermask, channel, timestamp) VALUES (?, ?, LOWER(?), strftime(\'%s\',\'now\'))';
    my $sth   = $dbh->prepare($query);
    if ( !$sth ) {
        $irc->yield( privmsg => $channel => "Error inserting quote: " . $dbh->errstr );
        return;
    }
    $sth->bind_param( 1, $quote );
    $sth->bind_param( 2, $who );
    $sth->bind_param( 3, $channel );

    #DBI::dump_results($sth);
    my $rv = $sth->execute();
    if ( !$rv ) {
        $irc->yield( privmsg => $channel => "Error inserting quote: " . $sth->errstr );
    }
    else {
        if ( $sth->rows > 0 ) {
            $irc->yield( privmsg => $channel => "Quote has been added, fool!" );
        }
    }
}

sub weather_default {

    my @prams = @_;
    my $zip   = $prams[0];
    my $chan  = $prams[1];
    my $nick  = $prams[2];
    my $who   = $prams[3];
    my $nacl  = acl( $nick, $who );

    if ( !defined($nacl) ) {
        $irc->yield( privmsg => $chan => "No Access!" );
        return;
    }

    if ( $zip eq "" ) { return }

    my $query = q{UPDATE users set wzdefault = ? where username = (SELECT username FROM users,usermask WHERE usermask.userid == users.userid AND ? GLOB usermask.hostmask)};

    my $sth = $dbh->prepare($query);
    if ( !$sth ) {
        $irc->yield( privmsg => $chan => "Error updating default: " . $dbh->errstr );
        return;
    }
    $sth->bind_param( 1, $zip );
    $sth->bind_param( 2, $who );

    #DBI::dump_results($sth);
    my $rv = $sth->execute();
    if ( !$rv ) {
        $irc->yield( privmsg => $chan => "Error updating default: " . $sth->errstr );
    }
    else {
        if ( $sth->rows > 0 ) {
            $irc->yield( privmsg => $chan => "Default updated." );
        }

    }

}

sub weather_extended {
    my @prams  = @_;
    my $zip    = $prams[0];
    my $chan   = $prams[1];
    my $nick   = $prams[2];
    my $who    = $prams[3];
    my $apikey = readconfig('apikey');

    if ( $zip eq "" ) {
        if ( !acl( $nick, $who ) ) {
            $irc->yield( notice => $nick => "Must be a user to set default weather" );
            return;
        }

        my $query = q{SELECT wzdefault FROM users, usermask WHERE username = (SELECT username WHERE usermask.userid == users.userid AND ? GLOB usermask.hostmask)};

        my $sth = $dbh->prepare($query);
        if ( !$sth ) {
            $irc->yield( privmsg => $chan => "Unable to check default location: " . $dbh->errstr );
            return;
        }
        $sth->bind_param( 1, $who );
        my $rv = $sth->execute();
        if ( !$rv ) {
            $irc->yield( privmsg => $chan => "Unable to check default location: " . $sth->errstr );
        }
        else {
            if ( defined( my $res = $sth->fetchrow_hashref ) ) {
                $zip = $res->{'wzdefault'};
            }
        }

    }

    if ( !defined($zip) ) {
        $irc->yield( notice => $nick => "No default set; use wzd to set" );
        return;
    }

    my $wun; 
    eval {
    $wun = new WWW::Wunderground::API(
        location => $zip,
        api_key  => $apikey,
        auto_api => 1,
        cache    => Cache::FileCache->new( { namespace => 'moocow_wundercache', default_expires_in => 2400 } ));
    };
    if(!defined($wun)) {
        $irc->yield( privmsg => $chan => "No results: wunderground api failed");
        return;
    }
    if ( $wun->response->error->description ) {
        $irc->yield( privmsg => $chan => "No results: " . $wun->response->error->description );
        return;
    }

    if ( $wun->response->results ) {
        $irc->yield( privmsg => $chan => "Too many results for location $zip" );
        return;
    }

    my $cond    = $wun->conditions;
    my $updated = $cond->observation_time;
    $updated =~ s/Last Updated on //;
    if(!defined($cond->display_location))
    {
        $irc->yield( privmsg => $chan => "Invalid location");
        return;
    }
    my $location = $cond->display_location->city;
    my $weather  = $cond->weather;
    my $temp     = $cond->temperature_string;
    my $feels    = $cond->feelslike_string;
    my $uv       = $cond->UV;
    my $humid    = $cond->relative_humidity;
    my $pressin  = $cond->pressure_in;
    my $pressmb  = $cond->pressure_mb;
    my $wind     = $cond->wind_string;
    $wind =~ s/From the //;
    my $dew      = $cond->dewpoint_string;
    my $precip   = $cond->precip_today_string;
    my $forecast = $wun->forecast->txt_forecast->forecastday->[0]{fcttext};

    #Harpers Ferry, WV; Updated: 3:00 PM EDT on October 17, 2013; Conditions: Overcast; Temperature: 71.2°F (21.8°C); UV: 1/16 Humidity: 75%; Pressure: 29.79 in/2054 hPa (Falling); Wind: SSE at 5.0 MPH (8 KPH)
    $irc->yield( privmsg => $chan =>
"WX $location Updated: \x02$updated\x02 Conditions: \x02$weather\x02: Temp: \x02$temp\x02 Feels like: \x02$feels\x02 Dewpoint: \x02$dew\x02 UV: \x02$uv\x02 Humidity: \x02$humid:\x02 Pressure: \x02${pressin}/in/${pressmb}\x02 MB Wind: \x02$wind\x02 Precip:\x02 $precip\x02"
    );
    $irc->yield( privmsg => $chan => "$forecast" );

    #    my $resp = $wun->r->full_location . "Updated: $obs"
    return;

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

sub random_joke {
    my @prams   = @_;
    my $channel = $prams[1];

    my $rssurl = "http://www.jokesareawesome.com/rss/random/";
    my $xml = get($rssurl);
    my $rss = new XML::RSS;
    $rss->parse($xml);
    foreach my $item ( @{ $rss->{'items'} } ) {
        my $title = $item->{'title'};
        my $content  = $item->{'content'}->{'encoded'};
        $irc->yield( privmsg => $channel => "$content" );
    }
}

sub random_fortune {
    my @prams   = @_;
    my $channel = $prams[1];


    opendir(my $fortune_opendir, $FORTUNE_DIR) || return;
    my @fortune_list = grep { !/\.dat$/ && -f "$FORTUNE_DIR/$_" } readdir($fortune_opendir);

    my $fortune_filename = $FORTUNE_DIR . "/" . $fortune_list[rand($#fortune_list)];
    my $fortune_file = new Fortune ($fortune_filename);
    $fortune_file->read_header();
    my $random_fortune = $fortune_file->get_random_fortune();

    my @fortune_lines = split(/\n/, $random_fortune);
    foreach my $line (@fortune_lines) {
      $irc->yield( privmsg => $channel => "$line" );
    }
}

sub spell {
    my @prams   = @_;
    my $channel = $prams[1];

    my @args    = split / /, $prams[0];
    my $word    = $args[0];
    my $speller = Text::Aspell->new;
    die unless $speller;

    $speller->set_option( 'lang',     'en_US' );
    $speller->set_option( 'sug-mode', 'fast' );

    if ( $speller->check($word) ) {
        $irc->yield( privmsg => $channel => "$word is spelled correctly" );
    }
    else {
        my @suggestions = $speller->suggest($word);
        $irc->yield( privmsg => $channel => "word is mispelled." );
        $irc->yield( privmsg => $channel => "suggestions: " . join( ' ', @suggestions ) );
    }
}

sub codeword {
    my @prams    = @_;
    my $codeword = $prams[0];
    my $channel  = $prams[1];
    my $kickee   = $prams[2];
    my $kickres  = "Don't try to make up codewords!";

    return if ( !eq_irc( $channel, "#threerivers" ) );

    if ( defined( $codewords{$codeword} ) ) {
        $kickee  = $codewords{"$codeword"}->{'kickee'};
        $kickres = $codewords{"$codeword"}->{'reason'};
    }

    if ( !$irc->is_channel_member( $channel, $kickee ) ) {
        $kickee  = $prams[2];
        $kickres = "Misfire!";
    }

    $irc->yield( privmsg => $channel => "EEP!!!" );
    $irc->yield( kick => $channel => $kickee => $kickres );
}

sub entertain {
    my @prams   = @_;
    my $channel = $prams[1];

    if ( !$irc->is_channel_member( $channel, "KtuLi" ) ) {
        $irc->yield( ctcp => $channel => "ACTION sends a zombie to track down KtuLi and punch him in the throat" );
    }
    else {
        $irc->yield( ctcp => $channel => "ACTION punches KtuLi in the throat." );
    }
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
    $ini = Config::Any::INI->load($path)
      || die("Unable to parse config file $path: $!");
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

sub gogl_got_response {
    my ( $heap, $kernel, $request_packet, $response_packet ) = @_[ HEAP, KERNEL, ARG0, ARG1 ];
    my $http_request = $request_packet->[0];
    my $data = $request_packet->[1];
    
    my ( $requrl, $channel, $settitle ) = ($data->{'url'}, $data->{'channel'}, $data->{'settitle'});
    my $http_response = $response_packet->[0];

    return if ( $http_response->code != 200 );
    
    my $j = JSON::Any->new;
    my $d = $j->decode($http_response->content);

    my $url = $d->{'id'};
    return if ( !defined($url) );
    $irc->yield( privmsg => $channel, $url );
    title( $requrl, $channel ) if ( defined($requrl) && $settitle == 1 );
}

sub title_got_response {
    my ( $heap, $kernel, $request_packet, $response_packet ) = @_[ HEAP, KERNEL, ARG0, ARG1 ];
    my $http_request  = $request_packet->[0];
    my $channel       = $request_packet->[1];
    my $http_response = $response_packet->[0];

    return if ( $http_response->code != 200 );

    return undef if ( !defined($http_response) );
    my $ctype = $http_response->header('Content-type');

    return undef if ( !( $ctype =~ /text\/(html|xhtml)/ ) );

    my $p = HTML::HeadParser->new;
    $p->parse( $http_response->content );
    my $title = $p->header('Title');
    $irc->yield( privmsg => $channel, $title ) if ( defined($title) );
}

sub gogl_title {
    my ( $url, $channel, $nick, $who ) = @_;
    gogl( $url, $channel, 1 );
}

sub gogl {
    my @args = my ( $url, $channel, $settitle ) = @_;

    #    my @args = ($url, $channel, $settitle);
    return if ( defined( $last_gogl{$channel} ) && $last_gogl{$channel} > ( time() - 30 ) );
    $last_gogl{$channel} = time();

    my $goglurl = "https://www.googleapis.com/urlshortener/v1/url";

    my $req = HTTP::Request->new( POST => $goglurl );
    $req->content_type('application/json');
    $req->content("{\"longUrl\": \"$url\"}");
    POE::Session->create(
        inline_states => {
            _start => sub {
                my ( $kernel, $heap ) = @_[ KERNEL, HEAP ];
                $kernel->post( 'http_ua' => 'request' => got_response => $req => {url => $url, channel => $channel, settitle => $settitle });
            },
            got_response => sub { gogl_got_response(@_); }
        }
    );
}

sub title {
    my @prams   = @_;
    my $url     = $prams[0];
    my $channel = $prams[1];
    my $req     = HTTP::Request->new( GET => $url );

    return undef if ( !defined($req) );
    POE::Session->create(
        inline_states => {
            _start => sub {
                my ( $kernel, $heap ) = @_[ KERNEL, HEAP ];
                $kernel->post( 'http_ua' => 'request' => got_response => $req => $channel ),;
            },
            got_response => sub { title_got_response(@_); }
        }
    );
}

sub youtube_got_response {
    my ( $heap, $kernel, $request_packet, $response_packet ) = @_[ HEAP, KERNEL, ARG0, ARG1 ];
    my $http_request = $request_packet->[0];
    my ( $channel, $url ) = @{ $request_packet->[1] };
    my $http_response = $response_packet->[0];

    return if ( $http_response->code != 200 );

    return undef if ( !defined($http_response) );
    my $ctype = $http_response->header('Content-type');
    return undef if ( !( $ctype =~ /application\/json/ ) );

    my $j  = JSON::Any->new;
    my $yt = $j->decode( $http_response->content );
    $yt = $yt->{'entry'};
    my $line = "YouTube: \x02 " . $yt->{'title'}{'$t'} . "\x02 Duration: \x02" . $yt->{'media$group'}{'yt$duration'}{'seconds'} . "\x02 seconds Views: \x02" . $yt->{'yt$statistics'}{'viewCount'} . "\x02";
    $irc->yield( privmsg => $channel, $line );
    gogl( $url, $channel, 0 );
}

sub youtube {
    my ( $url, $channel, $nick, $who ) = @_;
    return if ( defined( $last_u2{$channel} ) && $last_u2{$channel} > ( time() - 30 ) );
    $last_u2{$channel} = time();

    my $u2 = $5 if ( $url =~ m/^.*youtu(\.)?be(\.com\/watch\?)(feature=player_detailpage\&)?(v=|\/)(.*)/i );

    my $query = "http://gdata.youtube.com/feeds/api/videos/${u2}?strict=true&alt=json&prettyprint=false&v=2";
    my $req = HTTP::Request->new( GET => $query );

    return undef if ( !defined($req) );
    POE::Session->create(
        inline_states => {
            _start => sub {
                my ( $kernel, $heap ) = @_[ KERNEL, HEAP ];
                my @args = ( $channel, $url );
                $kernel->post( 'http_ua' => 'request' => got_response => $req => \@args ),;
            },
            got_response => sub { youtube_got_response(@_); }
        }
    );
}

sub say($$) {    # just to minimize typing
    $irc->yield( privmsg => $_[0] => $_[1] );    # needs to be changed to $channel
    return;
}

sub word(@) {                                    # !word game
    $wordppl{ $_[2] } = 0 if ( !exists( $wordppl{ $_[2] } ) );
    if ( $_[0] eq "reset" ) {                    # because there is no timer function
        say( $_[1], "the word has been reset by " . $_[2] . " answer was: " . $word_ans );
        $word_on  = 0;
        $word_ans = "";
        return;
    }
    elsif ( $_[0] =~ m/^score(s)?/ ) {           # show your score
        my $scores = "";
        while ( my ( $k, $v ) = each(%wordppl) ) {
            $scores .= $k . ": " . $v . ", ";
        }
        $scores =~ s/, $//;
        say( $_[1], $scores );
        return;
    }
    elsif ($word_on) {                           # boolean
        say( $_[1], "the game is already running with word: (" . $word_s . "), try \"!word reset\" to start over" );
        return;
    }
    else {
        my $no = int( rand(`wc -l /home/trevelyn/words.txt | awk '{print \$1}'`) );
        $word_ans = `sed '$no q;d' /home/trevelyn/words.txt`;
        chomp $word_ans;                         # answer
        my @word = split( //, $word_ans );
        my $sw   = "";                           # scrambled word
        until ( $#word == -1 ) {
            my $rn = int( rand($#word) );
            $sw .= $word[$rn];
            splice( @word, $rn, 1 );
        }
        $word_s = $sw;
        say( $_[1], $sw );
        $word_on = 1;
    }
    return;
}

sub hack(@) {
    say( $_[1], "hack the planet!" );
}

sub help {

    my @prams = @_;
    my $chan  = $prams[1];
    my $nick  = $prams[2];
    my $who   = $prams[3];
    $irc->yield( notice => $nick => "!tu <url>: Shorten a url" );
    $irc->yield( notice => $nick => "!u2 <url>: youtube info" );
    $irc->yield( notice => $nick => "!flip: coin flip" );
    $irc->yield( notice => $nick => "!wz <zip>: Weather for zip" );
    $irc->yield( notice => $nick => "!wzd <zip>: Adds default weather zip." );
    $irc->yield( notice => $nick => "!entertain: Massive entertainment." );
    $irc->yield( notice => $nick => "!codeword <codeword>: Special codeword actions." );
    $irc->yield( notice => $nick => "!quote: Display random quote" );
    $irc->yield( notice => $nick => "!addquote <quote>: add a new quote" );
    $irc->yield( notice => $nick => "!nhl <division|conference|stat|help>: nhl standings and stats" );
    $irc->yield( notice => $nick => "!word: word scramble game" );
    $irc->yield( notice => $nick => "!moo: moo." );
    $irc->yield( notice => $nick => "!addrss <rssurl>: add rss feed." );
    $irc->yield( notice => $nick => "!getrss: Get rss feed." );
    $irc->yield( notice => $nick => "!start: start trivia game." );
    $irc->yield( notice => $nick => "!score: trivia scores." );

    my $nacl = acl( $nick, $who );

    if ( !defined($nacl) || $nacl->{'access'} ne "A" ) {
        return;
    }

    $irc->yield( notice => $nick => "Admin Commands: (all privmsg)" );
    $irc->yield( notice => $nick => "!adduser <nickname> <hostmask> <acl>" );
    $irc->yield( notice => $nick => "!deluser <nickname>" );
    $irc->yield( notice => $nick => "!moduser <nickname> <acl>" );
    $irc->yield( notice => $nick => "!add_chanuser <channel> <nickname> <acl>" );
    $irc->yield( notice => $nick => "!checkuser <ircname>" );
    $irc->yield( notice => $nick => "!addchan <channel>" );
    $irc->yield( notice => $nick => "!listusers" );
    $irc->yield( notice => $nick => "!mod_chanuser <channel> <nickname> <acl>" );
    $irc->yield( notice => $nick => "!list_chanuser <channel>" );
    $irc->yield( notice => $nick => "!del_chanuser <channel> <nickname>" );

}

sub nhl_standings_response {
    my ( $heap, $kernel, $request_packet, $response_packet ) = @_[ HEAP, KERNEL, ARG0, ARG1 ];
    my $http_request  = $request_packet->[0];
    my $data       = $request_packet->[1];
    my $http_response = $response_packet->[0];

    my $channel = $data->{'channel'};
    my $division = $data->{'division'};

    return if ( $http_response->code != 200 );

    return undef if ( !defined($http_response) );

    my $conference;
    my @div_list;
    if ($division eq "eastern") {
      $conference = $division;
      @div_list = ('atlantic','metropolitan','wild card');
    } elsif ($division eq "western") {
      $conference = $division;
      @div_list = ('central','pacific','wild card');
    } else {
      $conference = "";
      @div_list = ($division);
    }

    my $first_wc = 0;
    my $print_wc = 0;
    foreach my $division (@div_list) {
      my @headers = ( "$division", 'GP', 'W', 'L', '.+', 'ROW' );

      my $te = HTML::TableExtract->new(
          debug     => 0,
          subtables => 0,
          automap   => 0,
          headers   => [@headers]
      ) || die("Unable create object: $!");
  
      $te->parse( $http_response->content ) || die("Error: $!");
      my $format = q{%-12s %-20s %-3s %-3s %-3s %-3s %-3s %-4s};
      my $header = sprintf( $format, "$division", "Team", "GP", "W", "L", "OTL", "P", "ROW" );
  
      foreach my $ts ( $te->tables ) {
          if (($conference eq "eastern") && ($division eq "wild card") && ($first_wc == 0)) {
            $first_wc++;
            $print_wc = 1;
          } elsif (($conference eq "western") && ($division eq "wild card") && ($first_wc > 0)) {
            $first_wc++;
            $print_wc = 1;
          } elsif ($division eq "wild card") {
            $print_wc = 0;
          }
          if (($division eq "wild card") && ($print_wc != 1)) {
            $first_wc++;
            next;
          }
          $irc->yield( privmsg => $channel => $header );
          my $line_count = 0;
          foreach my $row ( $ts->rows ) {
              if (($division eq "wild card") && ($line_count >= 4)) {
                last;
              }
              chomp(@$row);
              my $team = @{$row}[1];
              $team =~ s/\n//g;
              my $line = sprintf( $format, @{$row}[0], $team, @{$row}[2], @{$row}[3], @{$row}[4], @{$row}[5], @{$row}[6], @{$row}[7] );
              $irc->yield( privmsg => $channel => $line );
              $line_count++;
          }
  
      }
    }
}

sub nhl_leaderboard_response {
    my ( $heap, $kernel, $request_packet, $response_packet ) = @_[ HEAP, KERNEL, ARG0, ARG1 ];
    my $http_request  = $request_packet->[0];
    my $data       = $request_packet->[1];
    my $http_response = $response_packet->[0];

    my $channel = $data->{'channel'};
    my $request = $data->{'request'};
    $request = uc($request);
    $request = "PLUS/MINUS" if ( $request eq "PLUSMINUS" );
    $request = "SAVE PERCENTAGE" if ( $request eq "SAVEPERCENTAGE" );
    $request = "GAA" if ( $request eq "GOALSAGAINSTAVERAGE" );

    return if ( $http_response->code != 200 );

    return undef if ( !defined($http_response) );

    my @headers = ( 'RANK', 'PLAYER', 'TEAM', $request );

    my $te = HTML::TableExtract->new(
        debug     => 0,
        subtables => 0,
        automap   => 0,
        headers   => [@headers]
    ) || die("Unable create object: $!");
  
    $te->parse( $http_response->content ) || die("Error: $!");
    my $format = q{%-4s %-20s %-8s %-8s};
    my $header = sprintf( $format, "RANK", "PLAYER", "TEAM", $request );
  
    foreach my $ts ( $te->tables ) {
        my $line_count = 0;
        foreach my $row ( $ts->rows ) {
            if ($line_count >= 5) {
              last;
            }
            chomp(@$row);
            my $rank   = @{$row}[0]; $rank   =~ s/\n//g;
            my $player = @{$row}[1]; $player =~ s/\n//g;
            my $team   = @{$row}[2]; $team   =~ s/\n//g;
            my $value  = @{$row}[3]; $value  =~ s/\n//g;
            my $line = sprintf( $format, $rank, $player, $team, $value );
            $irc->yield( privmsg => $channel => $line );
            $line_count++;
        }
    }
}

sub nhl_standings {

    my @prams    = @_;
    my $request  = $prams[0];
    my $chan     = $prams[1];
    my $nick     = $prams[2];

    return if ( defined( $last_nhl{$chan}{$nick} ) && $last_nhl{$chan}{$nick} > ( time() - 60 ) );
    if ( $request eq "" ) {
        $irc->yield( notice => $nick => "Usage: !nhl <division|conference|stat|help>" );
        return;
    }
    $last_nhl{$chan}{$nick} = time();


    $request = lc($request);
    $request = "metropolitan" if ( $request eq "patrick" );
    $request = "eastern" if ( $request eq "east" );
    $request = "western" if ( $request eq "west" );
    $request = "plusMinus" if ($request eq "plusminus" );
    $request = "plusMinus" if ($request eq "+-" );
    $request = "plusMinus" if ($request eq "+/-" );
    $request = "savePercentage" if ($request eq "save%" );
    $request = "savePercentage" if ($request eq "savepercentage" );
    $request = "goalsAgainstAverage" if ($request eq "gaa" );
    $request = "shutOuts" if ($request eq "shutouts" );

    if (   ( $request eq "atlantic" )
        || ( $request eq "pacific" )
        || ( $request eq "central" )
        || ( $request eq "metropolitan" )
        || ( $request eq "eastern" ) 
        || ( $request eq "western" ) )
    {
        my $division = $request;

        my $url = "";
        if ( ($division eq "eastern") || ($division eq "western") ) {
            $url = "http://www.nhl.com/ice/m_standings.htm?type=WC";
        } else {
            $url = "http://www.nhl.com/ice/m_standings.htm?type=DIV";
        }

        my $req = HTTP::Request->new( GET => $url );
    
        POE::Session->create(
            inline_states => {
                _start => sub {
                    my ( $kernel, $heap ) = @_[ KERNEL, HEAP ];
                    $kernel->post( 'http_ua' => 'request' => got_response => $req => { channel => $chan, division => $division } );
                },
                got_response => sub { nhl_standings_response(@_); }
            }
        );
    } elsif (   ( $request eq "goals" )
             || ( $request eq "assists") 
             || ( $request eq "points" )
             || ( $request eq "plusMinus" )
             || ( $request eq "savePercentage" )
             || ( $request eq "goalsAgainstAverage" )
             || ( $request eq "shutOuts" )
             || ( $request eq "wins" ) )
    {
        my $url = "http://www.nhl.com/ice/m_statslist.htm?view=" . $request;

        my $req = HTTP::Request->new( GET => $url );

        POE::Session->create(
            inline_states => {
                _start => sub {
                    my ( $kernel, $heap ) = @_[ KERNEL, HEAP ];
                    $kernel->post( 'http_ua' => 'request' => got_response => $req => { channel => $chan, request => $request } );
                },
                got_response => sub { nhl_leaderboard_response(@_); }
            }
        );
    } elsif ( $request eq "help" ) {
        $irc->yield( notice => $nick => "Usage: !nhl <division|conference|stat|help>" );
        $irc->yield( notice => $nick => "          division   = metropolitan | atlantic | central | pacific ");
        $irc->yield( notice => $nick => "          conference = east | west" );
        $irc->yield( notice => $nick => "          stat       = points | goals | assists | +/- | save% | gaa | shutouts | wins" );
        $irc->yield( notice => $nick => "          help       = display this help message" );
    } else {
        $irc->yield( notice => $nick => "Usage: !nhl <division|conference|stat|help>" );
        return;
    }
}

sub delchan {
    my @prams = @_;
    my $who   = $prams[1];
    my $nick  = $prams[2];
    my $umask = $prams[3];

    my @args = split / /, $prams[0];

    my $nacl = acl( $nick, $umask );
    my $channel = $args[0];

    if ( !defined($nacl) || $nacl->{'access'} ne "A" ) {
        $irc->yield( notice => $who => "No Access!" );
        return;
    }
    if ( !defined($channel) || $channel eq "" ) {
        $irc->yield( notice => $who => "delchan #channame|ID" );
        return;
    }

    # first lookup the chanid...
    my $query = q{SELECT chanid FROM channel WHERE channame = ? OR chanid = ? };

    my $sth = $dbh->prepare($query);
    if ( !$sth ) { $irc->yield( privmsg => $who => "Error preparing statement for chanid lookup" ); return; }

    $sth->bind_param( 1, $args[0] );
    $sth->bind_param( 2, $args[1] );

    my $rv = $sth->execute();

    if ( !$rv ) {
        $irc->yield( privmsg => $who => "Error looking up channel: " . $sth->errstr );
        return;
    }

    my @arr = $sth->fetchrow_array();
    $sth->finish;

    if ( !@arr ) {
        $irc->yield( privmsg => $who => "Channel not found" );
        return;
    }

    my $chanid = $arr[0];

    $query = q{DELETE FROM chanuser WHERE chanid = ?};
    $dbh->begin_work;

    $sth = $dbh->prepare($query);

    if ( !$sth ) {
        $irc->yield( privmsg => $who => "Error preparing statement for delete: " . $dbh->errstr );
    }

    $sth->bind_param( 1, $chanid );
    $rv = $sth->execute();
    if ( !$rv ) {
        $dbh->rollback;
        $irc->yield( privmsg => $who => "Error deleting chanusers " . $sth->errstr );
        return;
    }

    # we don't check the number of rows deleted because we don't care if no users are left and zero are deleted
    $sth->finish;

    $query = q{DELETE FROM channel WHERE chanid = ? };

    $sth = $dbh->prepare($query);

    if ( !$sth ) {
        $irc->yield( privmsg => $who => "Error preparing statement for delete: " . $dbh->errstr );
    }

    $sth->bind_param( 1, $chanid );
    $sth->execute();

    if ( $sth->rows ) {
        $dbh->commit;
        $irc->yield( privmsg => $who => "Channel deleted" );
        delete $chans{$channel};
        $irc->plugin_del('AutoJoin');
        $autojoin = $irc->plugin_add( 'AutoJoin', POE::Component::IRC::Plugin::AutoJoin->new( Channels => \%chans, RejoinOnKick => 1 ) );
        $irc->yield( part => $channel );
    }
    else {
        $dbh->rollback;
        $irc->yield( privmsg => $who => "Unable to delete channel - not found?" );
    }

}

sub listchan {
    my @prams = @_;
    my $who   = $prams[1];
    my $nick  = $prams[2];
    my $umask = $prams[3];

    my $query = q{SELECT channame, username, chanid FROM channel, users WHERE channel.ownerid == users.userid};

    my $sth = $dbh->prepare($query);
    if ( !$sth ) {
        $irc->yield( privmsg => $who => "Error preparing statement: " . $dbh->errstr );
    }
    my $rv = $sth->execute();

    if ( !$rv ) {
        $irc->yield( privmsg => $who => "Error listing channels: " . $sth->errstr );
        return;
    }
    while ( defined( my $res = $sth->fetchrow_hashref ) ) {
        my ( $channame, $username, $chanid ) = ( $res->{'channame'}, $res->{'username'}, $res->{'chanid'} );

        $irc->yield( privmsg => $nick => "Channel: $channame Owner: $username ChanId: $chanid" );
    }
    if ( !$sth->rows ) {
        $irc->yield( privmsg => $nick => "No channels" );
    }

}

sub addchan {
    my @prams = @_;
    my $who   = $prams[1];
    my $nick  = $prams[2];
    my $umask = $prams[3];

    my @args = split / /, $prams[0];

    my $nacl    = acl( $nick, $umask );
    my $channel = $args[0];
    my $owner   = $args[1];
    my $key     = $args[2];
    if ( !defined($nacl) || $nacl->{'access'} ne "A" ) {
        $irc->yield( notice => $who => "No Access!" );
        return;
    }

    $key = '' if ( !defined($key) );

    my $query = q{INSERT INTO channel (channame, ownerid, chankey) VALUES (?,  (SELECT userid FROM users WHERE username = ?), ?) };

    my $sth = $dbh->prepare($query);
    if ( !$sth ) {
        $irc->yield( privmsg => $who => "Error preparing statement: " . $dbh->errstr );
    }
    $sth->bind_param( 1, $channel );
    $sth->bind_param( 2, $owner );
    $sth->bind_param( 3, $key );

    my $rv = $sth->execute();

    if ( !$rv ) {
        $irc->yield( privmsg => $who => "Error adding channel: " . $sth->errstr );
        return;
    }

    if ( $sth->rows > 0 ) {
        $irc->yield( privmsg => $who => "Added channel $channel with owner: $owner" );
        $chans{$channel} = $key;
        $irc->plugin_del('AutoJoin');
        $autojoin = $irc->plugin_add( 'AutoJoin', POE::Component::IRC::Plugin::AutoJoin->new( Channels => \%chans ) );
        $irc->yield( join => $channel => $key );
    }

}

sub add_chanuser {
    my @prams = @_;
    my $who   = $prams[1];
    my $nick  = $prams[2];
    my $umask = $prams[3];
    my @args  = split / /, $prams[0];

    my $nacl = acl( $nick, $umask );
    if ( !defined($nacl) || $nacl->{'access'} ne "A" ) {
        $irc->yield( notice => $who => "No Access!" );
        return;
    }

    my $channel = $args[0];
    my $user    = $args[1];
    my $access  = $args[2];

    my $query = q{INSERT INTO chanuser (chaccess, userid, chanid) VALUES (?, (SELECT userid FROM users WHERE username = ?), (SELECT chanid FROM channel WHERE channame = ?))};

    my $sth = $dbh->prepare($query);
    if ( !$sth ) {
        $irc->yield( privmsg => $who => "Error adding preparing statement to add user to channel: " . $sth->errstr );
    }

    $sth->bind_param( 1, $access );
    $sth->bind_param( 2, $user );
    $sth->bind_param( 3, $channel );
    my $rv = $sth->execute();
    if ( !$rv ) {
        $irc->yield( privmsg => $who => "Error adding user to channel: " . $sth->errstr );
        return;
    }
    if ( $sth->rows > 0 ) {
        $irc->yield( privmsg => $who => "Added user to channel" );
    }

}

sub add_user {

    my @prams = @_;
    my $chan  = $prams[1];
    my $nick  = $prams[2];
    my $umask = $prams[3];

    my @args = split / /, $prams[0];

    my $nacl = acl( $nick, $umask );

    if ( !defined($nacl) || $nacl->{'access'} ne "A" ) {
        $irc->yield( notice => $nick => "No Access!" );
        return;
    }

    my $nickname = $args[0];
    my $hostmask = $args[1];
    my $acl      = $args[2];

    if ( ( $nickname eq "" ) || ( $hostmask eq "" ) || ( $acl eq "" ) ) {
        return;
    }

    $irc->yield( privmsg => $chan => "Adding user $nickname with a mask of $hostmask and access level $acl" );

    $dbh->begin_work;

    my $query = q{INSERT INTO users (username, access) VALUES(?, ?)};

    my $sth = $dbh->prepare($query);
    if ( !$sth ) {
        $irc->yield( privmsg => $chan => "Error preparing insert statement for useradd: " . $dbh->errstr );
        $sth->finish;
        $dbh->rollback;
        return;
    }
    $sth->bind_param( 1, $nickname );
    $sth->bind_param( 2, $acl );

    my $rv = $sth->execute();
    if ( !$rv ) {
        $irc->yield( privmsg => $chan => "Error adding user: " . $sth->errstr );
        $sth->finish;
        $dbh->rollback;
        return;
    }
    $query = q{INSERT INTO usermask (hostmask, userid) VALUES(?, (SELECT(userid) FROM users WHERE username = ?))};
    $sth   = $dbh->prepare($query);
    if ( !$sth ) {
        $irc->yield( privmsg => $chan => "Error preparing insert statement for usermask add: " . $dbh->errstr );
        $sth->finish;
        $dbh->rollback;
        return;
    }

    $sth->bind_param( 1, $hostmask );
    $sth->bind_param( 2, $nickname );
    $rv = $sth->execute();

    if ( !$rv ) {
        $irc->yield( privmsg => $chan => "Error adding usermask: " . $sth->errstr );
        $sth->finish;
        $dbh->rollback;
        return;
    }
    $dbh->commit;
    if ( $sth->rows > 0 ) {
        $irc->yield( privmsg => $chan => "User has been added." );
    }

}

sub del_user {

    my @prams    = @_;
    my $nickname = $prams[0];
    my $chan     = $prams[1];
    my $nick     = $prams[2];
    my $umask    = $prams[3];

    my $nacl = acl( $nick, $umask );

    if ( !defined($nacl) || ( $nacl->{'access'} !~ 'A' ) ) {
        $irc->yield( notice => $nick => "No Access!" );
        return;
    }

    if ( $nickname eq "" ) { return; }

    my $query = q{DELETE FROM users where username = ?};

    my $sth = $dbh->prepare($query);
    if ( !$sth ) {
        $irc->yield( privmsg => $chan => "Error deleting user: " . $dbh->errstr );
        return;
    }
    $sth->bind_param( 1, $nickname );

    #DBI::dump_results($sth);
    my $rv = $sth->execute();
    if ( !$rv ) {
        $irc->yield( privmsg => $chan => "Error deleting user: " . $sth->err );
    }
    else {
        if ( $sth->rows > 0 ) {
            $irc->yield( privmsg => $chan => "User has been deleted." );
        }
    }

}

sub chan_acl {
    my @prams = @_;

    my $nickname = $prams[0];
    my $chan     = $prams[1];
    my $hostmask = $prams[2];
    my $host;

    #print "CHAN_ACL: -$hostmask- -$chan- -$nickname-\n";

    if ( defined($hostmask) && $hostmask ne '' ) {
        $host = $hostmask;
    }
    else {
        my $var = $irc->nick_info("$nickname");
        $host = $nickname . "!" . $var->{'Userhost'};
    }

    my %access;

    my $query =
q{SELECT username, hostmask, chaccess from users, usermask, channel, chanuser WHERE ? GLOB usermask.hostmask AND users.userid = usermask.userid AND users.userid = chanuser.userid AND chanuser.chanid = channel.chanid AND channame = ?};

    my $sth = $dbh->prepare($query) || die( "Unable to prepare ACL query: " . $dbh->errstr );

    $sth->bind_param( 1, $host );
    $sth->bind_param( 2, $chan );
    $sth->execute() || die( "Unable to execute query " . $sth->errstr );

    my $res = $sth->fetchrow_hashref;
    if ( defined($res) ) {
        if ( matches_mask( $res->{'hostmask'}, $host ) ) {
            $access{'hostmask'} = $res->{'hostmask'};
            $access{'username'} = $res->{'username'};
            $access{'access'}   = $res->{'chaccess'};
            return \%access;
        }

    }
    return undef;
}

sub acl {
    my @prams    = @_;
    my $nickname = $prams[0];
    my $hostmask = $prams[1];

    #print "ACL $hostmask\n";
    my $sth;
    my $tnick;
    my %access;

    my $host;
    if ( defined($hostmask) ) {
        $host = $hostmask;
    }
    else {
        my $var = $irc->nick_info("$nickname");
        $host = $nickname . "!" . $var->{'Userhost'};
    }

    my $query = q{SELECT users.username AS username, usermask.hostmask AS hostmask, users.access AS access FROM users,usermask WHERE usermask.userid == users.userid AND  ? GLOB usermask.hostmask};

    $sth = $dbh->prepare($query) || die( "Unable to prepare ACL query: " . $dbh->errstr );

    #DBI::dump_results($sth);

    $sth->bind_param( 1, $host );
    $sth->execute() || die( "Unable to execute ACL query: " . $sth->errstr );

    if ( defined( my $res = $sth->fetchrow_hashref ) ) {
        if ( matches_mask( $res->{'hostmask'}, $host ) ) {
            $access{'hostmask'} = $res->{'hostmask'};
            $access{'username'} = $res->{'username'};
            $access{'access'}   = $res->{'access'};

            #print Dumper(\%access);
            return \%access;
        }

    }

    if ( matches_mask( $master, $host ) ) {
        $access{'hostmask'} = $master;
        $access{'username'} = 'master user';
        $access{'access'}   = 'A';
        return \%access;
    }

    return undef;

}

sub check_user {

    my @prams    = @_;
    my $nickname = $prams[0];
    my $who      = $prams[1];
    my $nick     = $prams[2];
    my $umask    = $prams[3];

    #   print Dumper($acl);

    my $nacl = acl( $who, $umask );

    if ( !defined($nacl) || ( $nacl->{'access'} !~ 'O|A' ) ) {
        $irc->yield( notice => $who => "No Access!" );
        return;
    }

    my $acl = acl($nickname);

    if ( !defined($acl) ) {

        $irc->yield( privmsg => $who => "No such user." );
        return;

    }

    $irc->yield( privmsg => $who => "User access level for user: " . $acl->{'username'} . " " . $acl->{'hostmask'} . " " . $acl->{'access'} );

}

sub mod_user {

    my @prams = @_;
    my $chan  = $prams[1];
    my $nick  = $prams[2];
    my $umask = $prams[3];
    my @args  = split / /, $prams[0];

    my $nacl = acl( $nick, $umask );

    if ( !defined($nacl) || $nacl->{'access'} ne "A" ) {
        $irc->yield( notice => $nick => "No Access!" );
        return;
    }

    my $nickname = $args[0];
    my $acl      = $args[1];

    if ( ( $nickname eq "" ) || ( $acl eq "" ) ) {
        return;
    }

    $irc->yield( privmsg => $chan => "Modifying user $nickname with access level $acl" );

    $dbh->begin_work;

    my $query = q{UPDATE users set access = ? where username = ?};

    my $sth = $dbh->prepare($query);
    if ( !$sth ) {
        $irc->yield( privmsg => $chan => "Error preparing update statement for useradd: " . $dbh->errstr );
        $dbh->rollback;
        return;
    }
    $sth->bind_param( 1, $acl );
    $sth->bind_param( 2, $nickname );

    my $rv = $sth->execute();
    if ( !$rv ) {
        $irc->yield( privmsg => $chan => "Error adding user: " . $sth->errstr );
        $sth->finish;
        $dbh->rollback;
        return;
    }
    $dbh->commit;
    if ( $sth->rows > 0 ) {
        $irc->yield( privmsg => $chan => "User has been modified." );
    }

}

sub list_users {

    my @prams = @_;
    my $chan  = $prams[1];
    my $nick  = $prams[2];
    my $umask = $prams[3];

    my @args = split / /, $prams[0];

    my $nacl = acl( $nick, $umask );

    if ( !defined($nacl) || $nacl->{'access'} ne "A" ) {
        $irc->yield( notice => $nick => "No Access!" );
        return;
    }

    my $query = q{SELECT username,access,userid from users};
    my $sth   = $dbh->prepare($query);
    my $rv    = $sth->execute();

    while ( defined( my $res = $sth->fetchrow_hashref ) ) {

        my $uname  = $res->{'username'};
        my $access = $res->{'access'};
        my $userid = $res->{'userid'};
        $irc->yield( privmsg => $nick => "Username: $uname Access: $access UserID: $userid" );

    }

}

sub addmask {
    my @prams = @_;
    my $chan  = $prams[1];
    my $nick  = $prams[2];
    my $umask = $prams[3];

    my @args = split / /, $prams[0];

    my $nacl = acl( $nick, $umask );

    if ( !defined($nacl) || $nacl->{'access'} ne "A" ) {
        $irc->yield( notice => $nick => "No Access!" );
        return;
    }

    my $query = q{INSERT INTO usermask (hostmask, userid) VALUES(?, (SELECT(userid) FROM users WHERE username = ?))};
    my $sth   = $dbh->prepare($query);
    if ( !$sth ) {
        $irc->yield( privmsg => $chan => "Error preparing insert statement for usermask add: " . $dbh->errstr );
        $sth->finish;
        return;
    }

    $sth->bind_param( 1, $args[1] );
    $sth->bind_param( 2, $args[0] );
    my $rv = $sth->execute();

    if ( !$rv ) {
        $irc->yield( privmsg => $chan => "Error adding usermask: " . $sth->errstr );
        $sth->finish;
        return;
    }
    if ( $sth->rows > 0 ) {
        $irc->yield( privmsg => $chan => "Usermask has been added." );
    }

}

sub listmask {
    my @prams = @_;
    my $chan  = $prams[1];
    my $nick  = $prams[2];
    my $umask = $prams[3];

    my @args = split / /, $prams[0];
    my $nacl = acl( $nick, $umask );
    if ( !defined($nacl) || $nacl->{'access'} ne "A" ) {
        $irc->yield( notice => $nick => "No Access!" );
        return;
    }

    my $query = q{SELECT username, hostmask, maskid FROM users,usermask WHERE users.userid = usermask.userid AND (users.userid = ? OR users.username = ?)};
    my $sth   = $dbh->prepare($query);
    if ( !$sth ) {
        $irc->yield( privmsg => $nick => "Unable to prepare query to list user mask: " . $dbh->errstr );
        return;
    }

    $sth->bind_param( 1, $args[0] );
    $sth->bind_param( 2, $args[0] );

    my $rv = $sth->execute();

    if ( !$rv ) {
        $irc->yield( privmsg => $nick => "Unable to list user mask: " . $sth->errstr );
        return;
    }
    $irc->yield( privmsg => $nick => "Masks for user" );
    while ( defined( my $res = $sth->fetchrow_hashref ) ) {

        my $hmask  = $res->{'hostmask'};
        my $luser  = $res->{'username'};
        my $maskid = $res->{'maskid'};
        $irc->yield( privmsg => $nick => "Username: $luser Mask: $hmask MaskID: $maskid" );

    }
    if ( !$sth->rows ) {
        $irc->yield( privmsg => $nick => "No masks found for user" );
    }

}

sub mod_chanuser {

    my @prams = @_;
    my $chan  = $prams[1];
    my $nick  = $prams[2];
    my $umask = $prams[3];

    my @args = split / /, $prams[0];

    my $nacl = acl( $nick, $umask );

    if ( !defined($nacl) || $nacl->{'access'} ne "A" ) {
        $irc->yield( notice => $nick => "No Access!" );
        return;
    }

}

sub del_chanuser {

    my @prams = @_;
    my $chan  = $prams[1];
    my $nick  = $prams[2];
    my $umask = $prams[3];

    my @args = split / /, $prams[0];

    my $lchan = $args[0];
    my $lnick = $args[1];

    my $uid;

    my $nacl = acl( $nick, $umask );

    if ( !defined($nacl) || $nacl->{'access'} ne "A" ) {
        $irc->yield( notice => $nick => "No Access!" );
        return;
    }

    my $query =
q{DELETE FROM chanuser WHERE chanuser.userid = (SELECT users.userid FROM users,channel,chanuser WHERE channel.channame = ? AND (users.userid = ? OR users.username = ?) AND channel.chanid == chanuser.chanid AND chanuser.userid == users.userid)};

    $sth = $dbh->prepare($query);

    if ( !$sth ) {
        $irc->yield( privmsg => $nick => "Error preparing statement to delete chanuser: " . $dbh->errstr );
        return;
    }

    $sth->bind_param( 1, $lchan );
    $sth->bind_param( 2, $lnick );
    $sth->bind_param( 3, $lnick );

    my $rv = $sth->execute();
    if ( !$rv ) {
        $irc->yield( privmsg => $nick => "Unable to delete chanuser:" . $sth->errstr );
        return;
    }

    if ( $sth->rows > 0 ) {
        $irc->yield( privmsg => $nick => "User has been deleted." );
        return;
    }
    else {
        $irc->yield( privmsg => $nick => "User not found?" );
        return;
    }

    return;

}

sub list_chanuser {

    my @prams = @_;
    my $chan  = $prams[1];
    my $nick  = $prams[2];
    my $umask = $prams[3];

    my @args = split / /, $prams[0];
    my $lchan = $args[0];

    my $nacl = acl( $nick, $umask );

    if ( !defined($nacl) || $nacl->{'access'} ne "A" ) {
        $irc->yield( notice => $nick => "No Access!" );
        return;
    }

    if ( !defined($lchan) || $lchan eq "" ) {
        $irc->yield( privmsg => $nick => "Options are: listchan #channel" );
        return;
    }

    my $query = q{ SELECT username,users.userid AS userid,chaccess,channame FROM users,channel,chanuser WHERE channel.channame = ? AND channel.chanid == chanuser.chanid AND chanuser.userid == users.userid};

    my $sth = $dbh->prepare($query);
    $sth->bind_param( 1, $lchan );
    my $rv = $sth->execute();
    if ( !$rv ) {
        $irc->yield( privmsg => $nick => "Unable to list channels: " . $sth->errstr );
    }
    while ( defined( my $res = $sth->fetchrow_hashref ) ) {

        my $uname   = $res->{'username'};
        my $access  = $res->{'chaccess'};
        my $newchan = $res->{'channame'};
        my $uid     = $res->{'userid'};
        $irc->yield( privmsg => $nick => "Chan: $newchan User: $uname Userid:[$uid] Access: $access" );

    }
    if ( !$sth->rows ) {
        $irc->yield( privmsg => $nick => "No users found" );
    }

}

sub rss_timer {
    my ( $kernel, $umask, $channel ) = @_[ KERNEL, ARG0, ARG1 ];
    get_all_rss();
    $kernel->delay( 'rss_timer', 900 );
    return;
}

sub get_all_rss {

    my $query = q{select DISTINCT nick from rssfeeds; };
    my $sth   = $dbh->prepare($query);
    my $rv    = $sth->execute();

    while ( defined( my $res = $sth->fetchrow_hashref ) ) {
        getrss( $res->{'nick'} );
    }
}

sub addrss {
    my @prams   = @_;
    my $chan    = $prams[1];
    my $nick    = $prams[2];
    my @args    = split / /, $prams[0];
    my $rssurl  = $args[0];
    my $channel = $args[1];
    if ($channel) {
        $nick = $channel;
    }
    my $xml = get($rssurl);

    #my $rp = new XML::RSS::Parser::Lite;
    #$rp->parse($xml);
    my $rss = new XML::RSS;
    eval { $rss->parse($xml) };
    if ($@) {
        $irc->yield( privmsg => $nick => "unable to add feed" );
        return;
    }
    foreach my $item ( @{ $rss->{'items'} } ) {
        my $title = $item->{'title'};
        my $link  = $item->{'link'};
        if ( title_exists_in_db( $nick, $title ) == 1 ) {
            add_feed_to_db( $nick, $title, $rssurl );
        }
        else {
            $irc->yield( privmsg => $nick => "feed already exists" );
            return;
        }
    }
    $irc->yield( privmsg => $nick => "added successfully" );
}

sub deleterss {
    my @prams  = @_;
    my $chan   = $prams[1];
    my $nick   = $prams[2];
    my @args   = split / /, $prams[0];
    my $rssurl = $args[0];
    my $query  = q{DELETE from rssfeeds where nick = ? and rssurl = ?};
    my $sth    = $dbh->prepare($query);
    $sth->bind_param( 1, $nick );
    $sth->bind_param( 2, $rssurl );
    my $rv = $sth->execute();

    if ( !$rv ) {
        $irc->yield( privmsg => $nick => "error inserting feed database" );
    }
    else {
        $irc->yield( privmsg => $nick => "Deleted $rssurl" );
    }
}

sub title_exists_in_db {
    my @prams = @_;
    my $nick  = $prams[0];
    my $title = $prams[1];
    my $query = q{SELECT nick from rssfeeds where nick = ? and title GLOB  ?};
    my $sth   = $dbh->prepare($query);
    $sth->bind_param( 1, $nick );
    $sth->bind_param( 2, $title );
    $sth->execute() || die "Error: cannot get rss feeds " . $sth->errstr;

    if ( $sth->fetch ) {
        return 0;
    }
    else {
        return 1;
    }
}

sub add_feed_to_db {
    my @prams  = @_;
    my $nick   = $prams[0];
    my $title  = $prams[1];
    my $rssurl = $prams[2];
    my $query  = q{INSERT into rssfeeds (nick, title, rssurl) VALUES(?, ?, ?)};
    my $sth    = $dbh->prepare($query);
    $sth->bind_param( 1, $nick );
    $sth->bind_param( 2, $title );
    $sth->bind_param( 3, $rssurl );

    my $rv = $sth->execute() || die "Error: cannot get rss feeds " . $sth->errstr;
    if ( !$rv ) {
        $irc->yield( privmsg => $nick => "error inserting feed database" );
    }
    else {
        if ( $sth->rows > 0 ) {
        }
    }
}

sub getrss {
    my @prams = @_;
    my $nick  = $prams[0];
    if ( !$nick ) {
        my $nick = $prams[2];
    }

    my $query = q{select DISTINCT rssurl from rssfeeds where nick = ? };
    my $sth   = $dbh->prepare($query);
    $sth->bind_param( 1, $nick );
    my $rv = $sth->execute();
    while ( defined( my $res = $sth->fetchrow_hashref ) ) {
        show_new_feeds( $nick, $res->{'rssurl'} );
    }
}

sub listrss {
    my @prams = @_;
    my $chan  = $prams[1];
    my $nick  = $prams[2];

    my $query = q{select DISTINCT rssurl from rssfeeds where nick = ? };
    my $sth   = $dbh->prepare($query);
    $sth->bind_param( 1, $nick );
    my $rv = $sth->execute();
    if ( !$rv ) {
        $irc->yield( privmsg => $nick => "Unable to list channels: " . $sth->errstr );
    }
    while ( defined( my $res = $sth->fetchrow_hashref ) ) {
        $irc->yield( privmsg => $nick => "$res->{'rssurl'}" );
    }
}

sub show_new_feeds {
    my @prams  = @_;
    my $nick   = $prams[0];
    my $rssurl = $prams[1];
    print "getting rssurl: $rssurl\n";
    my $xml = get($rssurl);
    my $rss = new XML::RSS;
    $rss->parse($xml);
    foreach my $item ( @{ $rss->{'items'} } ) {
        my $title = $item->{'title'};
        my $link  = $item->{'link'};
        if ( title_exists_in_db( $nick, $title ) == 1 ) {
            add_feed_to_db( $nick, $title, $rssurl );
            $irc->yield( privmsg => $nick => "$title" );
            $irc->yield( privmsg => $nick => "$link" );
        }
    }
}

sub start_trivia {

    my @prams   = @_;
    my $channel = $prams[1];
    my $nick    = $prams[2];
    my $kernel  = $prams[4];

    if ($trivia_on) {
        $irc->yield( privmsg => $channel => "The game is already running... " );
        return;
    }

    $trivia_on   = 1;
    $trivia_chan = $channel;
    my $question = "";

    my $query = q{SELECT question,answer FROM trivia ORDER BY RANDOM() LIMIT 1};
    my $sth;
    $sth = $dbh->prepare($query);
    if ( !$sth ) {
        $irc->yield( privmsg => $channel => "Error fetching question: " . $dbh->errstr );
        return;
    }

    my $rv = $sth->execute();

    if ( !$rv ) {
        $irc->yield( privmsg => $channel => "Error reading question: " . $sth->errstr );
        return;
    }

    my $count = 0;
    while ( defined( my $res = $sth->fetchrow_hashref ) ) {
        $question   = $res->{'question'};
        $trivia_ans = lc( $res->{'answer'} );
    }

    $irc->yield( privmsg => $channel => $question );
    $kernel->delay( 'trivia_expire', $trivia_timeout );

    return;
}

sub stop_trivia {

    if ( !$trivia_on ) { return; }

    $trivia_on = 0;

    $irc->yield( privmsg => $trivia_chan => "The game has been stopped." );
    $trivia_ans = "";

    return;
}

sub trivia_expire {

    if ( !$trivia_on ) { return; }

    $trivia_on = 0;

    $irc->yield( privmsg => $trivia_chan => "Nobody got that right. The answer was: $trivia_ans" );
    $trivia_ans = "";

    return;
}

sub trivia_score {

    my @prams   = @_;
    my $channel = $prams[1];
    my $nick    = $prams[2];

    my $query    = q{SELECT count(*) from tscores};
    my $sth      = $dbh->prepare($query);
    my $rv1      = $sth->execute();
    my $res      = $sth->fetchrow_hashref;
    my $rowcount = $res->{'count(*)'};

    $query = q{SELECT nick,score from tscores ORDER BY CAST (score AS INTEGER) DESC LIMIT 10};
    $sth   = $dbh->prepare($query);
    my $rv = $sth->execute();
    if ( !$rv ) {
        $irc->yield( privmsg => $nick => "Unable to get scores: " . $sth->errstr );
    }
    $res = $sth->fetchrow_hashref;

    if ( $rowcount > 10 ) { $rowcount = 10; }

    my $output = "";

    for ( my $i = 1 ; $i < $rowcount + 1 ; $i++ ) {

        $output = $output . " $i. $res->{'nick'}($res->{'score'})";
        $res    = $sth->fetchrow_hashref;

    }

    $irc->yield( privmsg => $channel => "Top 10 scores for trivia:" );
    $irc->yield( privmsg => $channel => $output );

}

sub score_trivia {

    my @prams = @_;

    my $nick = $prams[0];

    my $query = q{SELECT nick,score from tscores where nick = ?};
    my $sth   = $dbh->prepare($query);
    $sth->bind_param( 1, $nick );
    my $rv = $sth->execute();
    if ( !$rv ) {
        $irc->yield( privmsg => $nick => "Unable to get score: " . $sth->errstr );
    }
    else {
        my $res = $sth->fetchrow_hashref;
        if ( $sth->rows > 0 ) {
            my $score = $res->{'score'};
            $score++;
            $query = q{UPDATE tscores set score = ? where nick = ?};
            $sth   = $dbh->prepare($query);
            $sth->bind_param( 1, $score );
            $sth->bind_param( 2, $nick );
            my $rv2 = $sth->execute();
            if ( !$rv2 ) {
                $irc->yield( privmsg => $nick => "Unable to set score: " . $sth->errstr );
            }

        }
        else {

            $query = q{INSERT INTO tscores (nick, score) values (?, 1)};
            $sth   = $dbh->prepare($query);
            $sth->bind_param( 1, $nick );
            my $rv3 = $sth->execute();
            if ( !$rv3 ) {
                $irc->yield( privmsg => $nick => "Unable to add score: " . $sth->errstr );
            }

        }
    }
}

sub start_timebomb {
    my @prams   = @_;
    my $channel = $prams[1];

    if ($tb_on) {
        $irc->yield( privmsg => $channel => "The timebomb is already running... " );
        return;
    }

    $tb_target = $prams[0];
    my $nick   = $prams[2];
    my $kernel = $prams[4];

    if ( ! $irc->is_channel_member($channel,$tb_target) ) {
        $irc->yield( privmsg => $channel => "$nick: $tb_target is not in the channel, you must want the timebomb..." );
        start_timebomb( $nick, $channel, $nick, "", $prams[4] );
        return;
    }

    if ( $tb_target eq $irc->nick_name() ) {
        $irc->yield( privmsg => $channel => "$nick: Do you think I'm stupid?" );
        start_timebomb( $nick, $channel, $nick, "", $prams[4] );
        return;
    }

    $tb_on      = 1;
    $tb_chan    = $channel;
    $tb_timeout = int( rand(45) + 15 );
    $tb_sender  = $nick;

    my @tb_colors = (
        'Red',     'Orange', 'Yellow',     'Green',      'Blue',   'Violet',  'Indigo',  'Black', 'White', 'Grey',  'Brown',    'Pink',
        'Mauve',   'Beige',  'Aquamarine', 'Chartreuse', 'Bisque', 'Crimson', 'Fuchsia', 'Gold',  'Ivory', 'Khaki', 'Lavender', 'Lime',
        'Magenta', 'Maroon', 'Navy',       'Olive',      'Plum',   'Silver',  'Tan',     'Teal',  'Turquoise'
    );

    my $tb_num_choices = int(rand(7));
    if ($tb_num_choices < 2) { $tb_num_choices = 2; } 
    elsif ($tb_num_choices > 6) { $tb_num_choices = 6; }

    my %tb_color_choices = ();
    for ( my $i = 0 ; $i < $tb_num_choices ; $i++ ) {
        my $rand_color = int( rand(@tb_colors) );
        while ( defined $tb_color_choices{$rand_color} ) {
            $rand_color = int( rand(@tb_colors) );
        }
        $tb_color_choices{$rand_color} = $tb_colors[$rand_color];
    }

    my @hash_keys = values %tb_color_choices;
    $tb_ans = $hash_keys[ rand @hash_keys ];
    my $tb_color_string = "";
    foreach my $color ( values %tb_color_choices ) {
        $tb_color_string .= $color . ", ";
    }
    chop($tb_color_string);
    chop($tb_color_string);

    if ( $tb_target =~ /noghri/i ) {
        my %tb_color_reversed = reverse %tb_color_choices;
        if ( defined $tb_color_reversed{'Pink'} ) { $tb_ans = "Pink"; }
    }

    $irc->yield( privmsg => $channel => "$tb_target: Timebomb! You have $tb_timeout seconds!" );
    $irc->yield( privmsg => $channel => "$tb_target: Choose which wire to !cut: $tb_color_string" );

    $kernel->delay( 'timebomb_expire', $tb_timeout );

    return;
}

sub timebomb_expire {

    if ( !$tb_on ) { return; }

    $irc->yield( privmsg => $tb_chan => "$tb_target: Time's up!" );
    my $wheres_the_kaboom = int(rand(25));
    if ($wheres_the_kaboom == 0) {
      $irc->yield( privmsg => $tb_chan => "$tb_target: Where's the kaboom?  There was supposed to be an earth-shattering kaboom!");
    } else {
      $irc->yield( kick => $tb_chan => "$tb_target" => "Time's up!  KABOOOOOM!" );
    }

    $tb_on     = 0;
    $tb_ans    = "";
    $tb_target = "";
    $tb_sender = "";

    return;
}

sub cut_timebomb {
    my @prams   = @_;
    my $guess   = $prams[0];
    my $channel = $prams[1];
    my $nick    = $prams[2];

    if ( !$tb_on ) {
        my $rand_bomb = int( rand(10) );
        if ( $rand_bomb > 7 ) {
            $irc->yield( privmsg => $channel => "$nick: You should know better than to go cutting wires you don't know what they go to... you've activated a timebomb!" );
            start_timebomb( $nick, $channel, $nick, "", $prams[4] );
        }
        return;
    }

    if ( $nick !~ /$tb_target/i ) {
        $irc->yield( privmsg => $tb_chan => "$nick: You're not holding the timebomb, we can send one your way if you like..." );
        return;
    }

    if ($guess =~ /$tb_sender/i) {
       my $rand_kt_bonus = 0;
       if ($tb_target =~ /ktuli/i) {
         $rand_kt_bonus = int(rand(3));
       } else {
         $rand_kt_bonus = int(rand(12));
       }
       if ($rand_kt_bonus == 1) {
         $guess = $tb_ans;
       }
     }

    if ( $guess =~ /$tb_ans/i ) {
        my $rand_bomb = int( rand(20) );
        if ( $rand_bomb == 18 ) {
            $irc->yield( privmsg => $channel => "$nick: You have disarmed the first timer, but have activated another!" );
            $tb_on = 0;
            start_timebomb( $nick, $channel, $tb_sender, "", $prams[4] );
            return;
        }
        elsif ( $rand_bomb == 19 ) {
            $irc->yield( privmsg => $channel => "$tb_sender: Bad news for you!  $nick disarmed the bomb but now you have one to disarm!" );
            $tb_on = 0;
            start_timebomb( $tb_sender, $channel, $tb_target, "", $prams[4] );
            return;
        }
        else {
            $irc->yield( privmsg => $tb_chan => "$nick: You chose wisely.  Have a nice day!" );
        }
    }
    else {
        $irc->yield( privmsg => $tb_chan => "$nick: You chose poorly..." );

        my $wheres_the_kaboom = int(rand(25));
        if ($wheres_the_kaboom == 0) {
          $irc->yield( privmsg => $tb_chan => "$tb_target: Where's the kaboom?  There was supposed to be an earth-shattering kaboom!");
        } else {
          $irc->yield( kick => $tb_chan => "$tb_target" => "You should have chose $tb_ans!  KABOOOOOM!" );
        }
    }
    $tb_target = "";
    $tb_sender = "";
    $tb_ans    = "";
    $tb_on     = 0;
}

sub track_package {
    my @prams = @_;
    my $trnum = $prams[0];
    my $chan  = $prams[1];
    my $nick  = $prams[2];
    my $who   = $prams[3];
    my $nacl  = acl( $nick, $who );

    if ( !defined($nacl) ) {
        $irc->yield( privmsg => $chan => "No Access!" );
        return;
    }

    if ( $trnum eq "" ) {
        if ( !acl( $nick, $who ) ) {
            $irc->yield( notice => $nick => "Must be a user to set tracking default" );
            return;
        }

        my $query = q{SELECT trdefault FROM users, usermask WHERE username = (SELECT username WHERE usermask.userid == users.userid AND ? GLOB usermask.hostmask)};

        my $sth = $dbh->prepare($query);
        if ( !$sth ) {
            $irc->yield( privmsg => $chan => "Unable to check tracking default: " . $dbh->errstr );
            return;
        }
        $sth->bind_param( 1, $who );
        my $rv = $sth->execute();
        if ( !$rv ) {
            $irc->yield( privmsg => $chan => "Unable to check tracking default: " . $sth->errstr );
        }
        else {
            if ( defined( my $res = $sth->fetchrow_hashref ) ) {
                $trnum = $res->{'trdefault'};
            }
        }

        if ( $trnum eq "" ) {
            $irc->yield( privmsg => $chan => "$nick: You don't have a tracking number stored, use !track [number]" );
            return;
        }
    }
    else {
        my $query = q{UPDATE users set trdefault = ? where username = (SELECT username FROM users,usermask WHERE usermask.userid == users.userid AND ? GLOB usermask.hostmask)};

        my $sth = $dbh->prepare($query);
        if ( !$sth ) {
            $irc->yield( privmsg => $chan => "Error updating default: " . $dbh->errstr );
            return;
        }
        $sth->bind_param( 1, $trnum );
        $sth->bind_param( 2, $who );

        #DBI::dump_results($sth);
        my $rv = $sth->execute();
        if ( !$rv ) {
            $irc->yield( privmsg => $chan => "Error updating default: " . $sth->errstr );
        }
        else {
            if ( $sth->rows > 0 ) {
                $irc->yield( privmsg => $chan => "Default tracking number updated." );
            }
        }
    }

    my %track = track_work($trnum);
    $irc->yield( privmsg => $chan => "This package is $track{'Current Status'}" );
}

sub track_work {
    my @prams = @_;
    my $trnum = $prams[0];

    my %track = UPStrack($trnum);
    return %track;
}

sub google {

   my @prams = @_;
   my $search = $prams[0];
   my $chan  = $prams[1];

}


