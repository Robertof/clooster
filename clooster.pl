#!/usr/bin/env perl
use Mojo::Base -strict;
use Digest::SHA;
use File::Basename ();
use JSON::MaybeXS;
use Mojo::IOLoop;

$|++;

# Find the configuration path
my $conf_path = $ARGV[0] || (File::Basename::fileparse $0, qr/\.[^.]*/)[0] . ".json";
die "ERROR: $conf_path does not exist\n" unless -e $conf_path;

# Read the configuration
open my $conf_fh, "<", $conf_path or die "ERROR: can't open $conf_path r/o\n";
my $conf_raw; $conf_raw .= $_ while <$conf_fh>;
close $conf_fh;

# Parse it
my $conf = JSON::MaybeXS->new (relaxed => 1)->decode ($conf_raw);
die "ERROR: I'm confused... should I be a server or a client?\n"
    if exists $conf->{client} and exists $conf->{server};
die "ERROR: Missing authentication key" unless exists $conf->{key};
die "ERROR: Missing Cloudflare configuration!\n" unless exists $conf->{cloudflare};

# Useful stuff
my ($is_client, $is_server) = map { exists $conf->{$_} } "client", "server";
# $client_n: number of clients currently connected (must be 1)
# $identity_ok: true if the client or server has authenticated successfully
# $total_clients: the total number of clients the server has ever accepted
# $last_keepalive: unix timestamp containing the last a keepalive was sent
my ($client_n, $identity_ok, $total_clients, $last_keepalive) = 0;
my $cloudflare = Local::Cloudflare->new ($conf->{cloudflare});
my $pushbullet = Local::Pushbullet->new ($conf->{pushbullet});

say "Initializing...";

# Pre-compute the authentication strings
my ($my_authstring, $their_authstring) = map { Digest::SHA::hmac_sha256 ($_, $conf->{key}) }
                                         $conf->{this_server}, $conf->{other_server};                                         
# Load the record & zone from Cloudflare
$cloudflare->init;

# Server mode
Mojo::IOLoop->server ($conf->{server} => \&register_event_handlers) if $is_server;

# Client mode
Mojo::IOLoop->client ($conf->{client} => sub {
    my ($loop, $err, $stream) = @_;
    if ($err) {
        $loop->stop;
        die "ERROR: $err\n";
    }
    say "Successfully connected to ", $stream->handle->peerhostname;
    register_event_handlers ($loop, $stream);
}) if $is_client;

Mojo::IOLoop->recurring (120 => \&watchdog);

say "Starting.";

Mojo::IOLoop->start;

sub register_event_handlers
{
    my ($loop, $stream) = @_;
    $last_keepalive = 0 if $is_client; # keep $last_keepalive in a consistent state
    if ($is_server)
    {
        say "Client connected: ", $stream->handle->peerhostname,
            " (", $stream->handle->peerhost, ")";
        return $stream->close if $client_n == 1; # no event handlers are called in this case
        ++$client_n;
    }
    $stream->timeout (80);
    $stream->write ($my_authstring);
    my $timer;
    $stream->on (read => sub {
        my ($stream, $bytes) = @_;
        if ($identity_ok)
        {
            $last_keepalive = time if $bytes eq $conf->{other_server};
        }
        else
        {
            return $stream->close unless ct_equal ($their_authstring, $bytes);
            say $is_server ? "Client": "Server", " authenticated successfully as ",
                $conf->{other_server};
            ++$identity_ok;
            $timer = $loop->recurring (60 => sub { # keep-alive sender
                $stream->write ($conf->{this_server});
            });
            $last_keepalive = time;
            if ($is_server)
            {
                up_handler() if $total_clients; # call up_handler() only after the first client
                ++$total_clients;
            }
        }
    });
    $stream->on (close => sub {
        --$client_n if $is_server;
        return unless $identity_ok;
        $loop->remove ($timer);
        --$identity_ok; # don't try to fool me!
        undef $last_keepalive;
        down_handler()
    });
}

