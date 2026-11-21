use strict;
use warnings;
use File::Basename qw(basename);
use File::Temp qw(tempfile);
use Scope::Guard;
use Test::More;
use t::Util;

my $h2o = bindir() . '/h2o';
my $enabled = (server_features()->{epoll_busypoll} // '') eq 'YES';
my $host = <<'YAML';
hosts:
  default:
    paths:
      /:
        file.dir: t/assets/doc_root
YAML

sub capture {
    my $pid = open my $out, '-|';
    die "fork: $!" unless defined $pid;
    if ($pid == 0) {
        open STDERR, '>&', STDOUT or die "dup stderr: $!";
        exec @_ or die "exec $_[0]: $!";
    }
    local $/;
    my $text = <$out> // '';
    close $out;
    return ($?, $text);
}

sub config_file {
    my ($text) = @_;
    my ($fh, $path) = tempfile(UNLINK => 1);
    print {$fh} $text or die "write $path: $!";
    close $fh or die "close $path: $!";
    return $path;
}

sub check_config {
    my ($label, $globals, $error) = @_;
    my ($status, $result) = capture($h2o, '-t', '-c', config_file("listen: 8080\n$host$globals"));
    if (defined $error) {
        isnt $status, 0, "$label is rejected";
        like $result, $error, "$label diagnostic";
    } else {
        is $status, 0, "$label is accepted" or diag $result;
    }
}

sub map_nic {
    my ($index, $cpus, $mode, $options) = @_;
    return "    - ifindex: $index\n      cpus: [$cpus]\n      options:\n        mode: $mode\n" . ($options // '');
}

sub mapped_config {
    my ($threads, @interfaces) = @_;
    return "num-threads: $threads\ntcp-reuseport: ON\nbusy-poll-map:\n  interfaces:\n" . join('', @interfaces);
}

sub lo_index {
    open my $lo, '<', '/sys/class/net/lo/ifindex' or die "find loopback: $!";
    chomp(my $index = <$lo>);
    return $index;
}

sub allowed_cpus {
    open my $fh, '<', '/proc/self/status' or die "read process status: $!";
    while (<$fh>) {
        next unless /^Cpus_allowed_list:\s*([0-9,-]+)/;
        return map { /(\d+)-(\d+)/ ? ($1 .. $2) : 0 + $_ } split /,/, $1;
    }
    die "missing Cpus_allowed_list";
}

subtest 'configuration test' => sub {
    check_config('ordinary configuration', "num-threads: 1\n");
    unless ($enabled) {
        check_config('busy polling on an unsupported build', "busy-poll-usecs: 32\n", qr/busypolling.*not available/i);
        return;
    }

    my @cpu = allowed_cpus();
    my $ifindex = lo_index();
    my $entry = map_nic($ifindex, $cpu[0], 'OFF');
    my $valid = mapped_config(1, $entry);
    check_config('one mapped worker', $valid);
    check_config('loopback lacks a pollable queue', mapped_config(1, map_nic($ifindex, $cpu[0], 'BUSYPOLL')),
                 qr/queue|NAPI|netlink/i);
    check_config('invalid interface mode', mapped_config(1, map_nic($ifindex, $cpu[0], 'OTHER')), qr/BUSYPOLL/i);
    check_config('suspend timeout outside SUSPEND', mapped_config(1, map_nic($ifindex, $cpu[0], 'BUSYPOLL',
                 "        suspend-timeout: 10000\n")), qr/suspend/i);
    check_config('zero suspend timeout in SUSPEND', mapped_config(1, map_nic($ifindex, $cpu[0], 'SUSPEND',
                 "        suspend-timeout: 0\n")), qr/positive suspend-timeout/i);
    check_config('unknown interface', mapped_config(1, map_nic(0, $cpu[0], 'OFF')), qr/interface/i);
    check_config('negative CPU', mapped_config(1, map_nic($ifindex, -1, 'OFF')), qr/integer/i);
    for my $protocol (qw(quic mptcp)) {
        my $active = mapped_config(1, map_nic($ifindex, $cpu[0], 'BUSYPOLL'));
        check_config("active polling with $protocol", "listen: {port: 8081, type: $protocol}\n$active",
                     qr/type $protocol does not support single-NAPI/i);
    }
    check_config('directives after map', "busy-poll-map:\n  interfaces:\n${entry}num-threads: 1\ntcp-reuseport: ON\n");
    (my $disabled = $valid) =~ s/tcp-reuseport: ON/tcp-reuseport: OFF/;
    check_config('map with reuseport disabled', $disabled, qr/tcp-reuseport/i);
    check_config('empty interface list', "num-threads: 1\ntcp-reuseport: ON\nbusy-poll-map: {interfaces: []}\n", qr/interface/i);
    check_config('empty CPU list', mapped_config(1, map_nic($ifindex, '', 'OFF')), qr/cpu/i);
    check_config('duplicate CPU', mapped_config(2, map_nic($ifindex, "$cpu[0], $cpu[0]", 'OFF')), qr/cpu/i);
    check_config('non-numeric CPU', mapped_config(1, map_nic($ifindex, 'invalid', 'OFF')), qr/integer/i);
    check_config('out-of-range budget', "busy-poll-budget: 65536\n", qr/busy-poll-budget/i);
    check_config('trailing text in duration', "busy-poll-usecs: 25ms\n", qr/busy-poll-usecs/i);

    SKIP: {
        skip 'two available CPUs needed for mixed worker configurations', 8 unless @cpu >= 2;
        check_config('unmapped ordinary worker', mapped_config(2, $entry));
        check_config('explicit worker affinity', mapped_config("[$cpu[0], $cpu[1]]", $entry));
        check_config('too few workers', mapped_config(1, map_nic($ifindex, "$cpu[0], $cpu[1]", 'OFF')), qr/worker|thread/i);
        check_config('conflicting worker affinity', mapped_config("[$cpu[1], $cpu[0]]", $entry), qr/cpu|worker|thread/i);
        check_config('duplicate interface', mapped_config(2, $entry, map_nic($ifindex, $cpu[1], 'OFF')), qr/interface/i);
    }
};

sub run_ok {
    my ($status, $out) = capture(@_);
    die "@_ failed ($status): $out" if $status;
    return $out;
}

subtest 'mapped loopback with an ordinary worker' => sub {
    plan skip_all => 'requires a busy-poll build' unless $enabled;
    plan skip_all => 'requires curl' unless prog_exists('curl');
    my @cpu = allowed_cpus();
    plan skip_all => 'requires two available CPUs' unless @cpu >= 2;
    my $port = empty_port();
    my ($log, $logpath) = tempfile(UNLINK => 1);
    my $conf = "listen: $port\n" . mapped_config("[$cpu[1], $cpu[0]]", map_nic(lo_index(), $cpu[1], 'OFF')) .
               $host . "    access-log:\n      path: $logpath\n      format: '%{bp.iface}x %{bp.napi-id}x %{bp.cpu-idx}x %{thread-index}x'\n";
    $conf .= "user: root\n" if $> == 0;
    my $server = spawn_h2o_raw($conf, [$port]);
    my @curl = qw(curl --noproxy * --fail --silent --show-error --max-time 4);
    for (1 .. 8) {
        is run_ok(@curl, "http://127.0.0.1:$port/index.txt"), "hello\n", 'HTTP response body';
    }
    undef $server;
    is_deeply [<$log>], [("lo 0 $cpu[1] 0\n") x 8], 'every loopback request went to the worker assigned to lo';
};

sub sysfs_write {
    my ($path, $value) = @_;
    open my $fh, '>', $path or die "open $path: $!";
    print {$fh} "$value\n" or die "write $path: $!";
    close $fh or die "close $path: $!";
}

sub busy_rx {
    my ($ns) = @_;
    my ($names, $values) = map { [split] } grep { /^TcpExt:/ } split /\n/, run_ok(qw(ip netns exec), $ns, qw(cat /proc/net/netstat));
    for my $i (1 .. $#$names) {
        return $values->[$i] if $names->[$i] eq 'BusyPollRxPackets';
    }
    die 'BusyPollRxPackets is missing from TcpExt';
}

sub check_idle_timeout {
    my ($ns) = @_;
    # Keep the client in the peer namespace. Once H2O answers a HEAD request
    # there is no more traffic on this connection to wake the mapped worker.
    my ($status, $error) = capture(qw(ip netns exec), $ns, $^X, '-e', <<'PERL');
use strict;
use warnings;
use IO::Socket::INET;
use Time::HiRes qw(time);
$SIG{ALRM} = sub { die "client deadline expired while waiting for H2O to close the connection\n" };
alarm 6;
my $sock = IO::Socket::INET->new(PeerAddr => '192.0.2.1', PeerPort => 8080, Proto => 'tcp') or die "connect: $!";
my $start = time;
print {$sock} "HEAD /index.txt HTTP/1.1\r\nHost: default\r\n\r\n" or die "write: $!";
my $status = <$sock> // '';
die "unexpected HTTP status: $status" unless $status =~ m{^HTTP/1\.1 200 };
while (defined(my $header = <$sock>)) {
    last if $header eq "\r\n";
}
die "unexpected response after HEAD" if defined(<$sock>);
die "connection closed before the one-second idle timeout" if time - $start < 0.8;
PERL
    is $status, 0, 'idle keep-alive connection closed before the independent client deadline' or diag $error;
}

subtest 'isolated netdevsim traffic' => sub {
    plan skip_all => 'requires a busy-poll build' unless $enabled;
    my $sys = '/sys/bus/netdevsim';
    plan skip_all => 'requires root, netdevsim and link_device support' unless $> == 0 && -w "$sys/new_device" && -w "$sys/link_device";
    plan skip_all => 'requires iproute2 and curl' unless prog_exists('ip') && prog_exists('curl');
    my @cpu = allowed_cpus();
    plan skip_all => 'requires at least three available CPUs' unless @cpu >= 3;

    my $sv = "h2o-bp-s-$$";
    my $cl = "h2o-bp-c-$$";
    my (@namespaces, @devices, @links, @fds);
    my $creator = $$;
    my $cleanup = Scope::Guard->new(sub {
        return if $$ != $creator;
        for my $link (reverse @links) {
            eval { sysfs_write("$sys/unlink_device", $link) }; warn $@ if $@;
        }
        for my $id (reverse @devices) {
            eval { sysfs_write("$sys/del_device", $id) }; warn $@ if $@;
        }
        for my $ns (reverse @namespaces) {
            system(qw(ip netns del), $ns) == 0 or warn "failed to delete $ns";
        }
    });
    for my $ns ($sv, $cl) {
        run_ok(qw(ip netns add), $ns);
        push @namespaces, $ns;
        run_ok(qw(ip -n), $ns, qw(link set lo up));
        open my $fd, '<', "/var/run/netns/$ns" or die "open netns $ns: $!";
        push @fds, $fd;
    }
    # netdevsim exposes NAPI IDs without recording the RX queue number in
    # received skbs. One queue per interface gives each link a distinct NAPI.
    my (@names, @index);
    for my $link (0, 1) {
        my @endpoints;
        for my $side (0, 1) {
            my $ns = $namespaces[$side];
            my $id = 1000 + int(rand(30000));
            ++$id while -e "$sys/devices/netdevsim$id";
            sysfs_write("$sys/new_device", "$id 1 1");
            push @devices, $id;
            run_ok(qw(udevadm settle --timeout=5)) if prog_exists('udevadm');
            my ($devpath) = glob("$sys/devices/netdevsim$id/net/*");
            die "no interface for netdevsim$id" unless defined $devpath;
            my $name = basename($devpath);
            run_ok(qw(ip link set dev), $name, 'netns', $ns);
            my $addr = sprintf('192.0.%d.%d/24', 2 + $link, 1 + $side);
            run_ok(qw(ip -n), $ns, qw(addr add), $addr, 'dev', $name);
            run_ok(qw(ip -n), $ns, qw(link set dev), $name, 'up');
            chomp(my $idx = run_ok(qw(ip netns exec), $ns, 'cat', "/sys/class/net/$name/ifindex"));
            push @endpoints, fileno($fds[$side]) . ":$idx";
            if ($side == 0) {
                push @names, $name;
                push @index, $idx;
            }
        }
        sysfs_write("$sys/link_device", join(' ', @endpoints));
        push @links, $endpoints[0];
    }

    for my $case (['OFF','OFF'], ['BUSYPOLL','OFF'], ['BUSYPOLL','ON'], ['SUSPEND','OFF'], ['SUSPEND','ON']) {
        subtest "@$case (mode, epoll-nonblock)" => sub {
            my ($mode, $nonblock) = @$case;
            my ($log, $logpath) = tempfile(UNLINK => 1);
            my $options = $mode eq 'OFF' ? '' : "        gro-flush-timeout: 90000000\n        defer-hard-irqs: 100\n";
            $options .= "        suspend-timeout: 180000000\n" if $mode eq 'SUSPEND';
            my @entries = map { map_nic($index[$_], $cpu[1 - $_], $mode, $options) } (0, 1);
            my $proxy_case = $mode eq 'BUSYPOLL' && $nonblock eq 'OFF';
            my $paths = $host;
            $paths .= "      /via/:\n        proxy.reverse.url: http://127.0.0.1:8080/\n" if $proxy_case;
            my $conf = "user: root\nlisten: 8080\nhttp1-request-io-timeout: 1\nepoll-nonblock: $nonblock\nbusy-poll-budget: 16\nbusy-poll-usecs: " .
                       ($mode eq 'BUSYPOLL' ? 1000 : 0) . "\n" . mapped_config("[$cpu[1], $cpu[0], $cpu[2]]", @entries) .
                       $paths . "    access-log:\n      path: $logpath\n      format: \"%m %{bp.iface}x %{bp.napi-id}x %{bp.cpu-idx}x %{thread-index}x %U%q\"\n";
            my $file = config_file($conf);
            # A successful read-only check with CAP_NET_ADMIN dropped catches
            # accidental attempts to change the device during configuration.
            my @test_cmd = ('ip', 'netns', 'exec', $sv);
            push @test_cmd, 'setpriv', '--bounding-set=-net_admin' if prog_exists('setpriv');
            my ($status, $result) = capture(@test_cmd, $h2o, '-t', '-c', $file);
            is $status, 0, 'configuration validates without changing the device' or diag $result;
            my $url = 'http://127.0.0.1:8080/index.txt';
            my @curl = qw(curl --noproxy * --fail --silent --show-error --max-time 4);
            my $server = spawn_server(argv => ['ip','netns','exec',$sv,$h2o,'-c',$file],
                                      is_ready => sub { my ($status) = capture('ip','netns','exec',$sv,@curl,'-I',$url); $status == 0 });
            my $before = busy_rx($sv);
            my $attempts = 32;
            for (1 .. $attempts) {
                my $mapped_url = sprintf('http://192.0.%d.1:8080/index.txt', 2 + $_ % 2);
                my $body = run_ok('ip','netns','exec',$cl,@curl,'-X','GET','--data-binary','@t/assets/doc_root/halfdome.jpg',
                                  $mapped_url);
                die "unexpected response from mapped listener" unless $body eq "hello\n";
            }
            is run_ok('ip','netns','exec',$sv,@curl,$url), "hello\n", 'ordinary worker serves loopback';
            my $packets = busy_rx($sv) - $before;
            check_idle_timeout($cl) if $mode eq 'SUSPEND';
            if ($proxy_case) {
                for my $path ('192.0.2.1:8080/via/index.txt', '192.0.2.1:8080/index.txt', '192.0.3.1:8080/index.txt') {
                    is run_ok(qw(ip netns exec), $cl, @curl, "http://$path?proxy-test"), "hello\n", "response from $path";
                }
            }
            undef $server;

            my (%worker, %napi, %after_proxy);
            my $ordinary = 0;
            for (<$log>) {
                my ($method,$iface,$id,$cpu_id,$tid,$path) = split;
                next if $method eq 'HEAD'; # readiness and keep-alive probes
                if ($path =~ /\?proxy-test$/) {
                    push @{$after_proxy{"$tid $path"}}, "$iface $id $cpu_id";
                    next;
                }
                if ($tid < 2 && $iface eq $names[$tid]) {
                    is $cpu_id, ($cpu[1], $cpu[0])[$tid], 'queue owner uses its configured CPU' unless $worker{$tid};
                    $worker{$tid}++;
                    $napi{$tid}{$id}++;
                } elsif ($iface eq '-' && $tid == 2) {
                    $ordinary++;
                } else {
                    fail "unexpected listener owner: $_";
                }
            }
            is $ordinary, 1, 'unmapped TCP is served only by the ordinary worker';
            is_deeply [sort keys %worker], [0,1], 'both interfaces served traffic';
            is(($worker{0}//0) + ($worker{1}//0), $attempts, 'all mapped requests accounted for');
            if ($mode eq 'OFF') {
                is_deeply [map { sort keys %{$napi{$_} // {}} } (0, 1)], [0, 0], 'OFF workers report NAPI ID zero';
                my $bp = '/proc/sys/net/core/busy_poll';
                SKIP: {
                    skip 'system-wide busy polling enabled', 1 if -e $bp && run_ok('cat', $bp) > 0;
                    is $packets, 0, 'ordinary epoll did not busy poll';
                }
            } else {
                my @ids = map { keys %{$napi{$_} // {}} } (0,1);
                is scalar(@ids), 2, 'each queue kept a single incoming NAPI ID';
                ok @ids == 2 && $ids[0] > 0 && $ids[1] > 0 && $ids[0] != $ids[1], 'separate nonzero NAPI IDs';
                cmp_ok $packets, '>', 0, 'packets processed by busy polling';
                if ($proxy_case) {
                    is_deeply \%after_proxy, {
                        '0 /via/index.txt?proxy-test' => ["$names[0] 0 $cpu[1]"],
                        '2 /index.txt?proxy-test' => ['- 0 -1'],
                        '0 /index.txt?proxy-test' => ["$names[0] 0 $cpu[1]"],
                        '1 /index.txt?proxy-test' => ["$names[1] $ids[1] $cpu[0]"],
                    }, 'only the worker that opened the upstream connection switched to ordinary epoll';
                }
            }
        };
    }
};

done_testing;
