package AnyEvent::NSQ::Connection;

# ABSTRACT: NSQd TCP connection
# VERSION
# AUTHORITY

use strict;
use warnings;
use AnyEvent::Handle;
use Carp;
use JSON::XS ();
use Sys::Hostname;

# Options from the python client, we might want to support later:
#   timeout=1.0
#   heartbeat_interval=30
#   requeue_delay=90
#   tls_v1=False
#   tls_options=None
#   snappy=False
#   deflate=False
#   deflate_level=6
#   output_buffer_size=16384
#   output_buffer_timeout=250
#   sample_rate=0
#   auth_secret=None

sub new {
  my ($class, %args) = @_;

  my $self = bless(
    { hostname        => hostname(),
      connect_timeout => undef,        ## use kernel default
      error_cb        => sub {
        croak(qq{FATAL: error from host '$_[0]->{host}' port $_[0]->{port}: $_[1]});
      },
    },
    $class
  );

  $self->{host} = delete $args{host} or croak q{FATAL: required 'host' parameter is missing};
  $self->{port} = delete $args{port} or croak q{FATAL: required 'port' parameter is missing};

  for my $p (qw( client_id hostname connect_cb )) {
    $self->{$p} = delete $args{$p} if exists $args{$p} and defined $args{$p};
  }

  croak(q{FATAL: required 'connect_cb' parameter is missing}) unless $self->{connect_cb};
  croak(q{FATAL: parameter 'connect_cb' must be a CodeRef})   unless ref($self->{connect_cb}) eq 'CODE';
  croak(q{FATAL: parameter 'error_cb' must be a CodeRef})     unless ref($self->{error_cb}) eq 'CODE';

  $self->connect;

  return $self;
}

sub connect {
  my ($self) = @_;
  return if $self->{handle};

  my $err_cb = $self->{error_cb};

  $self->{handle} = AnyEvent::Handle->new(
    connect => [$self->{host}, $self->{port}],

    on_prepare => sub { $self->{connect_timeout} },
    on_connect => sub { $self->_connected(@_) },

    on_connect_error => sub {
      $self->_disconnected;
      $err_cb->($self, '(connect) ' . ($_[1] || $!));
    },
    on_error => sub {
      $self->_disconnected;
      $err_cb->($self, '(read) ' . ($_[2] || $!));
    },
    on_eof => sub {
      $self->_disconnected;
    },
  );

  return;
}


## Protocol

sub identify {
  my ($self, @rest) = @_;
  my $cb = pop @rest;
  return unless my $hdl = $self->{handle};

  my $data = JSON::XS::encode_json($self->_build_identity_payload(@rest));
  $hdl->push_write("IDENTIFY\012");
  $hdl->push_write(pack('N', length($data)));
  $hdl->push_write($data);

  $self->_on_success_frame(sub { $cb->($self, $self->{identify_info} = $_[1]) });

  return;
}

sub subscribe {
  my ($self, $topic, $chan, $cb) = @_;
  return unless my $hdl = $self->{handle};

  $self->{message_cb} = $cb;

  $hdl->push_write("SUB $topic $chan\012");
  $self->_on_success_frame(sub { });    ## We don't care about the success ok

  return;
}

sub ready {
  my ($self, $n) = @_;
  return unless my $hdl = $self->{handle};

  $self->{ready_count} = $n;
  $self->{in_flight}   = 0;
  $hdl->push_write("RDY $n\012");
  #  print STDERR ">>>> READY SET $self->{in_flight} / $self->{ready_count}\n";

  return;
}

sub mark_as_done_msg {
  my ($self, $msg) = @_;
  return unless my $hdl = $self->{handle};

  $hdl->push_write("FIN $msg->{message_id}\012");

  return;
}

sub requeue_msg {
  my ($self, $msg, $delay) = @_;
  return unless my $hdl = $self->{handle};

  $hdl->push_write("FIN $msg->{message_id}\012");

  return;
}

sub nop {
  my ($self, $n) = @_;
  return unless my $hdl = $self->{handle};

  $hdl->push_write("NOP\012");

  return;
}


## Protocol helpers

