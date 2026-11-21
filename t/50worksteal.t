use strict;
use warnings;
use File::Temp qw(tempfile);
use IO::Select;
use IO::Socket::INET;
use IO::Socket::SSL;
use Test::More;
use t::Util;

local $ENV{H2O_TEST_ACCEPT_HANDOFF_SINGLE_ACCEPTOR} = 1;
local $SIG{ALRM} = sub { die "timed out waiting for accept handoff test\n" };
local $SIG{PIPE} = 'IGNORE';

for my $workers (1, 2, 3, 8) {
    subtest "$workers workers" => sub {
        alarm 20;
        my ($log, $log_path) = tempfile(UNLINK => 1);
        my $port = empty_port();
        my $use_tls = $workers == 2;
        my $tls_config = $use_tls ? <<"TLS" : '';
  ssl:
    key-file: examples/h2o/server.key
    certificate-file: examples/h2o/server.crt
    ocsp-update-interval: 0
TLS
        my $user = $< == 0 ? 'user: root' : '';
        my $server = spawn_h2o_raw(<<"EOT", [{port => $port, proto => 'tcp'}]);
$user
num-threads: $workers
tcp-accept-handoff: ON
max-connections: 48
listen:
  host: 127.0.0.1
  port: $port
$tls_config
hosts:
  default:
    paths:
      /:
        file.dir: @{[DOC_ROOT]}
    access-log:
      path: $log_path
      format: "%{thread-index}x %h"
EOT

        my @clients = map { connect_client($port, $use_tls) } 1..48;
        write_request($_, "GET /index.txt HTTP/1.0\r\n") for @clients;
        my $overflow = connect_client($port, 0);
        if (!$use_tls) {
            write_request($overflow, "GET /index.txt HTTP/1.0\r\n\r\n");
            ok !IO::Select->new($overflow)->can_read(0.2), 'connection limit holds';
        }

        for my $i (0..$#clients) {
            my $client = $clients[$i];
            write_request($client, "\r\n");
            check_response($client, $i + 1);
            # The first response releases one slot while the other clients remain connected.
            if ($i == 0) {
                if ($use_tls) {
                    start_tls($overflow);
                    write_request($overflow, "GET /index.txt HTTP/1.0\r\n\r\n");
                }
                check_response($overflow, 'connection limit recovered');
            }
        }

        undef $server;
        my @entries = <$log>;
        is scalar @entries, 49, 'exactly one access log entry per response';
        my (%served, $valid_entries);
        for (@entries) {
            if (/\A(\d+) 127\.0\.0\.1\n\z/ && $1 < $workers) {
                $served{$1}++;
                ++$valid_entries;
            }
        }
        is $valid_entries, 49, 'logged valid worker indices and preserved client addresses';
        ok $served{0}, 'accepting worker served connections';
        if ($workers > 1) {
            cmp_ok scalar(keys %served), '>', 1, 'a worker without an active listener served connections';
        } else {
            is scalar(keys %served), 1, 'single worker served connections locally';
        }
        alarm 0;
    };
}

done_testing;

sub connect_client {
    my ($port, $use_tls) = @_;
    my $client = IO::Socket::INET->new(PeerAddr => '127.0.0.1', PeerPort => $port, Proto => 'tcp', Timeout => 5)
        or die "connecting to port $port: $!";
    start_tls($client) if $use_tls;
    return $client;
}

sub start_tls {
    my ($client) = @_;
    IO::Socket::SSL->start_SSL($client, SSL_verify_mode => SSL_VERIFY_NONE)
        or die "starting TLS: " . IO::Socket::SSL::errstr();
}

sub write_request {
    my ($client, $request) = @_;
    my $written = syswrite($client, $request);
    die "writing request: $!" unless defined $written && $written == length $request;
}

sub check_response {
    my ($client, $name) = @_;
    local $/;
    my $response = <$client> // '';
    like $response, qr/\AHTTP\/1\.1 200 OK\r\n.+?\r\n\r\nhello\n\z/s, "response $name";
    close $client;
}
