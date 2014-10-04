#!/usr/bin/perl -w
use strict;
use Data::Dumper;
use warnings;
use WWW::Mechanize;
use feature qw(say);
use File::Find::Rule;
use Getopt::Std;
use HTML::TreeBuilder::XPath;
use File::Path qw(make_path);
use URI;

my %hosts = (
	'www.mangahere.co' =>  {
		'exists_xpath' => '//span[@id="current_rating"]',
		'manga_regex' => qr/manga\/([a-z_]*)\/$/,
		'chapters_xpath' => '//div[@class="detail_list"]/ul/li/span[@class="left"]/a[@class="color_0077"]/@href',
		'chapters_order' => 1,
		'pages_xpath' => '//div/span/select[@class="wid60"]/option/@value',
		'image_xpath' => '//img[@id="image"]/@src',
		'image_extension' => qr/\.([^\.]*)\?v=[0-9]+$/,
		'split_pages' => 2,
		'local_chapters' => qr/^[cv][0-9]+$/,
		'grab_chapters' => {
			'1' => qr/\/(v[0-9]+)\/(c[\.0-9]+)\/$/,
			'2' => qr/\/(c[\.0-9]+)\/$/,
		},
		'post_find' => {
			'1' => qr/^v[0-9]+$/,
		},
		'reload_page_regexp' => qr/html$/,
	},
);

sub get_chapters {
 my ($tree,$manga_host) = @_;
 my @links = $tree->findvalues ( $manga_host->{ 'chapters_xpath' } );
 my %chapters = ();
 my $id;
 $id = @links if $manga_host->{ 'chapters_order' };
 $id = 1 if !$manga_host->{ 'chapters_order' };
 foreach my $link (@links) {
  my @key;
  foreach (sort keys (%{$manga_host->{ 'grab_chapters' }})) {
   if( !@key and $link =~ $manga_host->{ 'grab_chapters' }->{$_} ){
    (@key) = $link =~ $manga_host->{ 'grab_chapters' }->{$_};
   }
  }
  $chapters{ join("/", @key) }{'url'} = $link;
  $chapters{ join("/", @key) }{'id'} = $id-- if $manga_host->{ 'chapters_order' };
  $chapters{ join("/", @key) }{'id'} = $id++ if !$manga_host->{ 'chapters_order' };
 }
 return %chapters;
}

sub get_pages {
 my ($tree, $xpath, $split_pages) = @_;
 my @pages = $tree->findvalues ( $xpath );
 return @pages[0..$#pages/$split_pages];
}

sub get_image {
 my ($chapter_tree,$manga_host,$directory,$page,$pages) = @_;
 my $image = $chapter_tree->findvalue ( $manga_host->{ 'image_xpath' } ) ;
 if ($image) {
  my ($extension) = $image =~ $manga_host->{ 'image_extension' };
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

sub find_chapter_directories {
 my ($host) = @_;
 my @chapter_directories = File::Find::Rule->directory()->name( $host->{'local_chapters'} )->in(".");
 foreach my $remove ($host->{ 'post_find' }) {
  while (my ($index, $directory) = each @chapter_directories) {
   splice(@chapter_directories,$index,1) if $directory =~ $remove;
  }
 }
 return @chapter_directories;
}

sub manga_exists {
 my ($manga_tree,$xpath) = @_;
 if($manga_tree->findvalue ( $xpath ) ){
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
 say " -m <manga_url> ie. http://www.mangahere.co/manga/<manga_title>/";
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
 say "Specify manga with -m <manga_url>";
 exit(1);
}

my $manga_url = $opt{m};

my $manga_host = URI->new( qq(${manga_url}/) )->host;

my ($manga) = $manga_url =~ $hosts{ $manga_host }{ 'manga_regex' };

my $manga_tree = HTML::TreeBuilder::XPath->new_from_url( $manga_url );

if( !manga_exists($manga_tree,$hosts{ $manga_host }{ 'exists_xpath' })) {
 say "Manga doesn't exists";
 exit(1);
}

my %chapters = get_chapters($manga_tree, $hosts{ $manga_host });

my @local_chapters;
if ( not defined $opt{'a'} ) {
 @local_chapters = find_chapter_directories($hosts{ $manga_host });
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

my @pages = get_pages($chapter_tree, $hosts{ $manga_host }{ 'pages_xpath' }, $hosts{ $manga_host }{ 'split_pages' });
;

while (my ($page, $page_url) = each @pages) {
 $chapter_tree= HTML::TreeBuilder::XPath->new_from_url( $page_url ) if $page_url =~ $hosts{ $manga_host }{ 'reload_page_regexp' };
 $page++;
 my $pages = @pages;
 my $res = get_image($chapter_tree,$hosts{ $manga_host },$chapter,$page,$pages);
 if(!$res || !$res->is_success) {
  say "Error chapter ", join(" ", $chapter, $page, "/", $pages, "url:", $page_url);
 } else {
  say "Got chapter ", join(" ", $chapter, $page, "/", $pages);
 }
 $chapter_tree->delete;
}

}
