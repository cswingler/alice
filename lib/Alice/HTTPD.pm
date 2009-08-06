package Alice::HTTPD;

use strict;
use warnings;

use Moose;
use bytes;
use Encode;
use Time::HiRes qw/time/;
use POE;
use POE::Component::Server::HTTP;
use JSON;
use Template;
use URI::QueryParam;
use IRC::Formatting::HTML;
use YAML qw/DumpFile/;

has 'config' => (
  is  => 'ro',
  isa => 'HashRef',
  required => 1,
  trigger => sub {
    my $self = shift;
    POE::Component::Server::HTTP->new(
      Port            => $self->config->{port},
      ContentHandler  => {
        '/serverconfig' => sub{$self->server_config(@_)},
        '/config'       => sub{$self->send_config(@_)},
        '/save'         => sub{$self->save_config(@_)},
        '/view'         => sub{$self->send_index(@_)},
        '/stream'       => sub{$self->setup_stream(@_)},
        '/favicon.ico'  => sub{$self->not_found(@_)},
        '/say'          => sub{$self->handle_message(@_)},
        '/static/'      => sub{$self->handle_static(@_)},
        '/autocomplete' => sub{$self->handle_autocomplete(@_)},
      },
      StreamHandler    => sub{$self->handle_stream(@_)},
    );
  },
);

before qw/send_config save_config send_index setup_stream not_found
          handle_message handle_static handle_autocomplete server_config/ => sub {
  $_[1]->header(Connection => 'close');
  $_[2]->header(Connection => 'close');
  $_[2]->streaming(0);
  $_[2]->code(200);
};

has 'irc' => (
  is  => 'rw',
  isa => 'Alice::IRC',
  weak_ref => 1,
);

has 'streams' => (
  is  => 'rw',
  isa => 'ArrayRef[POE::Component::Server::HTTP::Response]',
  default => sub {[]},
);

has 'seperator' => (
  is  => 'ro',
  isa => 'Str',
  default => '--xalicex',
);

has 'commands' => (
  is => 'ro',
  isa => 'ArrayRef[Str]',
  default => sub { [qw/join part names topic me query/] },
  lazy => 1,
);

has 'tt' => (
  is => 'ro',
  isa => 'Template',
  default => sub {
    Template->new(
      INCLUDE_PATH => 'data/templates',
      ENCODING     => 'UTF8'
    );
  },
);

has 'msgbuffer' => (
  is => 'rw',
  isa => 'ArrayRef[HashRef]',
  default => sub {[]},
);

after 'msgbuffer' => sub {
  my $self = shift;
  while (@{$self->{msgbuffer}} >= 100) {
    shift @{$self->{msgbuffer}};
  }
};

has 'msgid' => (
  is => 'rw',
  isa => 'Int',
  default => 0,
);

after 'msgid' => sub {
  my $self = shift;
  $self->{msgid} = $self->{msgid} + 1;
};

sub setup_stream {
  my ($self, $req, $res) = @_;
  
  # XHR tries to reconnect again with this header for some reason
  return 200 if defined $req->header('error');
  
  $self->log_debug("opening a streaming http connection");
  $res->streaming(1);
  $res->content_type('multipart/mixed; boundary=xalicex; charset=utf-8');
  $res->{msgs} = [];
  $res->{actions} = [];
  
  # populate the msg queue with any buffered messages that are newer
  # than the provided msgid
  if (defined (my $msgid = $req->uri->query_param('msgid'))) {
    $res->{msgs} = [ grep {$_->{msgid} > $msgid} @{$self->{msgbuffer}} ];
  }
  push @{$self->streams}, $res;
  return 200;
}

sub handle_stream {
  my ($self, $req, $res) = @_;
  if ($res->is_error) {
    $self->end_stream($res);
    return;
  }
  if (@{$res->{msgs}} or @{$res->{actions}}) {
    my $output;
    if (! $res->{started}) {
      $res->{started} = 1;
      $output .= $self->seperator."\n";
    }
    $output .= to_json({msgs => $res->{msgs}, actions => $res->{actions}, time => time});
    my $padding = " " x (1024 - bytes::length $output);
    $res->send($output . $padding . "\n" . $self->seperator . "\n");
    if ($res->is_error) {
      $self->end_stream($res);
      return;
    }
    else {
      $res->{msgs} = [];
      $res->{actions} = [];
    }
  }
  #$res->continue_delayed(0.5);
}

sub end_stream {
  my ($self, $res) = @_;
  $self->log_debug("closing a streaming http connection");
  for (0 .. scalar @{$self->streams} - 1) {
    if (! $self->streams->[$_] or ($res and $res == $self->streams->[$_])) {
      splice(@{$self->streams}, $_, 1);
    }
  }
  $res->close;
  $res->continue;
}

