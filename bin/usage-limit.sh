#!/bin/bash
# ループのログが Claude の利用上限で終わっていれば、解除の時刻（UNIX 時刻）を出す。手動ループの見張り役（askhub-manual.sh watch-final）が使う。
#   usage: bin/usage-limit.sh <ログ>
# 上限で終わっていれば解除の時刻を出して 0、上限のメッセージが無い・ログを読めなければ何も出さずに 1 で終わる。
#
# 読み方はオーケストレーター（shilokuma-inc/ask-hub-apple の AskHubKit/Sources/OrchestratorKit/UsageLimit.swift）と同じ:
#   - ログの末尾（8 KB）の、空行を除いた最後の 5 行から、最後の上限のメッセージ（limit を含み、hit your か limit reached を含む行）を読む
#   - `You've hit your session limit · resets 12pm (Asia/Tokyo)`・`… · resets Oct 7, 9am (Asia/Tokyo)`: その時刻。
#     時刻だけなら、ログの更新時刻より後の最初のその時刻。日付があってログの更新時刻の 1 日以上前なら翌年。タイムゾーンが無ければこの Mac のもの
#   - `Claude AI usage limit reached|1759456800`: その UNIX 時刻（ログの更新時刻の 8 日より先なら、読めなかったものとみなす）
#   - 解除の時刻を読めなければ、ログの更新時刻の 1 時間後
# オーケストレーターと違い、解除の時刻がログの更新時刻より後でなければ読めなかったものとみなす
# （過去の時刻ですぐに再開して、また上限で止まるのを繰り返さない）
set -euo pipefail

[[ $# -eq 1 ]] || { sed -n '3p' "$0" | sed 's/^# //' >&2; exit 64; }
[[ -f "$1" && -r "$1" ]] || exit 1

exec perl -e '
use strict;
use warnings;
use POSIX qw(mktime tzset);

my $path = shift;
my $trailing_lines = 5;
my $tail_bytes = 8 * 1024;
my $maximum_wait = 8 * 24 * 60 * 60;

open(my $fh, "<:raw", $path) or exit 1;
my $size = -s $fh;
seek($fh, $size > $tail_bytes ? $size - $tail_bytes : 0, 0) or exit 1;
my $text = do { local $/; <$fh> } // "";
close $fh;
my $logged = (stat $path)[9] // exit 1;
my $fallback = $logged + 60 * 60;

my @lines = grep { length } map { my $l = $_; $l =~ s/^[ \t]+|[ \t]+$//g; $l } split /\r\n|\n|\r/, $text;
@lines = @lines[-$trailing_lines .. -1] if @lines > $trailing_lines;
my ($line) = grep { my $l = lc; $l =~ /limit/ && ($l =~ /hit your/ || $l =~ /limit reached/) } reverse @lines;
exit 1 unless defined $line;

# `12pm`・`5:30am`・`Oct 7, 9am`・`Oct 7 at 9am` を読む
sub reset_date {
  my ($when, $zone) = @_;
  # タイムゾーンの名前が分からなければ、この Mac のタイムゾーンで読む（UTC と取り違えない）
  if (defined $zone && $zone =~ m{^[A-Za-z0-9_+-]+(?:/[A-Za-z0-9_+-]+)*$} && -f "/usr/share/zoneinfo/$zone") {
    $ENV{TZ} = $zone;
    tzset();
  }
  $when =~ /^(?:([A-Za-z]{3})[a-z]*\.?\s+(\d{1,2}),?\s+(?:at\s+)?)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)$/i or return undef;
  my ($month_name, $day, $hour, $minute, $meridiem) = ($1, $2, $3, $4 // 0, lc $5);
  return undef unless $hour >= 1 && $hour <= 12;
  $hour %= 12;
  $hour += 12 if $meridiem eq "pm";
  my @now = localtime($logged);
  if (defined $month_name) {
    my %months = (jan => 0, feb => 1, mar => 2, apr => 3, may => 4, jun => 5, jul => 6, aug => 7, sep => 8, oct => 9, nov => 10, dec => 11);
    my $month = $months{lc $month_name};
    return undef unless defined $month;
    my $date = mktime(0, $minute, $hour, $day, $month, $now[5], 0, 0, -1);
    return undef unless defined $date;
    # 年をまたぐ（12 月のログで `Jan 2`）なら翌年
    return $date < $logged - 24 * 60 * 60 ? mktime(0, $minute, $hour, $day, $month, $now[5] + 1, 0, 0, -1) : $date;
  }
  my $date = mktime(0, $minute, $hour, $now[3], $now[4], $now[5], 0, 0, -1);
  return undef unless defined $date;
  return $date > $logged ? $date : mktime(0, $minute, $hour, $now[3] + 1, $now[4], $now[5], 0, 0, -1);
}

my $reset;
if ($line =~ /usage limit reached\|(\d{9,})/i) {
  # ミリ秒などの桁違いの値で待機が長引かないよう、週の上限（7 日）を超える先は読めなかったものとみなす
  $reset = $1 > $logged + $maximum_wait ? $fallback : $1 + 0;
} elsif ($line =~ /resets\s+(.+?)(?:\s*\(([^)]+)\))?\s*$/i) {
  $reset = reset_date($1, $2) // $fallback;
} else {
  $reset = $fallback;
}
$reset = $fallback unless $reset > $logged;
print "$reset\n";
' "$1"
