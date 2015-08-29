#!/usr/bin/perl -w
use strict;
use Data::Dumper;
use warnings;
use feature qw(say);
use File::Find::Rule;
use Getopt::Std;
use HTML::TreeBuilder::XPath;
use File::Path qw(make_path);
use URI;
use LWP::UserAgent;

my %hosts = (
	'www.mangahere.co' =>  {
		'exists_xpath' => '//span[@id="current_rating"]',
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
	'www.mangapanda.com' =>  {
		'exists_xpath' => '//div[@id="mangaproperties"]',
		'chapters_xpath' => '//div[@id="chapterlist"]/table[@id="listing"]/tr/td/a/@href',
		'postprocess_chapters' => {
				'^' => 'http://www.mangapanda.com',
		},
		'chapters_order' => 0,
		'pages_xpath' => '//select[@id="pageMenu"]/option/@value',
		'postprocess_pages' => {
				'^' => 'http://www.mangapanda.com',
		},
		'image_xpath' => '//img[@id="img"]/@src',
		'image_extension' => qr/\.([^\.]*)$/,
		'split_pages' => 1,
		'local_chapters' => qr/^[cv][0-9]+$/,
		'grab_chapters' => {
			'1' => qr/\/chapter-([0-9]+)\.html$/,
			'2' => qr/\/([\.0-9]+)$/,
		},
		'post_find' => {},
		'reload_page_regexp' => qr/\/[0-9]+$/,
	},
	'www.goodmanga.net' =>  {
		'exists_xpath' => '//img[@id="series_image"]/@src',
		'chapters_xpath' => '//div[@id="chapters"]/ul/li/a/@href',
		'chapters_order' => 1,
		'pages_xpath' => '//div[@id="manga_nav_top"]/span/span[last()]',
		'build_pages' => {
			'where' => '$',
			'pages' => qr/([0-9]+)$/,
			'start' => 2,
			'prepare' => {
				'$' => '/'
			},
		},
		'image_xpath' => '//div[@id="manga_viewer"]/descendant-or-self::img/@src',
		'image_extension' => qr/\.([^\.]*)$/,
		'split_pages' => 1,
		'local_chapters' => qr/^[0-9]+$/,
		'grab_chapters' => {
			'1' => qr/\/([\.0-9]+)$/,
		},
		'post_find' => {},
		'reload_page_regexp' => qr/chapter\/[0-9]+\/[0-9]+$/,
		'chapters_pagination' => '//ul[@class="pagination"]/li/button/@href',
		'chapters_pagination_hidden' => 1,
	},
	'bato.to' =>  {
		'exists_xpath' => '//div[@id="content"]/div[2]/div/h2[@class="maintitle"]',
		'chapters_xpath' => '//table[contains(@class,"ipb_table") and contains(@class,"chapters_list")]/tbody/tr[contains(@class,"row") and contains(@class,"lang_English") and contains(@class,"chapter_row")]/td[1]/a/@href',
		'chapters_order' => 1,
		'pages_xpath' => '//select[@id="page_select"]/option/@value',
		'image_xpath' => '//img[@id="comic_page"]/@src',
		'image_extension' => qr/\.([^\.]*)$/,
		'split_pages' => 2,
		'local_chapters' => qr/^[chv]+[0-9v_]+$/,
		'grab_chapters' => {
			'1' => qr/_(v[0-9]+)_(ch[^_]+)_by_/,
			'2' => qr/_(ch[^_]+)_by_/,
		},
		'post_find' => {},
		'reload_page_regexp' => qr/\/[0-9]+$/,
	},
);

my $useragent = LWP::UserAgent->new->agent();

sub get_html_content {
 my ($url, $function) = @_;
 my $lwp_response = LWP::UserAgent->new(agent => $useragent)->get( $url );

 if ( !$lwp_response->is_success )
 {
  print "Get failed: ".$lwp_response->status_line." in ".$function."\n";
  exit 1;
 }
 return $lwp_response->decoded_content;
}

sub check_host {
 my ($hosts,$host) = @_;
 return defined($hosts->{ $host });
}

sub get_chapters_pagination {
 my ($tree,$manga_host,$visited_pages) = @_;
 my @pagination;
 #Get first page
 @pagination = $tree->findvalues ( $manga_host->{ 'chapters_pagination' } ) if defined $manga_host->{ 'chapters_pagination' };
 #Next visit all pagination pages if we have to.
 if ( defined ($manga_host->{ 'chapters_pagination_hidden' }) ) {
  if ( not defined $visited_pages ) {
   $visited_pages = {};
  }

  foreach ( @pagination ) {
   if ( not defined $visited_pages->{$_} ) {
    $visited_pages->{$_}=1;
    my $tree = HTML::TreeBuilder::XPath->new;
    $tree->parse( get_html_content($_, "get_chapter_pagination") );
    $tree->eof;
    #Get unique pages
    @pagination = do {
     my %seen; grep { !$seen{$_}++ }
     (@pagination , get_chapters_pagination( $tree, $manga_host, $visited_pages ))
    };
   }
  }

 }
 return @pagination;
}

sub get_chapters {
 my ($tree,$manga_host, @pagination) = @_;
 my %chapters = ();
 my @links;
 my $id;
 #undef is for page we are on right now.
 foreach my $page ( (undef,@pagination) ) {
  if( defined $page ) {
   $tree = HTML::TreeBuilder::XPath->new;
   $tree->parse( get_html_content( $page, "get_chapters") );
   $tree->eof;
  }
  (@links) = (@links, $tree->findvalues ( $manga_host->{ 'chapters_xpath' } ));
  $tree->delete;
 }
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
  if( defined $manga_host->{ 'postprocess_chapters' } ) {
   foreach ( keys %{$manga_host->{ 'postprocess_chapters' }} ) {
    $chapters{ join("/", @key) }{'url'} =~ s/$_/$manga_host->{ 'postprocess_chapters' }->{$_}/;
   }
  }
 }
 return %chapters;
}

