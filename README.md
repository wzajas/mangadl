## mangadl

mangadl is manga downloader written in perl. Currently supports: www.mangahere.co, www.mangapanda.com, www.goodmanga.net and bato.to.

It works but it's still work in progress!!!.

It started as excuse to learn web scraping in perl, but in time grew into multi-site script. I've added thread support so multiple chapters can be downloaded simultaneously. After first download url is written into .dot file which can be used in recursive mode. The idea was to have one directory for each manga and update all of them in one run from parent. Script should detect most errors and allow user to resume, so fell free to ^C any time.

### How to

Switches:

```
 -h this help message
 -m <manga_url> ie. http://www.mangahere.co/manga/<manga_title>/
 -r <range> chapter range eg. 1 or 1-3
 -l list what would be downloaded
 -n catch only the newest chapters (only if you have already downloaded something)
 -u '<user-agent>' define user-agent string (some hosts block lwp default)
 -t <int> number of threads
```
Couple of notes:

* **-n** example, let's assume that manga has 10 chapters, 5 of which you have already read online, 6th is released - download it with -r 6, then -n will download only 7-10 if they appear on site.
* **-l/-r** Ranges are created using numbers provided by **-l**. it's not always the same as chapter numbers. I tried using numbers provided by sites but soon it proved quite difficult depending on how users submitted them. Best thing to do is to run script with both switches to see what really will be downloaded. 

### Requirements

The following perl modules are needed:
* File::Find::Rule
* HTML::TreeBuilder::XPath
* LWP::UserAgent
* URI

Debian/Ubuntu: apt-get install libhtml-treebuilder-xpath-perl libfile-find-rule-perl libwww-perl liburi-perl

Arch: perl-libwww and perl-uri are in repository, perl-file-find-rule and perl-html-treebuilder-xpath can be found in aur.

### Internals

TODO

