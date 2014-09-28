#!/usr/bin/perl -w
use strict;
use Data::Dumper;
use warnings;
use WWW::Mechanize;
use feature qw(say);
use File::Find;
use Getopt::Std;
use HTML::TreeBuilder::XPath;
use File::Path qw(make_path);

sub get_chapters {
 my ($tree,$manga) = @_;
 my @links = $tree->findvalues ( '//div[@class="detail_list"]/ul/li/span[@class="left"]/a[@class="color_0077"]/@href');
 my %chapters = ();
 my @key;
 my $id = @links;
 foreach my $link (@links) {
  if ( $link =~ qr/\/${manga}\/c0*([\.0-9]+)\/$/ ) {
   (@key) = $link =~ qr/\/${manga}\/(c[\.0-9]+)\/$/;
  } else {
   (@key) = $link =~ qr/\/(v[0-9]*)\/(c[\.0-9]*)\/$/;
  }
  $chapters{ join("/", @key) }{'url'} = $link;
  $chapters{ join("/", @key) }{'id'} = $id--;
 }
 return %chapters;
}

sub get_pages {
 my ($tree) = @_;
 my @pages = $tree->findvalues ( '//div/span/select[@class="wid60"]/option/@value' );
 return @pages[0..$#pages/2];
}

sub get_image {
 my ($chapter_tree,$directory,$page,$pages) = @_;
 my $image = $chapter_tree->findvalue ( '//img[@id="image"]/@src' ) ;
 if ($image) {
  my ($extension) = $image =~ /\.([^\.]*)\?v=[0-9]+$/;
  my $zerofill = length($pages);
  my $imgname = sprintf("%0${zerofill}d.%s",$page,$extension);
  my $mech = WWW::Mechanize->new();
  my $res = $mech->get($image, ':content_file' => $directory.'/'.$imgname);
  return $res;
 } else {
  return undef;
 }
}

sub move_to_removed {
 my ($chapters, $deleted_chapters, $key) = @_;
 $deleted_chapters->{$key} = $chapters->{$key};
 delete $chapters->{$key};
}

sub get_chapters_to_sync {
 my ($chapters,$local_chapters,$range,$only_new) = @_;
 #remote local chapters
 my %local = map { $_ => 1 } @{$local_chapters};
 my @chapters = keys %{$chapters};
 foreach ( grep { $local{ $_ } } @chapters) {
  $chapters->{$_}->{removed}=1;
 }
 if ( @{$range} ) {
  foreach my $chapter (sort keys(%{$chapters})) {
   if ( $chapters->{$chapter}->{'id'} < @{$range}[0] || $chapters->{$chapter}->{'id'} > @{$range}[1] ) {
    $chapters->{$chapter}->{removed}=1;
   }
  }
 } elsif ($only_new) {
  if(@$local_chapters) {
   my $max = ((sort @$local_chapters)[-1]);
   my $remove = 1;
   foreach my $chapter (sort keys(%{$chapters})) {
     $chapters->{$chapter}->{removed}=1 if $remove;
     $remove = 0 if $chapter eq $max;
   }
  }
 }
}

#find2perl -type d -name "[cv][.0-9]*"
sub find_chapter_directories {
 my @chapter_directories;
 File::Find::find({
	wanted => sub {
		my ($dev,$ino,$mode,$nlink,$uid,$gid,$name);
		(($dev,$ino,$mode,$nlink,$uid,$gid) = lstat($_)) &&
		-d _ &&
		/^[cv][\.0-9]*.*\z/s
		&& $File::Find::name =~ s/^..//
		&& push(@chapter_directories,$File::Find::name);
	}
 }, '.');
 while (my ($index, $directory) = each @chapter_directories) {
  splice(@chapter_directories,$index,1) if $directory =~ /v[\.0-9]*$/;
 }
 return @chapter_directories;
}

sub manga_exists {
 my ($manga_tree) = @_;
 if($manga_tree->findvalue ( '//span[@id="current_rating"]') ){
  return 1;
 }
 return 0;
}

sub list_chapters {
 my ($chapters) = @_;
 foreach (sort keys %{$chapters}) {
  say "(",$chapters->{$_}->{'id'},") ", $_, " => ", (defined ($chapters->{$_}->{'removed'}) ) ? 'Skip' : 'Download';
 }
}

sub print_help {
 say "";
 say "Download mangas from mangahere.co";
 say "";
 say " -h this help message";
 say " -m <manga_tile> manga title from url http://www.mangahere.co/manga/<manga_title>/";
 say " -r <range> chapter range eg. 1 or 1-3";
 say " -l list what would be downloaded";
 say " -n catch only the newest chapters (only if you have already downloaded something)";
 say "";
}

my %opt=();
getopts("m:r:nlah", \%opt) or die "Please use -h for help.";

my @conflict_opts = ( [ 'r', 'n' ], [ 'a', 'n' ]);
foreach my $conflicts (@conflict_opts) {
 if ( ( grep { exists $opt{$_} } @$conflicts ) > 1 ) {
  say "Select one of ", join(",",@$conflicts);
  exit(1);
 }
}

if ( defined $opt{h}) {
 print_help();
 exit(0);
}

if (not defined $opt{m}) {
 say "Specify manga with -m <manga_name_from_url>";
 exit(1);
}

my ($manga) = $opt{m} =~ /([a-z0-9_]+)/;

my $manga_tree = HTML::TreeBuilder::XPath->new_from_url( qq(http://www.mangahere.co/manga/${manga}/) );

if( !manga_exists($manga_tree)) {
 say "Manga doesn't exists";
 exit(1);
}

my %chapters = get_chapters($manga_tree, $manga);

my @local_chapters;
if ( not defined $opt{'a'} ) {
 @local_chapters = find_chapter_directories();
}

if ( defined $opt{'n'} and @local_chapters and not defined $chapters{ ((sort @local_chapters)[-1]) } ) {
 say "Local chapters not found in chapter list, unable to determine newest chapter.";
 exit(1);
}

my @range=();
if (defined $opt{r}) {
 if($opt{r} =~ /^[\.0-9]+(-[\.0-9]+)??$/) {
  (@range) = grep defined && /^[\.0-9]+$/, $opt{r} =~ /^([\.0-9]+)(-([\.0-9]+))??$/;
  $range[1]=$range[0] if not defined $range[1];
  foreach (@range) {
   if ( $_ > scalar keys(%chapters) ) {
    say "Specified chapters don't exist";
    exit(1);
   }
  }
  @range = sort { $a <=> $b} @range;
 } else {
  say "Range is invalid";
  exit(1);
 }
}


get_chapters_to_sync(\%chapters, \@local_chapters, \@range, defined $opt{'n'});

if (defined $opt{l}) {
 list_chapters(\%chapters);
 exit(0);
}

foreach my $chapter (sort keys(%chapters)) {

next if defined $chapters{$chapter}{'removed'};

my $chapter_tree= HTML::TreeBuilder::XPath->new_from_url( $chapters{$chapter}{url} );
say $chapters{$chapter}{url};

if ( not -d $chapter) {
 make_path($chapter);
}

my @pages = get_pages($chapter_tree);

while (my ($page, $page_url) = each @pages) {
 if ( $page_url =~ /html$/ ) {
  $chapter_tree= HTML::TreeBuilder::XPath->new_from_url( $page_url );
 }
 $page++;
 my $pages = @pages;
 my $res = get_image($chapter_tree,$chapter,$page,$pages);
 if(!$res || !$res->is_success) {
  say "Error chapter ", join(" ", $chapter, $page, "/", $pages, "url:", $page_url);
 } else {
  say "Got chapter ", join(" ", $chapter, $page, "/", $pages);
 }
 $chapter_tree->delete;
}

}