sub handle_message {
  my ($self, $req, $res) = @_;
  my $msg  = $req->uri->query_param('msg');
  my $chan = lc $req->uri->query_param('chan');
  my $session = $req->uri->query_param('session');
  my $irc = $self->irc->connection_from_alias($session);
  return 200 unless $session;
  if (length $msg) {
    if ($msg =~ /^\/query (\S+)/) {
      $self->create_tab($1, $session);
    }
    elsif ($msg =~ /^\/join (.+)/) {
      $irc->yield("join", $1);
    }
    elsif ($msg =~ /^\/part\s?(.+)?/) {
      $irc->yield("part", $1 || $chan);
    }
    elsif ($msg =~ /^\/window new (.+)/) {
      $self->create_tab($1, $session);
    }
    elsif ($msg =~ /^\/n(?:ames)?/ and $chan) {
      $self->show_nicks($chan, $session);
    }
    elsif ($msg =~ /^\/topic\s?(.+)?/) {
      if ($1) {
        $irc->yield("topic", $chan, $1);
      }
      else {
        my $topic = $irc->channel_topic($chan);
        $self->send_topic(
          $topic->{SetBy}, $chan, $session, decode_utf8($topic->{Value})
        );
      }
    }
    elsif ($msg =~ /^\/me (.+)/) {
      my $nick = $irc->nick_name;
      $self->display_message($nick, $chan, $session, decode_utf8("• $1"));
      $irc->yield("ctcp", $chan, "ACTION $1");
    }
    else {
      $self->log_debug("sending message to $chan");
      my $nick = $irc->nick_name;
      $self->display_message($nick, $chan, $session, decode_utf8($msg));
      $irc->yield("privmsg", $chan, $msg);
    }
  }

  return 200;
}

sub handle_static {
  my ($self, $req, $res) = @_;
  my $file = $req->uri->path;
  my ($ext) = ($file =~ /[^\.]\.(.+)$/);
  if (-e "data$file") {
    open my $fh, '<', "data$file";
    $self->log_debug("serving static file: $file");
    if ($ext =~ /png|gif|jpg|jpeg/i) {
      $res->content_type("image/$ext"); 
    }
    elsif ($ext =~ /js/) {
      $res->header("Cache-control" => "no-cache");
      $res->content_type("text/javascript");
    }
    elsif ($ext =~ /css/) {
      $res->header("Cache-control" => "no-cache");
      $res->content_type("text/css");
    }
    else {
      $self->not_found($req, $res);
    }
    my @file = <$fh>;
    $res->content(join "", @file);
    return 200;
  }
  $self->not_found($req, $res);
}

sub send_index {
  my ($self, $req, $res) = @_;
  $self->log_debug("serving index");
  $res->content_type('text/html; charset=utf-8');
  my $output = '';
  my $channels = [];
  for my $irc ($self->irc->connections) {
    my $session = $irc->session_alias;
    for my $channel (keys %{$irc->channels}) {
      push @$channels, {
        chanid  => channel_id($channel, $session),
        chan    => $channel,
        session => $session,
        topic   => $irc->channel_topic($channel),
        server  => $irc,
      }
    }
  }
  $self->tt->process('index.tt', {
    channels  => $channels,
    style     => $self->config->{style} || "default",
  }, \$output) or die $!;
  $res->content($output);
  return 200;
}

sub send_config {
  my ($self, $req, $res) = @_;
  $self->log_debug("serving config");
  $res->header("Cache-control" => "no-cache");
  my $output = '';
  $self->tt->process('config.tt', {
    config      => $self->config,
    connections => [ sort {$a->{alias} cmp $b->{alias}}
                     $self->irc->connections ],
  }, \$output);
  $res->content($output);
  return 200;
}

sub server_config {
  my ($self, $req, $res) = @_;
  $self->log_debug("serving blank server config");
  $res->header("Cache-control" => "no-cache");
  my $name = $req->uri->query_param('name');
  $self->log_debug($name);
  my $config = '';
  $self->tt->process('server_config.tt', {name => $name}, \$config);
  my $listitem = '';
  $self->tt->process('server_listitem.tt', {name => $name}, \$listitem);
  $res->content(to_json({config => $config, listitem => $listitem}));
  return 200;
}

sub save_config {
  my ($self, $req, $res) = @_;
  $self->log_debug("saving config");
  my $new_config = {};
  my $servers;
  for my $name ($req->uri->query_param) {
    next unless $req->uri->query_param($name);
    if ($name =~ /^(.+)_(.+)/) {
      if ($2 eq "channels") {
        $new_config->{$1}{$2} = [$req->uri->query_param($name)];
      }
      else {
        $new_config->{$1}{$2} = $req->uri->query_param($name);
      }
    }
  }
  for my $newserver (values %$new_config) {
    if (! exists $self->config->{servers}{$newserver->{name}}) {
      $self->irc->add_server($newserver->{name}, $newserver);
    }
    $self->config->{servers}{$newserver->{name}} = $newserver;
  }
  DumpFile($ENV{HOME}.'/.alice.yaml', $self->config);
}

