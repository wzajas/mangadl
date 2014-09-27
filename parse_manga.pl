#!/usr/bin/perl -w
use strict;
use Data::Dumper;
use warnings;
use WWW::Mechanize;
use feature qw(say);
use File::Find;
use Getopt::Std;
use HTML::TreeBuilder::XPath;

sub get_chapters {
 my ($tree,$manga) = @_;
 my @links = $tree->findvalues ( '//div[@class="detail_list"]/ul/li/span[@class="left"]/a[@class="color_0077"]/@href');
 my %chapters = map { $_ =~ qr/\/c0*([\.0-9]+)\/$/ , $_ } @links;
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
 my ($chapters,$chapter_directories,$range,$only_new,$removed_chapters) = @_;
 my %local = map { $_ => 1 } @{$chapter_directories};
 my @chapters = keys %{$chapters};
 foreach ( grep { $local{ $_ } } @chapters) {
  move_to_removed($chapters,$removed_chapters,$_);
 }
 if ( @{$range} ) {
  foreach ( grep { $_ <@{$range}[0] || $_ > @{$range}[1] } keys %{$chapters} ) {
   move_to_removed($chapters,$removed_chapters,$_);
  }
 } elsif ($only_new) {
  if(@$chapter_directories) {
   foreach ( grep { $_ <= ((sort {$a <=> $b} @$chapter_directories)[-1]) } keys %{$chapters} ) {
    move_to_removed($chapters,$removed_chapters,$_);
   }
  }
 }
}

#http://stackoverflow.com/questions/3795490/how-can-i-use-filefind-in-perl
sub find_chapter_directories {
 my @chapter_directories;
 find( {
        preprocess => \&limit_depth,
        wanted => sub { push @chapter_directories,  $_ =~ /c0+([\.0-9]*)/ if -d $_ and $_ =~ /^c[\.0-9]*$/; }
       },
       ".");
 return @chapter_directories;
}

sub limit_depth {
 my $depth = $File::Find::dir =~ tr[/][];
 if ($depth < 1) {
  return @_;
 } else {
  return grep { not -d } @_;
 }
}

sub chapter_directories {
     $_ =~ /c0+([\.0-9]*)/ if -d $_ and $_ =~ /^c[\.0-9]*$/;
}

sub chapters_exists {
 my ($chapters, $check) = @_;
 foreach (@{$check}) {
  return 0 if not defined $chapters->{ $_ };
 }
 return 1;
}

sub manga_exists {
 my ($manga_tree) = @_;
 if($manga_tree->findvalue ( '//span[@id="current_rating"]') ){
  return 1;
 }
 return 0;
}

sub list_chapters {
 my ($chapters,$deleted_chapters) = @_;
 my %tmp;
 map { $tmp{$_} = 'D' } keys %{$chapters};
 map { $tmp{$_} = 'R' } keys %{$deleted_chapters};
 foreach (sort { $a <=> $b } keys %tmp) {
  say "$_ => $tmp{$_}";
 }
 undef %tmp;
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

my %removed_chapters = ();
my %chapters = get_chapters($manga_tree, $manga);

my @local_chapters;
if ( not defined $opt{'a'} ) {
 @local_chapters = find_chapter_directories();
}

my @range=();
if (defined $opt{r}) {
 if($opt{r} =~ /^[\.0-9]+(-[\.0-9]+)??$/) {
  (@range) = grep defined && /^[\.0-9]+$/, $opt{r} =~ /^([\.0-9]+)(-([\.0-9]+))??$/;
  $range[1]=$range[0] if not defined $range[1];
  if(!chapters_exists(\%chapters,\@range))  {
   say "Specified chapters don't exist";
   exit(1);
  }
  @range = sort { $a <=> $b} @range;
 } else {
  say "Range is invalid";
  exit(1);
 }
}

get_chapters_to_sync(\%chapters, \@local_chapters, \@range, defined $opt{'n'},\%removed_chapters);

if (defined $opt{l}) {
 list_chapters(\%chapters,\%removed_chapters);
 exit(0);
}

foreach my $chapter (sort { $a <=> $b } keys(%chapters)) {

my $chapter_tree= HTML::TreeBuilder::XPath->new_from_url( $chapters{$chapter} );

my ($chapter) = $chapters{$chapter} =~ /\/(c[\.0-9]*)\/$/;
if ( not -d $chapter) {
 mkdir $chapter;
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
