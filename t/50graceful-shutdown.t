use strict;
use warnings;
use IO::Socket::INET;
use Net::EmptyPort qw(check_port);
use Test::More;
use Time::HiRes;
use t::Util;

subtest 'SIGINT wakes idle workers' => sub {
    my $port = empty_port();
    my $server = spawn_h2o_raw(<< "EOT", [$port]);
num-threads: 4
listen: {host: 127.0.0.1, port: $port}
hosts:
  default:
    paths:
      /:
        file.dir: @{[ DOC_ROOT ]}
EOT
    local $SIG{ALRM} = sub { die "timed out waiting for the in-flight request\n" };
    alarm 10;
    # Hold a request mid-body so the first worker to handle SIGINT cannot exit the process.
    my $sock = IO::Socket::INET->new(PeerAddr => "127.0.0.1:$port") or die "connect: $!";
    print {$sock} "GET /index.txt HTTP/1.1\r\nHost: default\r\nContent-Length: 1\r\nExpect: 100-continue\r\nConnection: close\r\n\r\n";
    like scalar(<$sock>), qr{^HTTP/1\.1 100 }, 'worker is waiting for the request body';
    while (defined(my $header = <$sock>)) {
        last if $header eq "\r\n";
    }
    kill 'INT', $server->{pid} or die "kill: $!";

    # Rebinding detects the last worker closing its listener without waking it with another connection.
    my $deadline = Time::HiRes::time() + 3;
    my $replacement;
    until ($replacement = IO::Socket::INET->new(LocalAddr => "127.0.0.1:$port", Listen => 1, ReuseAddr => 1)) {
        last if Time::HiRes::time() >= $deadline;
        Time::HiRes::sleep(0.02);
    }
    ok $replacement, 'all worker listeners are closed while the connection drains';
    print {$sock} "x";
    my $response = do { local $/; <$sock> };
    like $response, qr{^HTTP/1\.1 200 .*\r\n\r\nhello\n\z}s, 'in-flight request finishes normally';
    alarm 0;
    close $sock;
};

# 1. send headers
# 2. 1st goaway
# 3. send data (with END_STREAM flag)
# 4. 2nd goaway
subtest 'case 1' => sub {
    my $server = spawn_h2o(<< "EOT");
num-threads: 1
http2-graceful-shutdown-timeout: 0
hosts:
  default:
    paths:
      "/":
        - file.dir: @{[ DOC_ROOT ]}
EOT
    unless (fork) {
        Time::HiRes::sleep(1.5);
        kill 'TERM', $server->{pid};
        exit;
    }

    my $output = run_with_h2get_simple($server, <<"EOR");
    req = {
        ":method" => "GET",
        ":authority" => host,
        ":scheme" => "https",
        ":path" => "/",
    }
    h2g.send_headers(req, 1, END_HEADERS)
    sleep 2
    h2g.send_data(1, END_STREAM, '')

    loop do
        f = h2g.read(1000)
        if f == nil
            puts "timeout"
            exit 1
        end
        puts "#{f.type}, stream_id:#{f.stream_id}, len:#{f.len}, flags:#{f.flags}"
        if f.type == 'DATA' and f.is_end_stream
          puts 'received complete response'
          break
        end
    end
EOR
    like $output, qr{received complete response};
};

# 1. send headers
# 2. 1st goaway
# 3. 2nd goaway
# 4. send data (with END_STREAM flag)
subtest 'case 2' => sub {
    my $server = spawn_h2o(<< "EOT");
num-threads: 1
http2-graceful-shutdown-timeout: 0
hosts:
  default:
    paths:
      "/":
        - file.dir: @{[ DOC_ROOT ]}
EOT
    unless (fork) {
        Time::HiRes::sleep(1.5);
        kill 'TERM', $server->{pid};
        exit;
    }

    my $output = run_with_h2get_simple($server, <<"EOR");
    req = {
        ":method" => "GET",
        ":authority" => host,
        ":scheme" => "https",
        ":path" => "/",
    }
    h2g.send_headers(req, 1, END_HEADERS)
    sleep 3
    h2g.send_data(1, END_STREAM, '')

    loop do
        f = h2g.read(1000)
        if f == nil
            puts "timeout"
            exit 1
        end
        puts "#{f.type}, stream_id:#{f.stream_id}, len:#{f.len}, flags:#{f.flags}"
        if f.type == 'DATA' and f.is_end_stream
          puts 'received complete response'
          break
        end
    end
EOR
    like $output, qr{received complete response};
};

done_testing();
