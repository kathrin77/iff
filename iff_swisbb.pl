#! /usr/bin/perl -w

use strict;
use warnings;
use Text::CSV;
use String::Util qw(trim);
use XML::LibXML;
use XML::LibXML::XPathContext;
use Data::Dumper;
use Getopt::Long;
use URI::Escape;
use Encode;
use utf8;
use 5.010;
binmode( STDOUT, ":utf8" );

##########################################################
#
#	DECLARE NECESSARY VARIABLES
#
##########################################################

my @rows;
my $row;
my @found;
my @notfound;
my $found_nr = 1;
my $notfound_nr = 1;

## table rows and needed variables:
# 	Author:
my @authors;
my $author;
my $author2;
my @authority;
my $author_size;
my $escaped_author;

#	Title:
my @titles;
my $title;
my $subtitle = '';
my $volume = '';;
my $titledate = '';
my $escaped_title;

#	ISBN:
my $isbn;
my $isbn2;
my $isbnlength;

#	Others:
my $pages;
my $material;
my $created;
my $addendum;
my $location;
my $callno;
my $place;
my $publisher;
my $year;
my $note;
my $tsignature;
my $tsignature_1;
my $tsignature_2;
my $subj1;
my $subj2;
my $subj3;

# flags:
my $HAS_ISBN;
my $HAS_ISBN2;
my $HAS_AUTHOR;
my $HAS_AUTHOR2;
my $HAS_AUTHORITY;
my $HAS_SUBTITLE;
my $HAS_VOLUME;
my $HAS_TITLEDATE;
my $HAS_YEAR;
my $HAS_PAGES;
my $HAS_PAGERANGE;
my $HAS_PLACE;
my $HAS_PUBLISHER;

# regex:
my $HYPHEN_ONLY= qr/\A\-/; # a '-' in the beginning
my $EMPTY_CELL= qr/\A\Z/; #nothing in the cell
my $TITLE_SPLIT = qr/\s{2,3}/; #min 2, max 3 whitespaces

# testfiles
my $test800;
my $test400;
my $test200;

# input, output, filehandles:

my $csv;
my $fh_in;
my $fh_found;
my $fh_notfound;

# Swissbib and SRU variables:

# Swissbib SRU-Service for the complete content of Swissbib:
my $swissbib = 'http://sru.swissbib.ch/sru/search/defaultdb?'; 

# needed queries
my $isbnquery = '+dc.identifier+%3D+';
my $titlequery = '+dc.title+%3D+';
my $authorquery = '+dc.creator+%3D+';
my $yearquery = '+dc.date+%3D+';
my $anyquery = '+dc.anywhere+%3D+';

my $operation = '&operation=searchRetrieve';
my $schema = '&recordSchema=info%3Asrw%2Fschema%2F1%2Fmarcxml-v1.1-light'; # MARC XML - swissbib (less namespaces)
my $max = '&maximumRecords=10'; # swissbib default is 10 records
my $query = '&query=';
my $parameters = $operation.$schema.$max;

my $server_endpoint = $swissbib.$parameters.$query;
my $sruquery;

# XML-Variables
my $dom;
my $xpc;

my @record;
my $numberofrecords;
my $rec;
my $el;
# record counter
my $i;

# MARC fields
my $MARC100a;
my $MARC110a;
my $MARC700a;
my $MARC710a;
my $MARC245a;
my $MARC246a;
my $MARC264c;
my $MARC264b; 
my $MARC264a; 
my $MARC260c;
my $MARC260b;
my $MARC260a;
my $MARC949B;
my $MARC852B;

# Matching counters
my $AUTHORMATCH;
my $TITLEMATCH;
my $YEARMATCH;
my $PAGEMATCH;
my $PUBLISHERMATCH;
my $PLACEMATCH;
my $TOTALMATCH;
my $IDSSGMATCH; # im IDSSG vorhanden
my $IFFMATCH; # ist ein neu eingespielter IFF-Treffer.
my @matches;
my $bibnr;

