#!/usr/bin/perl -w
use strict;

################################################################################
#
# deki_import_csv.pl - A simple script to create Deki pages from a CSV
#
# Author: Ross Turk <ross@rossturk.com>
#

# Deki settings
my $dekiHost = "company.mindtouch.us";
my $dekiParentPage = "Import_Root";

# Print debugging messages?
my $debug = 0;

# Grab the CSV as the first command-line parameter
my $file = shift @ARGV;

if (!$file) {
	print "usage: $0 csv_file\n";
	exit 1;
}

chomp($file);

# First, let's get the password.
my $dekiUsername = prompt('Username for '.$dekiHost.': ');
my $dekiPassword = prompt('Password for '.$dekiHost.': ', -e => '*');

if (!$dekiUsername || !$dekiPassword) {
	die("Need both a username and a password, sorry!");
}

################################################################################

# We need some modules in here!

use Text::CSV;
use HTML::FromText;
use LWP::UserAgent;
use Data::Dumper;
use URI::Escape;
use XML::Writer;
use IO::Prompt;

# The progress text looks better if output buffering is off...
$| = 1;

# Let's instantiate some stuff we need
my $agent = LWP::UserAgent->new; # User agent
my $t2h = HTML::FromText->new({paras => 1, lines =>0}); # HTML Converter
my $csv = Text::CSV->new ({binary => 1}); # CSV Parser

# Configure the user agent so that we're logged in to Deki
$agent->cookie_jar({});
$agent->credentials($dekiHost.':80','DekiWiki',$dekiUsername=>$dekiPassword);

# Open the CSV and start looping through it
open (CSV, "<", $file) or die $!;

# Let's throw away the first line, it's just the header text...
my $header = <CSV>;

# ...and start looping through the rest!
LINE: while (<CSV>) {
	if ($csv->parse($_)) {
		my @columns = $csv->fields();

		# If the title contains "skip" and no other words, move to the next line.
		if ($columns[5] =~ m/\s*skip\s*/) {
			next LINE;
		}
		
		# The Summary field becomes our title
		my $title = $columns[5];
		(my $titlePath = $title) =~ s/\s/_/g;
		
		print "Importing ". $columns[0] ."...";

		# Add the RFP Request as a new section
		my $content = "<h2>Request</h2>\n";
		$content .= "<p>". $columns[6] . "</p>\n";

		# Add the RFP Response in <p> tags after it
		$content .= "<h2>Response</h2>\n";
		
		my $body = $columns[7];
		$body =~ s/\r/\n/g;
		$content .= $t2h->parse($body);

		# Format and encode the new page's path and title
		my $newPagePath = uri_escape(uri_escape($dekiParentPage ."/". $titlePath));
		my $requestURL = "http://". $dekiHost ."/\@api/deki/pages/=". $newPagePath .
				"/contents?title=". uri_escape($title);
		
		# Create the page
		my $request = HTTP::Request->new;
		$request->method('POST'); # New pages are created with POST requests
		$request->content_type('text/plain'); # Oddly, this isn't text/xml or text/html.
		$request->content($content);
		$request->uri($requestURL);

		$debug && print "URL: $requestURL\n";
		$debug && print "Content: [[\n$content]]\n\n";
		
		my $response = $agent->request($request);
		
		if ($response->is_error) {
			die "Error: ". $response->status_line;
		}
		
		# Scrape the response for the ID of the page we just created, we'll use it later.
		$response->content =~ m/page id="(\d+)"/;
		my $pageID = $1;
		print "page (id: ". $pageID .")...";

		# Assemble a new XML document for our tags
		my $tags;
		my $writer = new XML::Writer(OUTPUT => \$tags); 
		$writer->startTag('tags');
		
		# Add the "relevant product" field to our tag list
		$writer->emptyTag('tag', 'value' => $columns[3]);
		
		# Each item in the "keywords" field should be a tag.
		my @tags = split(/,/,$columns[4]);
		
		foreach my $tag (@tags) {
			$tag =~ s/^\s+//g; $tag =~ s/\s+$//g;
			$writer->emptyTag('tag', 'value' => $tag);
		}
		
		# If the "customizations required" field does not contain the word "standard".
		# we should tag this item with "custom".
		unless ($columns[1] =~ m/standard/) {
			$writer->emptyTag('tag', 'value' => "custom");
		}
			
		$writer->endTag();
		$writer->end;

		$requestURL = "http://". $dekiHost ."/\@api/deki/pages/". $pageID ."/tags";

		# Add the tags to our new page
		$request = HTTP::Request->new;
		$request->method('PUT');
		$request->content_type('text/xml');
		$request->content($tags);
		$request->uri($requestURL);

		$debug && print "URL: $requestURL\n";
		$debug && print "Content: [[\n$tags]]\n\n";

		$response = $agent->request($request);
		
		if ($response->is_error) {
			die "Error: " . $response->status_line;
		}
		
		print "tags\n";
		
	} else {
		my $err = $csv->error_diag;
		print "\n\n\nFailed to parse line:\n\n\n $err";
	}
}
close CSV;