sub _build_identity_payload {
  my ($self, @rest) = @_;

  my %data = (
    client_id => $self->{client_id},
    short_id  => $self->{client_id},
    hostname  => $self->{hostname},
    long_id   => $self->{hostname},
    ## TODO: heartbeat_interval => ...,  ## milliseconds between heartbeats
    ## TODO: output_buffer_size => ...,
    ## TODO: output_buffer_timeout => ...,
    ## TODO: sample_rate => ...,
    ## TODO: msg_timeout => ...,
    @rest,
    feature_negotiation => \1,
  );

  my $ua = "AnyEvent::NSQ::Connection/" . ($AnyEvent::NSQ::Connection::VERSION || 'developer');
  if (!$data{user_agent}) { $data{user_agent} = $ua }
  elsif (substr($data{user_agent}, -1) eq ' ') { $data{user_agent} .= $ua }

  for my $k (keys %data) {
    delete $data{$k} unless defined $data{$k};
  }

  return \%data;
}


## Connection setup and cleanup

sub _connected {
  my ($self) = @_;

  $self->{connected} = 1;

  $self->_send_magic_identifier;
  $self->_start_recv_frames;

  $self->{connect_cb}->($self);
}

sub _disconnected {
  my ($self) = @_;

  $self->{handle}->destroy;
  delete $self->{$_} for qw(conn connected);
}

sub _force_disconnect {
  my ($self) = @_;
  return unless my $hdl = $self->{handle};

  $hdl->push_shutdown;
  $hdl->on_read(sub { });
  $hdl->on_eof(undef);
  $hdl->on_error(
    sub {
      delete $hdl->{rbuf};
      $hdl->destroy;
      $self->_disconnected;
    }
  );
}


## low-level protocol details

sub _send_magic_identifier { $_[0]{handle}->push_write('  V2') }

sub _start_recv_frames {
  my ($self) = @_;
  my $hdl    = $self->{handle};
  my $err_cb = $self->{error_cb};

  my @read_frame;    ## on a separate line, we need it circular
  @read_frame = (
    chunk => 8,
    sub {
      my ($size, $frame_type) = unpack('NN', $_[1]);
      $hdl->unshift_read(
        chunk => $size - 4,    ## remove size of frame_type...
        sub {
          my ($msg) = $_[1];
#          print STDERR ">>>> FRAME $size, $frame_type";

          if ($frame_type == 0) {    ## OK frame
#            print STDERR ", success: $msg\n";
            my $info = {};
            if ($msg eq '_heartbeat_') {
              $self->nop;
            }
            else {
              if ($msg ne 'OK') {
                $info = eval { JSON::XS::decode_json($msg) };
                unless ($info) {
                  $err_cb->($self, qq{unexpected/invalid JSON response '$msg'});
                  $self->_force_disconnect;
                  @read_frame = ();
                  return;
                }
                my $cb = shift @{ $self->{success_cb_queue} || [] };
                $cb->($self, $info) if $cb;
              }
            }
          }
          elsif ($frame_type == 1) {    ## error frame
#            print STDERR ", error: $msg\n";
            $self->{error_cb}->($self, qq{received error '$msg'});
            $self->_force_disconnect;
            @read_frame = ();
            return;
          }
          elsif ($frame_type == 2) {    ## message frame
            my ($t1, $t2, $attempts, $message_id) = unpack('NNnA16', substr($msg, 0, 26, ''));
            $msg = {
              attempts   => $attempts,
              message_id => $message_id,
              tstamp     => ($t2 | ($t1 << 32)),
              message    => $msg,
            };
#            print STDERR ", msg: $attempts, $message_id, $msg\n";
            $self->{in_flight}++;
            $self->{message_cb}->($self, $msg) if $self->{message_cb};

            ## FIXME: this logic was more of infered than learned, but I remember seeing 25% somewhere
#            print STDERR ">>>> READY CHECK? $self->{in_flight} / $self->{ready_count}\n";
            $self->ready($self->{ready_count})
              if $self->{ready_count} and $self->{in_flight} / $self->{ready_count} > .25;
          }
          else {
            $err_cb->($self, qq{unexpected frame type '$frame_type'});
            $self->_force_disconnect;
            @read_frame = ();
            return;
          }

          ## ... and keep reading those frames
#          print STDERR ">>>> RESET FRAME READER\n";
          $hdl->push_read(@read_frame);
        }
      );
    }
  );

  ## Start with first frame...
  $hdl->push_read(@read_frame);
}

sub _on_success_frame {
  my ($self, $cb) = @_;

  push @{ $self->{success_cb_queue} }, $cb;
}


1;