##########################################################

# 	READ AND TREAT THE DATA

# TODO before that:
# Step 1: Rohdaten bereinigen in Datei Fulldump:
# Entferne alle Zeichenumbrüche
# Entferne alle Zeilen, welche im Zusatz "in:" enthalten --> separate Datei: Fulldump-nur-in, knapp 1800 Zeilen (Analytica)
# Entferne alle Zeilen, welche im Subj1 "Zeitschriften" enthalten --> separate Datei Fulldump-nur-zs-ohne-in, ca. 1550 Zeilen (Zeitschriften)

# Step 2: Datei Fulldump vorbereiten:
# Datei Fulldump in csv-Datei umwandeln - es verbleiben ca. 12'000 Zeilen.
# Aktuelle Testdateien sind so manuell vorbereitet.


##########################################################

# testfiles
$test800 = "Fulldump800.csv"; # ca. 15 Zeilen
$test400 = "Fulldump400.csv"; # ca. 30 Zeilen
$test200 = "Fulldump200.csv"; # ca. 60 Zeilen

# open input/output:
$csv = Text::CSV->new ( { binary => 1} ) or die "Cannot use CSV: ".Text::CSV->error_diag ();
open $fh_in, "<:encoding(utf8)", $test800 or die "$test800: $!";
open $fh_found, ">:encoding(utf8)", "found.csv" or die "found.csv: $!";
open $fh_notfound, ">:encoding(utf8)", "notfound.csv" or die "notfound.csv: $!";