sub get_pages {
 my ($tree, $manga_host,$original_url) = @_;
 my @pages;
 @pages = $tree->findvalues ( $manga_host->{ 'pages_xpath' } );
 if( defined $manga_host->{ 'build_pages' } ) {
  if ( defined $manga_host->{ 'build_pages' }->{ 'prepare' } ) {
   foreach (sort keys ( %{$manga_host->{ 'build_pages' }->{ 'prepare' }} )) {
    $original_url =~ s/$_/$manga_host->{ 'build_pages' }->{ 'prepare' }->{$_}/;
   }
  }
  @pages = ($original_url, map { my $url = $original_url; $url =~ s/$manga_host->{ 'build_pages' }->{ 'where' }/$_/; $url } ($manga_host->{ 'build_pages' }->{ 'start' }..do { (my $p) = $pages[0] =~ $manga_host->{ 'build_pages' }->{ 'pages' }; $p }));
 }
 if( defined $manga_host->{ 'postprocess_pages' } ) {
   foreach my $r ( keys %{$manga_host->{ 'postprocess_pages' }} ) {
    map { s/$r/$manga_host->{ 'postprocess_pages' }->{$r}/ } @pages;
   }
 }
 return @pages[0..$#pages/$manga_host->{ 'split_pages' }];
}

sub get_image {
 my ($chapter_tree,$manga_host,$directory,$page,$pages) = @_;
 my $image_url = $chapter_tree->findvalue ( $manga_host->{ 'image_xpath' } ) ;
 if ($image_url) {
  my ($extension) = $image_url =~ $manga_host->{ 'image_extension' };
  my $zerofill = length($pages);
  my $imgname = sprintf("%0${zerofill}d.%s",$page,$extension);
  my $ua = LWP::UserAgent->new(agent => $useragent);
  return $ua->get($image_url, ':content_file' => $directory.'/'.$imgname);
 } else {
  return undef;
 }
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
 foreach (sort { $chapters->{$a}->{'id'} <=> $chapters->{$b}->{'id'} } keys %{$chapters}) {
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
 say " -u '<user-agent>' define user-agent string (some hosts block lwp default)";
 say "";
}

my %opt=();
getopts("m:r:u:nlah", \%opt) or die "Please use -h for help.";

my @conflict_opts = ( [ 'r', 'n' ], [ 'a', 'n' ]);
foreach my $conflicts (@conflict_opts) {
 if ( ( grep { exists $opt{$_} } @$conflicts ) > 1 ) {
  say "Select one of ", join(",",@$conflicts);
  exit(1);
 }
}

if ( not defined $opt{m} or defined $opt{h}) {
 print_help();
 exit(0);
}

if ( defined $opt{u} ) {
 $useragent=$opt{u};
}

my $manga_url = $opt{m};

my $manga_host = URI->new( qq(${manga_url}/) )->host;

if ( !check_host(\%hosts, $manga_host) ) {
 say "Host is not supported";
 exit(1);
}

my $manga_page_content = get_html_content( $manga_url, 'main' );

my $manga_tree = HTML::TreeBuilder::XPath->new;

$manga_tree->parse($manga_page_content);
$manga_tree->eof;

if( !manga_exists($manga_tree,$hosts{ $manga_host }{ 'exists_xpath' })) {
 say "Manga doesn't exists";
 exit(1);
}

my @pagination = get_chapters_pagination($manga_tree, $hosts{ $manga_host });

my %chapters = get_chapters($manga_tree, $hosts{ $manga_host }, @pagination);

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

foreach my $chapter (sort { $chapters{$a}{'id'} <=> $chapters{$b}{'id'} } keys(%chapters)) {

next if defined $chapters{$chapter}{'removed'};

my $chapter_tree= HTML::TreeBuilder::XPath->new;
$chapter_tree->parse( get_html_content( $chapters{$chapter}{url}, "main_chapter_tree") );
$chapter_tree->eof;
say $chapters{$chapter}{url};

if ( not -d $chapter) {
 make_path($chapter);
}

my @pages = get_pages($chapter_tree, $hosts{ $manga_host }, $chapters{$chapter}{url});

while (my ($page, $page_url) = each @pages) {
 if ( $page_url =~ $hosts{ $manga_host }{ 'reload_page_regexp' } ) {
  $chapter_tree = HTML::TreeBuilder::XPath->new;
  $chapter_tree->parse( get_html_content( $page_url, "main_pages") );
  $chapter_tree->eof;
 }
 $page++;
 my $pages = @pages;
 my $res = get_image($chapter_tree,$hosts{ $manga_host },$chapter,$page,$pages);
 if(!$res || !$res->is_success) {
  say "Error chapter ", join(" ", $chapter, "page", $page, "/", $pages, "url:", $page_url);
 } else {
  say "Got chapter ", join(" ", $chapter, "page", $page, "/", $pages);
 }
 $chapter_tree->delete;
}

}
