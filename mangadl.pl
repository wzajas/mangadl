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
use threads;
use Thread::Queue;
use File::Basename;
use File::Spec::Functions;

my %hosts = (
	'www.mangahere.co' =>  {
		'exists_xpath' => '//span[@id="current_rating"]',
		'chapters_xpath' => '//div[@class="detail_list"]/ul/li/span[@class="left"]/a[@class="color_0077"]/@href',
		'chapters_order' => 1,
		'pages_xpath' => '(//div/span/select[@class="wid60"])[last()]/option/@value',
		'image_xpath' => '//img[@id="image"]/@src',
		'image_extension' => qr/\.([^\.]*)\?v=[0-9]+$/,
		'local_chapters' => qr/^[cv][0-9]+$/,
		'grab_chapters' => {
			'1' => qr/\/(v[0-9]+)\/(c[\.0-9]+)\/$/,
			'2' => qr/\/(c[\.0-9]+)\/$/,
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
		'local_chapters' => qr/^[0-9]+$/,
		'grab_chapters' => {
			'1' => qr/\/chapter-([0-9]+)\.html$/,
			'2' => qr/\/([\.0-9]+)$/,
		},
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
		'local_chapters' => qr/^[0-9]+$/,
		'grab_chapters' => {
			'1' => qr/\/([\.0-9]+)$/,
		},
		'reload_page_regexp' => qr/chapter\/[0-9]+\/[0-9]+$/,
		'chapters_pagination' => '//ul[@class="pagination"]/li/button/@href',
		'chapters_pagination_hidden' => 1,
	},
	'bato.to' =>  {
		'exists_xpath' => '//div[@id="content"]/div[2]/div/h2[@class="maintitle"]',
		'chapters_xpath' => '//table[contains(@class,"ipb_table") and contains(@class,"chapters_list")]/tbody/tr[contains(@class,"row") and contains(@class,"lang_English") and contains(@class,"chapter_row")]/td[1]/a/@href',
		'chapters_order' => 1,
		'pages_xpath' => '(//select[@id="page_select"])[last()]/option/@value',
		'image_xpath' => '//img[@id="comic_page"]/@src',
		'image_extension' => qr/\.([^\.]*)$/,
		'local_chapters' => qr/^[chv]+[0-9v_]+$/,
		'grab_chapters' => {
			'1' => qr/_(v[0-9]+)_(ch[^_]+)_by_/,
			'2' => qr/_(ch[^_]+)_by_/,
		},
		'reload_page_regexp' => qr/\/[0-9]+$/,
	},
	'mangafox.me' =>  {
		'exists_xpath' => '//div[@id="series_info"]',
		'chapters_xpath' => '//div[@id="chapters"]/ul/li/div/*[self::h3 or self::h4]/a/@href',
		'chapters_order' => 1,
		'pages_xpath' => '//form[@id="top_bar"]/div/div[@class="l"]',
		'build_pages' => {
			'where' => 'REPLACE',
			'pages' => qr/of ([0-9]+)/,
			'start' => 2,
			'prepare' => {
				'1\.html$' => 'REPLACE.html'
			},
		},
		'image_xpath' => '//img[@id="image"]/@src',
		'image_extension' => qr/\.([^\.]*)$/,
		'local_chapters' => qr/^[cv][\.TBD0-9]+$/,
		'grab_chapters' => {
			'1' => qr/\/(v[TBD0-9]+)\/(c[\.0-9]+)\/1\.html$/,
			'2' => qr/\/(c[\.0-9]+)\/1\.html$/,
		},
		'reload_page_regexp' => qr/\/[0-9]+\.html$/,
	},
);

#Queue for chapters
my $queue = Thread::Queue->new();

my $useragent :shared = LWP::UserAgent->new->agent();;

#Thread pool
my @thr;

#Number of tries for each download
my $try_repeat :shared = 2;

sub download_chapter {
 my ($chapter_url, $chapter, $manga_host, $dir_name) = @_;

 my $directory = canonpath($dir_name."/".$chapter);

 say "Downloading ".$chapter_url." as ".canonpath($directory);
 my $chapter_tree = HTML::TreeBuilder::XPath->new;
 my $content = get_html_content($chapter_url);
 if ( $content->is_error ) {
  say "Couldn't download first page of ".$chapter.", skipping...";
  return 1;
 }
 $chapter_tree->parse( $content->decoded_content );
 $chapter_tree->eof;

 if ( not -d $directory) {
  make_path($directory);
 }

 #Directory is created, files being downloaded
 #Mark directory as incomplete, then remove that mark
 #if no errors are encountered.
 open(my $incomplete_file, '>', canonpath($directory."/.mangadl_incomplete")) or say "Couldn't open .mangadl_incomplete file for ".canonpath($directory);
 close($incomplete_file);

 my $problem=0;

 my @pages = get_pages($chapter_tree, $hosts{ $manga_host }, $chapter_url);

 PAGES_LOOP: while (my ($page, $page_url) = each @pages) {
  if ( $page_url =~ $hosts{ $manga_host }{ 'reload_page_regexp' } ) {
   $chapter_tree = HTML::TreeBuilder::XPath->new;
   my $content = get_html_content( $page_url );
   if ( $content->is_error ) {
    say "Couldn't download page ".$page." from ".$page_url.", skipping...";
    $problem=1;
    next PAGES_LOOP;
   }
   $chapter_tree->parse( $content->decoded_content );
   $chapter_tree->eof;
  }
  $page++;
  my $pages = @pages;
  my $res = get_image($chapter_tree,$hosts{ $manga_host },$directory,$page, $pages);
  if( ref($res) eq "HTTP::Response" ) {
   if( $res->is_success ) {
    say "Got chapter ", join(" ", $chapter, "page", $page, "/", $pages, "(", $directory, ")");
   } else {
    say "Error chapter ", join(" ", $chapter, "page", $page, "/", $pages, "(", $directory, ")", "url:", $page_url, $res->status_line);
    $problem=1;
   }
  } elsif ( $res == 1 ) {
    say "Error chapter couldn't find image on ", join(" ", $chapter, "page", $page, "/", $pages, "(", $directory, ")", "url:", $page_url);
    $problem=1;
  } else {
    say "Page already downloaded skipping ", join(" ", $chapter, "page", $page, "/", $pages, "(", $directory, ")", "url:", $page_url);
  }
  $chapter_tree->delete;
 }

 if ( !$problem ) {
  if ( -f canonpath($directory."/.mangadl_incomplete") ) {
   unlink(canonpath($directory."/.mangadl_incomplete")) or say "Couldn't delete .mangadl_incomplete file for ".$directory;
  }
 }

}

sub get_html_content {
 my ($url) = @_;
 my $lwp_response;
 my $i=0;
 do {
  $lwp_response = LWP::UserAgent->new(agent => $useragent)->get( $url );
  $i++;
 } while( $lwp_response->is_error and $i<$try_repeat);
 return $lwp_response;
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

  PAGINATION: foreach ( @pagination ) {
   if ( not defined $visited_pages->{$_} ) {
    $visited_pages->{$_}=1;
    my $tree = HTML::TreeBuilder::XPath->new;
    my $content = get_html_content($_);
    if ( $content->is_error ) {
     say "Couldn't download pagination from: ".$_.", chapter list will be incomplete";
     next PAGINATION;
    }
    $tree->parse( $content->decoded_content );
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
   my $content = get_html_content( $page );
   if ( $content->is_error ) {
    say "Couldn't get chapters from page: ".$page;
    next;
   }
   $tree->parse( $content->decoded_content );
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
 return @pages[0..$#pages];
}

sub get_image {
 my ($chapter_tree,$manga_host,$directory,$page,$pages,$dir_name) = @_;
 my $image_url = $chapter_tree->findvalue ( $manga_host->{ 'image_xpath' } ) ;
 if ($image_url) {
  my ($extension) = $image_url =~ $manga_host->{ 'image_extension' };
  my $zerofill = length($pages);
  my $imgname = sprintf("%0${zerofill}d.%s",$page,$extension);
  if ( ! -f canonpath($directory.'/'.$imgname) ) {
   my $ua = LWP::UserAgent->new(agent => $useragent);
   return $ua->get($image_url, ':content_file' => canonpath($directory.'/'.$imgname));
  } else {
   return 2;
  }
 } else {
  return 1;
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
 my ($host, $local_directory) = @_;
 my @chapter_directories = File::Find::Rule->directory()->name( $host->{'local_chapters'} )->relative()->in($local_directory);
 my @incomplete_files = File::Find::Rule->file()->name( '.mangadl_incomplete' )->relative()->in($local_directory);
 foreach my $incomplete (@incomplete_files) {
  my $i=0;
  $i++ until $chapter_directories[$i] eq dirname($incomplete) or $i > scalar @chapter_directories;
  splice(@chapter_directories, $i, 1);
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
 say "Download mangas from various manga sites.";
 say "";
 say " -h this help message";
 say " -m <manga_url> ie. http://www.mangahere.co/manga/<manga_title>/";
 say " -r <range> chapter range eg. 1 or 1-3";
 say " -l list what would be downloaded";
 say " -n catch only the newest chapters (only if you have already downloaded something)";
 say " -u '<user-agent>' define user-agent string (some hosts block lwp default)";
 say " -t <int> number of threads";
 say "";
 say "Example: ".$0." -m http://www.your-manga-host/manga/";
 say "Script saves url on first download to .mangadl, so you don't have to type it again.";
 say "";
}

my %opt=();
getopts("m:r:u:t:Rnlah", \%opt) or die "Please use -h for help.";

my @conflict_opts = ( [ 'r', 'n' ], [ 'a', 'n' ], [ 'R', 'm' ]);
foreach my $conflicts (@conflict_opts) {
 if ( ( grep { exists $opt{$_} } @$conflicts ) > 1 ) {
  say "Select one of ", join(",",@$conflicts);
  exit(1);
 }
}

if ( defined $opt{h} ) {
 print_help();
 exit(0);
}

my %manga_urls;

if ( not defined($opt{R}) and -f ".mangadl" ) {
 open(my $info_file, '<', ".mangadl") or die "Couldn't read .mangadl file";
 #Can't do it other way around because same urls can be in different dirs.
 chomp ( $manga_urls{ '.' } = <$info_file> );
 close($info_file);
}

if ( not defined $opt{R} ) {
 if ( not defined $opt{m} ) {
   if ( not defined $manga_urls{ '.' } ) {
    print_help();
    exit(1);
   }
 } else {
  if ( defined $manga_urls{ '.' }
   and ( $manga_urls{ '.' } ne $opt{m} ) ) {
   say STDERR "Provided -m url and .mangadl url are different!";
   exit(1);
  } else {
   $manga_urls{ '.' } = $opt{m};
  }
 }
}

if ( defined $opt{R} ) {
 my @manga_directories = File::Find::Rule->file()->name( '.mangadl' )->in( '.' );
 foreach (@manga_directories) {
  open(my $info_file, '<', $_) or die "Couldn't read .mangadl file";
  chomp( $manga_urls{ $_ } = <$info_file> );
  close($info_file);
 }
}

if ( defined $opt{u} ) {
 $useragent=$opt{u};
}

my $thread_limit = 2;

if (defined $opt{t}) {
 if($opt{t} =~ /^[1-9]+$/) {
  $thread_limit = $opt{t};
 } else {
  say "Thread number is invalid";
  exit(1);
 }
}

URLS_LOOP: foreach my $dotfile (keys %manga_urls) {

say "Downloading chapters from ".$manga_urls{$dotfile}." in ".dirname($dotfile)." directory";

my $manga_host = URI->new( qq($manga_urls{$dotfile}/) )->host;

if ( !check_host(\%hosts, $manga_host) ) {
 say "Host is not supported, skipping...";
 next URLS_LOOP;
}

my $manga_page_content = get_html_content( $manga_urls{$dotfile} );

if ( $manga_page_content->is_error ) {
 say "Couldn't download front page for: ".$manga_urls{$dotfile};
 next URLS_LOOP;
}

my $manga_tree = HTML::TreeBuilder::XPath->new;

$manga_tree->parse($manga_page_content->decoded_content);
$manga_tree->eof;

if( !manga_exists($manga_tree,$hosts{ $manga_host }{ 'exists_xpath' })) {
 say "Manga doesn't exists, skipping...";
 next URLS_LOOP;
}
else {
 #Don't create file during listing
 #or when file already exists
 unless ( defined $opt{l} or defined $opt{R} or -f ".mangadl" ) {
  open(my $info_file, '>', ".mangadl") or die "Couldn't write .mangadl file";
  say $info_file $manga_urls{$dotfile};
  close($info_file);
 }
}

my @pagination = get_chapters_pagination($manga_tree, $hosts{ $manga_host });

my %chapters = get_chapters($manga_tree, $hosts{ $manga_host }, @pagination);

my @local_chapters;
if ( not defined $opt{'a'} ) {
 @local_chapters = find_chapter_directories($hosts{ $manga_host }, dirname($dotfile));
}

if ( defined $opt{'n'} and @local_chapters and not defined $chapters{ ((sort @local_chapters)[-1]) } ) {
 say "Local chapters not found in chapter list, unable to determine newest chapter.";
 exit(1);
}

my @range=();
if (defined $opt{r}) {
 if($opt{r} =~ /^[0-9]+(-[0-9]+)??$/) {
  (@range) = grep defined && /^[0-9]+$/, $opt{r} =~ /^([0-9]+)(-([0-9]+))??$/;
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
 undef(%chapters);
}

foreach my $chapter (sort { $chapters{$a}{'id'} <=> $chapters{$b}{'id'} } keys(%chapters)) {

 next if defined $chapters{$chapter}{'removed'};

 #Create threads on demand
 push @thr, threads->create(
  sub {
   # Thread will loop until no more work
   while (defined(my $chapter = $queue->dequeue)) {
    say "Got new job for chapter ".$chapter->{chapter}." in ".$chapter->{dir_name};
    download_chapter($chapter->{url}, $chapter->{chapter}, $chapter->{manga_host}, $chapter->{dir_name});
   }
  }
 ) if scalar(@thr) < $thread_limit;

 $queue->enqueue( { url => $chapters{$chapter}{url}, chapter => $chapter, manga_host => $manga_host, dir_name => dirname($dotfile) } );

}

}

# Signal that there is no more work to be sent
$queue->end();
# Join up with the threads
$_->join() for @thr;