# read each line and do...:
while ($row = $csv->getline( $fh_in) ) {
	push @rows, $row; #TODO: maybe not needed?
	
	#reset all flags and counters:
	$HAS_ISBN=1;
	$HAS_ISBN2=0;
	$HAS_AUTHOR=1;
	$HAS_AUTHOR2=0;
	$HAS_AUTHORITY=0;
	$HAS_SUBTITLE=0;
	$HAS_VOLUME=0;
	$HAS_TITLEDATE=0;
	$HAS_YEAR=1;
	$HAS_PAGES=1;
	$HAS_PAGERANGE=0;
	$HAS_PLACE=1;
	$HAS_PUBLISHER=1;
	$AUTHORMATCH=0;
	$TITLEMATCH=0;
	$YEARMATCH=0;
	$PAGEMATCH=0;
	$PUBLISHERMATCH=0;
	$PLACEMATCH=0;
	$IDSSGMATCH=0;
	$IFFMATCH=0;

	#get all necessary variables
	$author = $row->[0];
	$title = $row->[1];
	$isbn = $row->[2];
	$pages = $row->[3];
	$material = $row->[4];
	$created = $row->[5];
	$addendum = $row->[6];
	$location = $row->[7];
	$callno = $row->[8];
	$place  = $row->[9];
	$publisher = $row->[10];
	$year = $row->[11];
	$note = $row->[12];
	$tsignature = $row->[13];
	$tsignature_1 = $row->[14];
	$tsignature_2 = $row->[15];
	$subj1 = $row->[16];
	$subj2 = $row->[17];
	$subj3 = $row->[18];

	##########################
	# Deal with ISBN:
	##########################

	# 	remove all but numbers and X
	$isbn =~ s/[^0-9xX]//g; 
	$isbnlength = length($isbn);

	if ($isbnlength == 26) {
		#there are two ISBN-13
		$isbn2 = substr $isbn, 13;
		$isbn = substr $isbn,0,13;
		$HAS_ISBN2 = 1;
	} elsif ($isbnlength == 20) {
		#there are two ISBN-10
		$isbn2 = substr $isbn, 10;
		$isbn = substr $isbn,0,10;
		$HAS_ISBN2 = 1;
	} elsif ($isbnlength == 13 || $isbnlength == 10) {
		#valid ISBN
		$HAS_ISBN = 1;
	} else {
		#not a valid ISBN
		$HAS_ISBN = 0;
	}


	#############################
	# Deal with AUTHOR/AUTORITIES
	#############################

	$author = trim($author);
	$author =~ s/\.//g; #remove dots
	$author =~ s/\(|\)//g; #remove ()

	#check if empty author:
	if ($author =~ /$EMPTY_CELL/ || $author =~ /$HYPHEN_ONLY/) {
		$HAS_AUTHOR = 0;
		$author='';
	}
	#check if author = NN or the like:
	if ($author =~ /\ANN/ || $author =~ /\AN\.N\./ || $author =~ /\AN\.\sN\./ ) { 
		$HAS_AUTHOR = 0;
		$author='';
	}

	#TODO: Schweiz. ausschreiben? aber wie?

	#check if several authors: contains "/"?
	if ($HAS_AUTHOR && $author =~ /[\/]/) {
		@authors = split('/', $author);
		$author = $authors[0];
		$author2 = $authors[1];
		$HAS_AUTHOR2 = 1;
	} else { 
		$author2 = '';

	}

	#check if authority rather than author:
	if ($HAS_AUTHOR) {

		if ($author =~ /amt|Amt|kanzlei|Schweiz\.|institut/) {#probably an authority # TODO maybe more! 
			$HAS_AUTHORITY=1;
			$author_size = 5;
			#debug: 			print "Authority1: ". $HAS_AUTHORITY." authorsize1: ".$author_size."\n";
		} else {
			@authority = split(' ', $author);
			$author_size = scalar @authority;
			#debug:			print "Authorsize2: ". $author_size."\n";
		}

		if ($author_size>3) { #probably an authority
			$HAS_AUTHORITY=1;
			#debug: 			print "Authority2: ". $HAS_AUTHORITY." authorsize2: ".$author_size."\n";
		} else {	#probably a person
			# trim author's last name:
			if ($author =~ /\Avon|\AVon|\Ade|\ADe|\ALe\s/) { #TODO maybe more
				$author = ( split /\s/, $author, 3 )[1];
				#debug				print "Author: ".$author."\n";
			} else {
				$author = ( split /\s/, $author, 2 )[0];
				#debug				print "Author: ".$author."\n";
			}
			if ($HAS_AUTHOR2) {
				if ($author2 =~ /\Avon|\AVon|\Ade|\ADe|\ALe\s/) {#TODO maybe more
					$author2 = ( split /\s/, $author2, 3 )[1];
					#debug					print "Author2: ".$author2."\n";
				} else {
					$author2 = ( split /\s/, $author2, 2 )[0];
					#debug					print "Author2: ".$author2."\n";				
				}
			}
		}
	} 

	#debug: 	print "Autor variable: ".$author. " ~~ " .  $author2."\n";


	##########################
	# Deal with TITLE:
	##########################

	$title = trim($title);
	#TODO: '+' im Titel ersetzen, aber womit?
	$title =~ s/\.//g; #remove dots
	$title =~ s/\(|\)//g; #remove ()

	#check if title has subtitle that needs to be eliminated: (2 or 3 whitespaces) #TODO depends on how carriage returns are removed! works for now.
	if ($title =~ /$TITLE_SPLIT/) {
		@titles = ( split /$TITLE_SPLIT/, $title);
		$subtitle = $titles[1];
		$title = $titles[0];
		$HAS_SUBTITLE=1;
	} else {$subtitle = '';}

	#check if title has volume information that needs to be removed: (usually: ... - Bd. ...)
	if ($title =~ /-\sBd|-\sVol|-\sReg|-\sGen|-\sTeil|-\s\d{1}\.\sTeil|-\sI{1,3}\.\sTeil/) {
		$volume = (split / - /, $title, 2)[1];
		$title = (split / - /, $title, 2)[0];
		$HAS_VOLUME=1;
	} else {$volume = '';}

	#check if the title contains years or other dates and remove them:
	if ($title =~ /-\s\d{1,4}/) {
		$titledate = (split / - /, $title, 2)[1];
		$title = (split / - /, $title, 2)[0];
		$HAS_TITLEDATE=1;
	} else {$titledate = '';}

	if ($title =~ /\s\d{1,4}\Z/) {# Das Lohnsteuerrecht 1972
		$titledate = substr $title, -4;
		$title = (split /\s\d{1,4}/, $title, 2)[0];
		$HAS_TITLEDATE=1;
	} elsif ($title =~ /\s\d{4}\/\d{2}\Z/) { #Steuerberater-Jahrbuch 1970/71
		$titledate = substr $title, -7;
		$title = (split /\s\d{4}\/\d{2}/, $title, 2)[0];
		$HAS_TITLEDATE=1;
	} elsif ($title =~ /\s\d{4}\/\d{4}\Z/) { #Steuerberater-Jahrbuch 1970/1971
		$titledate = substr $title, -9;
		$title = (split /\s\d{4}\/\d{4}/, $title, 2)[0];
		$HAS_TITLEDATE=1;
	} elsif ($title =~ /\s\d{4}\-\d{4}\Z/) { #Sammlung der Verwaltungsentscheide 1947-1950
		$titledate = substr $title, -9;
		$title = (split /\s\d{4}\-\d{4}/, $title, 2)[0]; 
		$HAS_TITLEDATE=1;
	} else {$titledate = '';}

	#debug: 	print $title . " ~~ " . $subtitle . " ~~ " . $volume . " ~~ " . $titledate ."\n";



	##########################################
	# Deal with YEAR, PAGES, PLACE, PUBLISHER:
	##########################################

	if ($year =~ /$EMPTY_CELL/ || $year =~ /$HYPHEN_ONLY/ || $year =~ /online/) {
		$HAS_YEAR = 0;
		$year='';
	}

	if ($pages =~ /$EMPTY_CELL/ || $pages =~ /$HYPHEN_ONLY/) {
		$HAS_PAGES = 0;
		$pages='';
	} elsif ($pages =~ /\AS.\s/ || $pages =~ /\-/) { #very likely not a monography but a volume or article, eg. S. 300ff or 134-567
		$HAS_PAGERANGE=1;
	}

	if ($place =~ /$EMPTY_CELL/ || $place =~ /$HYPHEN_ONLY/) {
		$HAS_PLACE = 0;
		$place='';
	}
	if ($publisher =~ /$EMPTY_CELL/ || $publisher =~ /$HYPHEN_ONLY/) {
		$HAS_PUBLISHER = 0;
		$publisher='';
	} #TODO if publisher is needed, probably some more work to do here...


	######################################################################

	# START SEARCH ON SWISSBIB
	# Documentation of Swissbib SRU Service:
	# http://www.swissbib.org/wiki/index.php?title=SRU
	# 

	######################################################################


	##########################################
	# Build Query:
	##########################################

	#empty sruquery:
	$sruquery = '';

	if ($HAS_ISBN) { 
		#debug: 
		print "ISBN-Suche: ".$isbn. "\n";
		#$isbn = uri_escape($isbn);
		$sruquery = $server_endpoint . $isbnquery . $isbn;

	} else {
		#debug: 
		print "Titel-Suche: ".$title. "\n";		
		$escaped_title = uri_escape_utf8($title);
		$sruquery = $server_endpoint . $titlequery . $escaped_title;

		if ($HAS_AUTHOR) {
			#debug
			print "Autor-Suche: ".$author. "\n";
			$escaped_author = uri_escape_utf8($author);
	    	$sruquery .= "+AND" . $authorquery . $escaped_author;


		} elsif ($HAS_YEAR) {
			#debug
			print "Jahr-Suche: ".$year. "\n";
			#$year = uri_escape($year);
	    	$sruquery .= "+AND" . $yearquery . $year;

		} else {
			#debug
			print "Zusätzliches Suchfeld benötigt!\n";
		}

	}
	
	# Debug: 		print "URL: ". $sruquery. "\n";

	# load xml as DOM object, # register namespaces of xml
	$dom = XML::LibXML->load_xml( location => $sruquery );
	$xpc = XML::LibXML::XPathContext->new($dom);

	# get nodes of records with XPATH
	@record = $xpc->findnodes('/searchRetrieveResponse/records/record/recordData/record');

	$numberofrecords = $xpc->findnodes('/searchRetrieveResponse/numberOfRecords');
	$numberofrecords = int($numberofrecords);

	# debug:	
	print "Treffer:" .$numberofrecords."\n\n";
	
	


### debug output:
	if ($numberofrecords == 0) {

		# TODO: make a new query with other parameters, if still 0:
		push @notfound, "\n", $notfound_nr, $isbn, $title, $author, $year;
		$notfound_nr++;

	} elsif ($numberofrecords >= 1 && $numberofrecords <= 10) {
		
		# compare fields in record:
		$i = 1;
		foreach $rec (@record) {
		 print "#Document $i:\n";
			## Authors: TODO authorities, 2nd author (700a,110a)

			if ($HAS_AUTHOR && $xpc->exists( './datafield[@tag="100"]', $rec)){
				foreach $el ($xpc->findnodes( './datafield[@tag=100]', $rec)){
		         $MARC100a = $xpc->findnodes('./subfield[@code="a"]', $el )->to_literal;
					# debug: 
					print "Feld 100a: ".$MARC100a."\n";
#					if ($author eq $MARC100a) {
					if ($MARC100a=~ m/$author/i) { #kommt Autor in 100a vor? (ohne Gross-/Kleinschreibung zu beachten)
						$AUTHORMATCH = 10;
					} else { $AUTHORMATCH = 0; }
					# debug: 
					print "A-Match: ".$AUTHORMATCH."\n";
		     	}
		 	}

			## Title: TODO subtitle, title addons, etc., other marc fields (246a, 245b, 246b)
		 	if ($xpc->exists('./datafield[@tag="245"]', $rec)){		     
		     	foreach $el ($xpc->findnodes( './datafield[@tag=245]', $rec)){
		         $MARC245a= $xpc->findnodes('./subfield[@code="a"]', $el )->to_literal;
					# debug: 
					print "Feld 245a: ".$MARC245a. "\n";  
					print "Titel: ".$title. "\n"; 
#					if ($title eq $MARC245a) {
					if ($MARC245a =~m/$title/i) {#kommt Titel in 245a vor? (ohne Gross-/Kleinschreibung zu beachten)
						$TITLEMATCH = 10;
					} else { $TITLEMATCH = 0; }
					# debug: 
					print "T-Match: ".$TITLEMATCH."\n";       
	     		}
			}

			## Year, publisher, place: TODO year may be off by 1-2 years, other marc fields (260)
		 	if ($HAS_YEAR && $xpc->exists('./datafield[@tag="264"]', $rec)){
		     
		     foreach $el ($xpc->findnodes( './datafield[@tag=264]', $rec)){
		         $MARC264c = $xpc->findnodes('./subfield[@code="c"]', $el )->to_literal;

					# debug: 
					print "Feld 264c: ".$MARC264c."\n";   
					print "Jahr: ".$year."\n"; 
					if ($year eq $MARC264c) {
						$YEARMATCH = 10;
					} else { $YEARMATCH = 0; }
					# debug: 
					print "J-Match: ".$YEARMATCH."\n"; 
		     	}

	 		} 
		 	if ($HAS_PLACE && $xpc->exists('./datafield[@tag="264"]', $rec)){
		     
		     foreach $el ($xpc->findnodes( './datafield[@tag=264]', $rec)){
					$MARC264a = $xpc->findnodes('./subfield[@code="a"]', $el )->to_literal;
					# debug: 
					print "Feld 264a: ".$MARC264a."\n";   
					print "Ort: ".$place."\n"; 
#					if ($place eq $MARC264a) {
					if ($MARC264a=~m/$place/i) {
						$PLACEMATCH = 10;
					} else { $PLACEMATCH = 0; }
					# debug: 
					print "P-Match: ".$PLACEMATCH."\n"; 
		     	}

	 		} 
		 	if ($HAS_PUBLISHER && $xpc->exists('./datafield[@tag="264"]', $rec)){
		     
		     foreach $el ($xpc->findnodes( './datafield[@tag=264]', $rec)){
					$MARC264b = $xpc->findnodes('./subfield[@code="a"]', $el )->to_literal;
					# debug: 
					print "Feld 264b: ".$MARC264b."\n";   
					print "Verlag: ".$place."\n"; 
#					if ($publisher eq $MARC264b) {
					if ($MARC264b =~m/$place/i) {
						$PUBLISHERMATCH = 10;
					} else { $PUBLISHERMATCH = 0; }
					# debug: 
					print "V-Match: ".$PUBLISHERMATCH."\n"; 
		     	}

	 		} 

			## Posessing library network: 
		 	if ($xpc->exists('./datafield[@tag="949"]', $rec)){

		     	foreach $el ($xpc->findnodes( './datafield[@tag=949 ]', $rec)){
		         $MARC949B= $xpc->findnodes('./subfield[@code="B"]', $el )->to_literal;            
					print "Feld 949B: ".$MARC949B."\n";
					if ($MARC949B =~/IDSSG/) {
						#get record nr.
						#$bibnr = $xpc->findnodes('./datafield[@tag=035/subfield[@code="a"]')->to_literal;
						#print $bibnr."\n";
						#if ($bibnr > 990000) {
						#	$IFFMATCH = -100;
						#} else {
						#	$IDSSGMATCH = 100;
						#}
						print "--------------------------Bingo! HSG-Buch!\n"; 
					} elsif ($MARC949B =~/IDSBB|IDSLU|NEBIS/) {
						print "--------------------------OK! Im IDS vorhanden\n"; 
					} 
		     	}
		 	} 

			## Posessing library network: 
		 	if ($xpc->exists('./datafield[@tag="852"]', $rec)){

		     	foreach $el ($xpc->findnodes( './datafield[@tag=852 ]', $rec)){
		         $MARC852B = $xpc->findnodes('./subfield[@code="B"]', $el )->to_literal;            
					print "Feld 852B: ".$MARC852B."\n";
					if ($MARC852B =~/IDSSG/) {
						print "--------------------------Bingo! HSG-Buch!\n"; 
					} elsif ($MARC949B =~/IDSBB|IDSLU|NEBIS/) {
						print "--------------------------OK! Im IDS vorhanden\n"; 
					} 
		     	} 
		 	} 
			
		 	$i++;
			$TOTALMATCH = ($TITLEMATCH+$AUTHORMATCH+$YEARMATCH+$PAGEMATCH+$PUBLISHERMATCH+$PLACEMATCH);
		 	print "Totalmatch: ".$TOTALMATCH."\n";
		 	print "-----\n\n";
		}

		# TODO: if correct, write out as marcxml, if false, do another query with more parameters 
		push @found, "\n", $found_nr, $isbn, $title, $author, $year;
		$found_nr++;
	} elsif ($numberofrecords > 10) {
		# TODO: repeat search with better query
		push @found, "\n", $found_nr, $isbn, $title, $author, $year;
		$found_nr++;
	} else {
		# TODO: something wrong with query.
	}

}

$csv->eof or $csv->error_diag();
close $fh_in;

$csv->print ($fh_notfound, \@notfound);
$csv->print ($fh_found, \@found);

close $fh_found or die "found.csv: $!";
close $fh_notfound or die "notfound.csv: $!";

print "Total gefunden: ".$found_nr."\n";
print "Total nicht gefunden: ".$notfound_nr."\n";