sub watchdog
{
    my $loop = shift;
    # If $last_keepalive is not defined in server mode, then it means that the server has not
    # received a connection yet, or that the client died. Don't do anything.
    return if $is_server and !defined $last_keepalive;
    # If $last_keepalive is not defined in client mode, then it means that the server died.
    # Try to establish a connection again.
    if ($is_client and !defined $last_keepalive)
    {
        $loop->client ($conf->{client} => sub {
            my ($loop, $err, $stream) = @_;
            unless ($err)
            {
                # Yay, we're up & running again!
                register_event_handlers ($loop, $stream);
                up_handler()
            }
        });
        return;
    }
    # If $last_keepalive is defined (finally!), check if not too much time has passed since the
    # last keepalive.
    down_handler() if time() - $last_keepalive > 120;
}

# Called whenever a server is back online.
sub up_handler
{
    handler ("up");
}

# Called whenever a server is down.
sub down_handler
{
    handler ("down");
}

# Generic handler (no redudant code in my home!)
sub handler
{
    my $event = shift; # either 'up' or 'down'
    say "Server $conf->{other_server} is now $event";
    my $new_record_value = $event eq "up" ?
        $cloudflare->preferred_record_value : $conf->{this_server};
    $cloudflare->fetch_record (sub {
        my $record = shift;
        # if the record is up to date, just send a notification
        if ($record->{content} eq $new_record_value)
        {
            $pushbullet->agent->start (
                $pushbullet->send_note_tx (
                    title => sprintf ("[%s] Server '%s' is now %s",
                             $conf->{this_server}, $conf->{other_server}, $event),
                    body  => "No record change is necessary"
                ),
                # Make the request async, but don't care about the result.
                # If it works, yay! Otherwise, ¯\_(ツ)_/¯
                sub {}
            ) if $pushbullet->enabled;
            return;
        }
        say "Updating the record $record->{name} to $new_record_value";
        # ask cloudflare to update the record
        $cloudflare->agent->start (
            $cloudflare->update_record_tx ($new_record_value),
            sub {
                my (undef, $tx) = @_;
                # check if everything is ok, then notify accordingly
                my $ok = eval {
                    $cloudflare->tx_ok ($tx);
                    $cloudflare->record ($tx->res->json ("/result") // die);
                    1
                };
                $pushbullet->agent->start (
                    $pushbullet->send_note_tx (
                        title => sprintf ("[%s] Server '%s' is now %s%s",
                                 $conf->{this_server}, $conf->{other_server}, $event,
                                 $ok ? "" : ", but something went wrong while updating the record"),
                        body  => $ok ?
                                    sprintf
                                        "The address for '%s' has been changed to '%s'",
                                            $record->{name}, $conf->{this_server} :
                                        "Here's what went wrong: $@"
                    ),
                    sub {}
                ) if $pushbullet->enabled;
            }
        );
    });
}

# constant-time equal function
# inspired by http://codahale.com/a-lesson-in-timing-attacks/
sub ct_equal
{
    my ($a, $b) = map { [ unpack "W*", $_ ] } @_;
    return if @$a ne @$b;
    my $r = 0;
    $r |= $a->[$_] ^ $b->[$_] for 0 .. @$a - 1;
    $r == 0
}

package Local::Pushbullet;
use Mojo::Base -strict;
use Mojo::UserAgent;
use constant BASE_API_URL => "https://api.pushbullet.com/v2";

sub new { bless $_[1] // { disabled => 1 }, $_[0] }
sub agent { state $agent = Mojo::UserAgent->new }

# sends a note
# %msg = ( title => "...", body => "..." )
sub send_note_tx
{
    my ($self, %msg) = @_;
    die "DEVELOPER ERROR: Please try to insert a new developer and try again.\n"
        if $self->{disabled};
    $self->_tx (POST => "pushes" => json => {
        type => "note",
        %msg,
        %{$self->{target} // {}}
    })
}

# true if enabled
sub enabled
{
    !shift->{disabled}
}

sub _tx
{
    my $self = shift;
    splice @_, 1, 1, "@{[BASE_API_URL]}/$_[1]", {
        "Authorization" => "Bearer $self->{key}"
    };
    agent->build_tx (@_)
}

1;

package Local::Cloudflare;
use Mojo::Base -strict;
use Mojo::UserAgent;
use constant BASE_API_URL => "https://api.cloudflare.com/client/v4";

sub new { bless $_[1], $_[0] }
sub agent { state $agent = Mojo::UserAgent->new }

# AUTOLOAD magic to allow to use methods like 'get_zones' and similar
sub AUTOLOAD
{
    my $self = shift;
    our $AUTOLOAD;
    $AUTOLOAD =~ /(get|patch|post|delete|put)_(.+)$/i;
    my ($method, $endpoint) = (uc $1, $2);
    # get_dns_records ('/zones/abcdef') -> GET zones/abcdef/dns_records
    $endpoint =  substr (shift, 1) . "/$endpoint" if $_[0] =~ m!^/!;
    # put_dns_records ('/zones/abcdef', '/ghijkl') -> PUT zones/abcdef/dns_records/ghijkl
    $endpoint .= shift if $_[0] =~ m!^/!;
    # get_zones (name => 'something') -> get_zones ({ name => 'something' })
    @_ = ( { @_ } ) if @_ % 2 == 0 and !grep { $_ eq $_[0] } "form", "json";
    # get_zones ({ name => 'something' }) -> get_zones (form => { name => 'something' })
    unshift @_, "form" if ref $_[0] eq "HASH";
    $self->_tx ($method => $endpoint, @_);
}

# initializes the library by fetching and caching the zone id and record data
sub init
{
    my $self = shift;
    # retrieve the zone id
    my $tx = agent->start ($self->get_zones (name => $self->{zone}, status => "active"));
    $self->tx_ok ($tx, "zone retrieval");
    $self->{zone_id} = $tx->res->json ("/result/0/id")
        or die "ERROR: zone retrieval failed: missing zone id\n";
    # retrieve the record we're interested in
    $self->fetch_record;
}

# retrieves the record object from cloudflare
# optionally makes the request async and calls the callback after everything is done
sub fetch_record
{
    my ($self, $on_finish) = @_;
    my $tx = agent->start (
        $self->get_dns_records (
            "/zones/$self->{zone_id}",
            name => $self->{record}
        ),
        !$on_finish ? () : sub {
            my (undef, $tx) = @_;
            eval {
                $self->tx_ok ($tx);
                $self->{record_obj} = $tx->res->json ("/result/0") // die;
            };
            $on_finish->($self->{record_obj});
        }
    );
    unless ($on_finish)
    {
        $self->tx_ok ($tx, "record retrieval");
        $self->{record_obj} = $tx->res->json ("/result/0")
            or die "ERROR: record retrieval failed: missing record id\n";
    }
}

# updates the address of the record object, returns the transaction object
sub update_record_tx
{
    # $new_value is optional, defaults to "preferred_value"
    my ($self, $new_value) = @_;
    die "ERROR: Local::Cloudflare has not been initialized\n" unless exists $self->{record_obj};
    $self->{record_obj}{content} = $new_value // $self->{preferred_value};
    # return the tx and let the developer start it
    $self->put_dns_records ("/zones/$self->{zone_id}", "/$self->{record_obj}{id}",
        json => $self->{record_obj});
}

# gets/sets the record object
sub record
{
    my $self = shift;
    return $self->{record_obj} = shift if @_;
    $self->{record_obj}
}

# gets the preferred record value
sub preferred_record_value
{
    shift->{preferred_value}
}

# dies if the specified transaction was not successful
# accepts an optional operation description
sub tx_ok
{
    my (undef, $tx, $desc) = @_;
    $desc //= "operation";
    die "ERROR: $desc failed (agent-reported error): @{[$tx->error->{message}]}\n"
        unless $tx->success;
    die "ERROR: $desc failed: invalid JSON data\n" unless defined $tx->res->json;
    die "ERROR: $desc failed (cloudflare error): @{[$tx->res->json('/errors/0/message')]}\n"
        unless $tx->res->json->{success};
    die "ERROR: $desc failed: empty result set\n"
        if ref $tx->res->json->{result} eq "ARRAY" && !@{$tx->res->json->{result}};
}

# internal method, generates a transaction object with the correct URL and authentication
# headers
sub _tx
{
    my $self = shift;
    splice @_, 1, 1, "@{[BASE_API_URL]}/$_[1]", {
        "X-Auth-Key" => $self->{key},
        "X-Auth-Email" => $self->{mail}
    };
    agent->build_tx (@_)
}

1;