sub handle_autocomplete {
  my ($self, $req, $res) = @_;
  $res->content_type('text/html; charset=utf-8');
  my $query = $req->uri->query_param('msg');
  my $chan = $req->uri->query_param('chan');
  my $session_alias = $req->uri->query_param('session');
  my $irc = $self->irc->connection_from_alias($session_alias);
  ($query) = $query =~ /((?:^\/)?[\d\w]*)$/;
  return 200 unless $query;
  $self->log_debug("handling autocomplete for $query");
  my @matches = sort {lc $a cmp lc $b} grep {/^\Q$query\E/i} $irc->channel_list($chan);
  push @matches, sort grep {/^\Q$query\E/i} map {"/$_"} @{$self->commands};
  my $html = '';
  $self->tt->process('autocomplete.tt',{matches => \@matches}, \$html) or die $!;
  $res->content($html);
  return 200;
}

sub not_found {
  my ($self, $req, $res) = @_;
  $self->log_debug("serving 404:", $req->uri->path);
  $res->code(404);
  return 404;
}

sub send_topic {
  my ($self, $who, $channel, $session, $topic) = @_;
  my $nick = ( split /!/, $who)[0];
  $self->display_event($nick, $channel, $session, "topic", $topic);
}

sub display_event {
  my ($self, $nick, $channel, $session, $event_type, $msg) = @_;
  my $event = {
    type      => "message",
    event     => $event_type,
    nick      => $nick,
    chan      => $channel,
    chanid    => channel_id($channel, $session),
    session   => $session,
    message   => $msg,
    msgid     => $self->msgid,
    timestamp => make_timestamp(),
  };
  my $html = '';
  $self->tt->process("event.tt", $event, \$html);
  $event->{full_html} = $html;
  push @{$self->msgbuffer}, $event;
  $self->send_data($event);
}

sub display_message {
  my ($self, $nick, $channel, $session, $text) = @_;
  my $html = IRC::Formatting::HTML->formatted_string_to_html($text);
  my $mynick = $self->irc->connection_from_alias($session)->nick_name;
  my $msg = {
    type      => "message",
    event     => "say",
    nick      => $nick,
    chan      => $channel,
    chanid    => channel_id($channel, $session),
    session   => $session,
    msgid     => $self->msgid,
    self      => $nick eq $mynick,
    html      => $html,
    message   => $text,
    highlight => $text =~ /\b$mynick\b/i || 0,
    timestamp => make_timestamp(),
  };
  $html = '';
  $self->tt->process("message.tt", $msg, \$html);
  $msg->{full_html} = $html;
  push @{$self->msgbuffer}, $msg;
  $self->send_data($msg);
}

sub clients {
  my $self = shift;
  return scalar @{$self->streams};
}

sub create_tab {
  my ($self, $name, $session) = @_;
  my $action = {
    type      => "action",
    event     => "join",
    chan      => $name,
    chanid    => channel_id($name, $session),
    session   => $session,
    timestamp => make_timestamp(),
  };
  my $chan_html = '';
  $self->tt->process("channel.tt", $action, \$chan_html);
  $action->{html}{channel} = $chan_html;
  my $tab_html = '';
  $self->tt->process("tab.tt", $action, \$tab_html);
  $action->{html}{tab} = $tab_html;
  $self->send_data($action);
  $self->log_debug("sending a request for a new tab: $name " . $action->{chanid}) if $self->clients;
}

sub close_tab {
  my ($self, $name, $session) = @_;
  $self->send_data({
    type      => "action",
    event     => "part",
    chanid    => channel_id($name, $session),
    chan      => $name,
    session   => $session,
    timestamp => make_timestamp(),
  });
  $self->log_debug("sending a request to close a tab: $name") if $self->clients;
}

sub send_data {
  my ($self, $data) = @_;
  return unless $self->clients;
  for my $res (@{$self->streams}) {
    if ($data->{type} eq "message") {
      push @{$res->{msgs}}, $data;
    }
    elsif ($data->{type} eq "action") {
      push @{$res->{actions}}, $data;
    }
  }
  $_->continue for @{$self->streams};
}

sub show_nicks {
  my ($self, $chan, $session) = @_;
  my $irc = $self->irc->connection_from_alias($session);
  $self->send_data({
    type    => "message",
    event   => "announce",
    chanid  => channel_id($chan, $session),
    chan    => $chan,
    session => $session,
    str     => format_nick_table($irc->channel_list($chan))
  });
}

sub format_nick_table {
  my @nicks = @_;
  return "" unless @nicks;
  my $maxlen = 0;
  for (@nicks) {
    my $length = length $_;
    $maxlen = $length if $length > $maxlen;
  }
  my $cols = int(74  / $maxlen + 2);
  my (@rows, @row);
  for (sort {lc $a cmp lc $b} @nicks) {
    push @row, $_ . " " x ($maxlen - length $_);
    if (@row >= $cols) {
      push @rows, [@row];
      @row = ();
    }
  }
  push @rows, [@row] if @row;
  return join "\n", map {join " ", @$_} @rows;
}

sub channel_id {
  my $id = join "_", @_;
  $id =~ s/[#&]/chan_/;
  return lc $id;
}

sub make_timestamp {
  return sprintf("%02d:%02d", (localtime)[2,1])
}

sub log_debug {
  my $self = shift;
  print STDERR join " ", @_, "\n" if $self->config->{debug};
}

sub log_info {
  print STDERR join " ", @_, "\n";
}

__PACKAGE__->meta->make_immutable;
no Moose;
1;
