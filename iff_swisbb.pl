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

use Vari;
use Flag;
use Marc;
use Match;

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


# regex:
my $HYPHEN_ONLY= qr/\A\-/; # a '-' in the beginning
my $EMPTY_CELL= qr/\A\Z/; #nothing in the cell
my $TITLE_SPLIT = qr/\s{2,3}/; #min 2, max 3 whitespaces

# testfiles
my $test800 = "test/Fulldump800.csv"; # ca. 15 Zeilen
my $test400 = "test/Fulldump400.csv"; # ca. 30 Zeilen
my $test200 = "test/Fulldump200.csv"; # ca. 60 Zeilen

# input, output, filehandles:
my $csv;
my $fh_in;
my $fh_found;
my $fh_notfound;
my $fh_report;

# Swissbib SRU-Service for the complete content of Swissbib:
my $swissbib = 'http://sru.swissbib.ch/sru/search/defaultdb?'; 
my $operation = '&operation=searchRetrieve';
my $schema = '&recordSchema=info%3Asrw%2Fschema%2F1%2Fmarcxml-v1.1-light'; # MARC XML - swissbib (less namespaces)
my $max = '&maximumRecords=10'; # swissbib default is 10 records
my $query = '&query=';

my $server_endpoint = $swissbib.$operation.$schema.$max.$query;

# needed queries
my $isbnquery = '+dc.identifier+%3D+';
my $titlequery = '+dc.title+%3D+';
my $authorquery = '+dc.creator+%3D+';
my $yearquery = '+dc.date+%3D+';
my $anyquery = '+dc.anywhere+%3D+';

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

# open input/output:
$csv = Text::CSV->new ( { binary => 1} ) or die "Cannot use CSV: ".Text::CSV->error_diag ();
#open $fh_in, "<:encoding(utf8)", $test800 or die "$test800: $!";
#open $fh_in, "<:encoding(utf8)", $test400 or die "$test400: $!";
open $fh_in, "<:encoding(utf8)", $test200 or die "$test200: $!";
open $fh_found, ">:encoding(utf8)", "found.csv" or die "found.csv: $!";
open $fh_notfound, ">:encoding(utf8)", "notfound.csv" or die "notfound.csv: $!";
open $fh_report, ">:encoding(utf8)", "report.txt" or die "report.txt: $!";


# read each line and do...:
while ($row = $csv->getline( $fh_in) ) {
	push @rows, $row; #TODO: maybe not needed?

	#get all necessary variables
	$Vari::author = $row->[0];
	$Vari::title = $row->[1];
	$Vari::isbn = $row->[2];
	$Vari::pages = $row->[3];
	#$Vari::material = $row->[4];
	#$Vari::created = $row->[5];
	#$Vari::addendum = $row->[6];
	#$Vari::location = $row->[7];
	#$Vari::callno = $row->[8];
	$Vari::place  = $row->[9];
	$Vari::publisher = $row->[10];
	$Vari::year = $row->[11];
	#$Vari::note = $row->[12];
	#$Vari::tsignature = $row->[13];
	#$Vari::tsignature_1 = $row->[14];
	#$Vari::tsignature_2 = $row->[15];
	#$Vari::subj1 = $row->[16];
	#$Vari::subj2 = $row->[17];
	#$Vari::subj3 = $row->[18];

	#reset all flags and counters:
	resetFlags();
	#resetMatch();

	##########################
	# Deal with ISBN:
	##########################

	# 	remove all but numbers and X
	$Vari::isbn =~ s/[^0-9xX]//g; 
	$Vari::isbnlength = length($Vari::isbn);

	if ($Vari::isbnlength == 26) {		#there are two ISBN-13
		$Vari::isbn2 = substr $Vari::isbn, 13;
		$Vari::isbn = substr $Vari::isbn,0,13;
		$Flag::HAS_ISBN2 = 1;
	} elsif ($Vari::isbnlength == 20) {		#there are two ISBN-10
		$Vari::isbn2 = substr $Vari::isbn, 10;
		$Vari::isbn = substr $Vari::isbn,0,10;
		$Flag::HAS_ISBN2 = 1;
	} elsif ($Vari::isbnlength == 13 || $Vari::isbnlength == 10) { 		#valid ISBN
		$Flag::HAS_ISBN = 1;
	} else { 		#not a valid ISBN
		$Flag::HAS_ISBN = 0;
	}


	#############################
	# Deal with AUTHOR/AUTORITIES
	#############################

	$Vari::author = trim($Vari::author);
	$Vari::author =~ s/\.//g; #remove dots
	$Vari::author =~ s/\(|\)//g; #remove ()

	#check if empty author or if author = NN or the like:
	if ($Vari::author =~ /$EMPTY_CELL/ || $Vari::author =~ /$HYPHEN_ONLY/ || $Vari::author =~ /\ANN/ || $Vari::author =~ /\AN\.N\./ || $Vari::author =~ /\AN\.\sN\./ ) {
		$Flag::HAS_AUTHOR = 0;
		$Vari::author='';
	} else {
		$Flag::HAS_AUTHOR = 1;		
	}

	#TODO: Schweiz. ausschreiben? aber wie?

	#check if several authors: contains "/"?
	if ($Flag::HAS_AUTHOR && $Vari::author =~ /[\/]/) {
		@Vari::authors = split('/', $Vari::author);
		$Vari::author = $Vari::authors[0];
		$Vari::author2 = $Vari::authors[1];
		$Flag::HAS_AUTHOR2 = 1;
	} else { 
		$Vari::author2 = '';
	}

	#check if authority rather than author:
	if ($Flag::HAS_AUTHOR) {

		if ($Vari::author =~ /amt|Amt|kanzlei|Schweiz\.|institut/) {#probably an authority # TODO maybe more! 
			$Flag::HAS_AUTHORITY=1;
			$Vari::author_size = 5;
			#debug: 			print "Authority1: ". $HAS_AUTHORITY." authorsize1: ".$author_size."\n";
		} else {
			@Vari::authority = split(' ', $Vari::author);
			$Vari::author_size = scalar @Vari::authority;
			#debug:			print "Authorsize2: ". $author_size."\n";
		}

		if ($Vari::author_size>3) { #probably an authority
			$Flag::HAS_AUTHORITY=1;
			#debug: 			print "Authority2: ". $HAS_AUTHORITY." authorsize2: ".$author_size."\n";
		} else {	#probably a person
			# trim author's last name:
			if ($Vari::author =~ /\Avon|\AVon|\Ade|\ADe|\ALe\s/) { #TODO maybe more
				$Vari::author = ( split /\s/, $Vari::author, 3 )[1];
				#debug				print "Author: ".$author."\n";
			} else {
				$Vari::author = ( split /\s/, $Vari::author, 2 )[0];
				#debug				print "Author: ".$author."\n";
			}
			if ($Flag::HAS_AUTHOR2) {
				if ($Vari::author2 =~ /\Avon|\AVon|\Ade|\ADe|\ALe\s/) {#TODO maybe more
					$Vari::author2 = ( split /\s/, $Vari::author2, 3 )[1];
					#debug					print "Author2: ".$author2."\n";
				} else {
					$Vari::author2 = ( split /\s/, $Vari::author2, 2 )[0];
					#debug					print "Author2: ".$author2."\n";				
				}
			}
		}
	} 

	#debug: 	print "Autor variable: ".$author. " ~~ " .  $author2."\n";


	##########################
	# Deal with TITLE:
	##########################

	$Vari::title = trim($Vari::title);
	#TODO: '+' im Titel ersetzen, aber womit?

	$Vari::title =~ s/\.//g; #remove dots
	$Vari::title =~ s/\(|\)//g; #remove ()

	#check if title has subtitle that needs to be eliminated: (2 or 3 whitespaces) #TODO depends on how carriage returns are removed! works for now.
	if ($Vari::title =~ /$TITLE_SPLIT/) {
		@Vari::titles = ( split /$TITLE_SPLIT/, $Vari::title);
		$Vari::subtitle = $Vari::titles[1];
		$Vari::title = $Vari::titles[0];
		$Flag::HAS_SUBTITLE=1;
	} elsif ($Vari::title =~ /\:/) {#check if title has subtitle that needs to be eliminated: (':') 
		@Vari::titles = ( split /\:/, $Vari::title);
		$Vari::subtitle = $Vari::titles[1];
		$Vari::title = $Vari::titles[0];
		$Vari::title = trim($Vari::title);
		$Vari::subtitle = trim($Vari::subtitle);
		$Flag::HAS_SUBTITLE=1;
	} else {$Vari::subtitle = '';}

	#check if title has volume information that needs to be removed: (usually: ... - Bd. ...)
	if ($Vari::title =~ /-\sBd|-\sVol|-\sReg|-\sGen|-\sTeil|-\s\d{1}\.\sTeil|-\sI{1,3}\.\sTeil/) {
		$Vari::volume = (split / - /, $Vari::title, 2)[1];
		$Vari::title = (split / - /, $Vari::title, 2)[0];
		$Flag::HAS_VOLUME=1;
	} else {$Vari::volume = '';}

	#check if the title contains years or other dates and remove them:
	if ($Vari::title =~ /-\s\d{1,4}/) {
		$Vari::titledate = (split / - /, $Vari::title, 2)[1];
		$Vari::title = (split / - /, $Vari::title, 2)[0];
		$Flag::HAS_TITLEDATE=1;
	} else {$Vari::titledate = '';}

	if ($Vari::title =~ /\s\d{1,4}\Z/) {# Das Lohnsteuerrecht 1972
		$Vari::titledate = substr $Vari::title, -4;
		$Vari::title = (split /\s\d{1,4}/, $Vari::title, 2)[0];
		$Flag::HAS_TITLEDATE=1;
	} elsif ($Vari::title =~ /\s\d{4}\/\d{2}\Z/) { #Steuerberater-Jahrbuch 1970/71
		$Vari::titledate = substr $Vari::title, -7;
		$Vari::title = (split /\s\d{4}\/\d{2}/, $Vari::title, 2)[0];
		$Flag::HAS_TITLEDATE=1;
	} elsif ($Vari::title =~ /\s\d{4}\/\d{4}\Z/) { #Steuerberater-Jahrbuch 1970/1971
		$Vari::titledate = substr $Vari::title, -9;
		$Vari::title = (split /\s\d{4}\/\d{4}/, $Vari::title, 2)[0];
		$Flag::HAS_TITLEDATE=1;
	} elsif ($Vari::title =~ /\s\d{4}\-\d{4}\Z/) { #Sammlung der Verwaltungsentscheide 1947-1950
		$Vari::titledate = substr $Vari::title, -9;
		$Vari::title = (split /\s\d{4}\-\d{4}/, $Vari::title, 2)[0]; 
		$Flag::HAS_TITLEDATE=1;
	} else {$Vari::titledate = '';}
	
	$Vari::shorttitle = substr $Vari::title, 0,10;
	#print "Kurztitel: ".$Vari::shorttitle."\n";

	#debug: 	print $title . " ~~ " . $subtitle . " ~~ " . $volume . " ~~ " . $titledate ."\n";



	##########################################
	# Deal with YEAR, PAGES, PLACE, PUBLISHER:
	##########################################

	if ($Vari::year =~ /$EMPTY_CELL/ || $Vari::year =~ /$HYPHEN_ONLY/ || $Vari::year =~ /online/) {
		$Flag::HAS_YEAR = 0;
		$Vari::year='';
	} else {
		$Flag::HAS_YEAR = 1;
	}

	if ($Vari::pages =~ /$EMPTY_CELL/ || $Vari::pages =~ /$HYPHEN_ONLY/) {
		$Flag::HAS_PAGES = 0;
		$Vari::pages='';
	} elsif ($Vari::pages =~ /\AS.\s/ || $Vari::pages =~ /\-/) { #very likely not a monography but a volume or article, eg. S. 300ff or 134-567
		$Flag::HAS_PAGERANGE=1;
		$Flag::HAS_PAGES = 1; ## TODO: check, maybe should be 0?
	} else {
		$Flag::HAS_PAGES = 1;
	}

	if ($Vari::place =~ /$EMPTY_CELL/ || $Vari::place =~ /$HYPHEN_ONLY/ || $Vari::place =~ /0/) { #TODO: remove everything after / or ,
		$Flag::HAS_PLACE = 0;
		$Vari::place='';
	} else {
		$Flag::HAS_PLACE = 1;
	}


	#check if place has words that needs to be removed: (usually: D.C., a.M.)
	if ($Vari::place =~ m/d\.c\.|a\.m\./i) {
		$Vari::place = substr $Vari::place, 0,-5;
		#debug			print $Vari::place."\n";
	} 

	if ($Vari::publisher =~ /$EMPTY_CELL/ || $Vari::publisher =~ /$HYPHEN_ONLY/) {
		$Flag::HAS_PUBLISHER = 0;
		$Vari::publisher='';
	} else {
		$Flag::HAS_PUBLISHER = 1;
	}

	#check if publisher has words that needs to be removed: (usually: Der die das The le la)
	if ($Vari::publisher =~ m/der\s|die\s|das\s|the\s|le\s|la\s/i) {
		$Vari::publisher = (split /\s/, $Vari::publisher, 2)[1];
		#debug		print $Vari::publisher."\n";
	} 

# TODO: Remove "Verlag" etc. from publishers name.


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

	if ($Flag::HAS_ISBN) { 
		#debug: 
		print $fh_report "ISBN-Suche: ".$Vari::isbn. "\n";
		#$isbn = uri_escape($isbn);
		$sruquery = $server_endpoint . $isbnquery . $Vari::isbn;

		if ($Flag::HAS_ISBN2) {
			print $fh_report "ISBN2-Suche: ".$Vari::isbn2. "\n";	
	    	$sruquery .= "+OR" . $isbnquery . $Vari::isbn2;		
		}

	} else {
		#debug: 
		print $fh_report "Titel-Suche: ".$Vari::title. "\n";		
		$Vari::escaped_title = uri_escape_utf8($Vari::title);
		$sruquery = $server_endpoint . $titlequery . $Vari::escaped_title;

		if ($Flag::HAS_AUTHOR) {
		#debug
			print $fh_report "Autor-Suche: ".$Vari::author. "\n";
			$Vari::escaped_author = uri_escape_utf8($Vari::author);
	    	$sruquery .= "+AND" . $authorquery . $Vari::escaped_author; 
			# TODO: check directly for author 2 here?

		} elsif ($Flag::HAS_YEAR) {
			#debug
			print $fh_report "Jahr-Suche: ".$Vari::year. "\n";
			#$year = uri_escape($year);
	    	$sruquery .= "+AND" . $yearquery . $Vari::year;

		} elsif ($Flag::HAS_PAGES) {
			#debug
			print $fh_report "Seiten-Suche: ".$Vari::pages. "\n";
	    	$sruquery .= "+AND" . $anyquery . $Vari::pages;			

		} else {
			#debug
			print $fh_report "Kein weiteres Suchfeld!\n";
		}

	}
	
	# Debug: 		
	print $fh_report "URL: ". $sruquery. "\n";

	# load xml as DOM object, # register namespaces of xml
	$dom = XML::LibXML->load_xml( location => $sruquery );
	$xpc = XML::LibXML::XPathContext->new($dom);

	# get nodes of records with XPATH
	@record = $xpc->findnodes('/searchRetrieveResponse/records/record/recordData/record');

	$numberofrecords = $xpc->findnodes('/searchRetrieveResponse/numberOfRecords');
	$numberofrecords = int($numberofrecords);

	# debug:	
	print $fh_report "Treffer: " .$numberofrecords."\n\n";	
	


### debug output:
	if ($numberofrecords == 0) {

		print $fh_report "Kein Treffer gefunden mit dieser Suche!!!\n";	
		print $fh_report "*****************************************************\n\n";
		
		# TODO: make a new query with other parameters, if still 0:
		push @notfound, "\n", $notfound_nr, $Vari::isbn, $Vari::title, $Vari::author, $Vari::year;
		$notfound_nr++;

	} elsif ($numberofrecords > 10) {
		if ($Flag::HAS_YEAR) {
			#debug
			print $fh_report "Jahr-Suche: ".$Vari::year. "\n";
			#$year = uri_escape($year);
	    	$sruquery .= "+AND" . $yearquery . $Vari::year;

		} elsif ($Flag::HAS_PAGES) {
			#debug
			print $fh_report "Seiten-Suche: ".$Vari::pages. "\n";
	    	$sruquery .= "+AND" . $anyquery . $Vari::pages;			

		} else {
		
			#debug
			print $fh_report "Kein weiteres Suchfeld!\n";
			print $fh_report "Treffermenge zu hoch!!!\n";	
			print $fh_report "*****************************************************\n\n";
		}
		print $fh_report "URL erweitert: ". $sruquery. "\n";
		#Suche wiederholen mit neuer query:
		# load xml as DOM object, # register namespaces of xml
		$dom = XML::LibXML->load_xml( location => $sruquery );
		$xpc = XML::LibXML::XPathContext->new($dom);

		# get nodes of records with XPATH
		@record = $xpc->findnodes('/searchRetrieveResponse/records/record/recordData/record');

		$numberofrecords = $xpc->findnodes('/searchRetrieveResponse/numberOfRecords');
		$numberofrecords = int($numberofrecords);

		# debug:	
		print $fh_report "Treffer mit erweitertem Suchstring: " .$numberofrecords."\n\n";	
				

	} else {
		print $fh_report "Treffermenge ok.\n";	
	
	}
	
	if ($numberofrecords >= 1 && $numberofrecords <= 10) {
		
		# compare fields in record:
		$i = 1;
		foreach $rec (@record) {
			print $fh_report "#Document $i:\n";
			resetMatch(); # setze für jeden Record die MATCHES wieder auf 0.
			#CHECK AUTHORS & AUTHORITIES:
			if ($Flag::HAS_AUTHOR && $xpc->exists( './datafield[@tag="100"]', $rec)){
				foreach $el ($xpc->findnodes( './datafield[@tag=100]', $rec)){
		         $Marc::MARC100a = $xpc->findnodes('./subfield[@code="a"]', $el )->to_literal;
					# debug: 
					print $fh_report "Feld 100a: ".$Marc::MARC100a."\n";
					print $fh_report "Autor: ".$Vari::author."\n";
					if ($Marc::MARC100a=~ m/$Vari::author/i) { #kommt Autor in 100a vor? (ohne Gross-/Kleinschreibung zu beachten)
						$Match::AUTHORMATCH = 10;
					} #else { $Match::AUTHORMATCH = 0; }
					# debug: 
					print $fh_report "AUTHORMATCH: ".$Match::AUTHORMATCH."\n";
		     	}
		 	} elsif ($Flag::HAS_AUTHOR && $xpc->exists( './datafield[@tag="700"]', $rec)){
				foreach $el ($xpc->findnodes( './datafield[@tag=700]', $rec)){
		         $Marc::MARC700a = $xpc->findnodes('./subfield[@code="a"]', $el )->to_literal;
					# debug: 
					print $fh_report "Feld 700a: ".$Marc::MARC700a."\n";
					print $fh_report "Autor: ".$Vari::author."\n";					
					if ($Marc::MARC700a=~ m/$Vari::author/i) { #kommt Autor in 700a vor? (ohne Gross-/Kleinschreibung zu beachten)
						$Match::AUTHORMATCH = 10;
					} #else { $Match::AUTHORMATCH = 0; }
					# debug: 
					print $fh_report "AUTHORMATCH: ".$Match::AUTHORMATCH."\n";
		     	}
			}
			
			if ($Flag::HAS_AUTHOR2 && $xpc->exists( './datafield[@tag="700"]', $rec)){
				foreach $el ($xpc->findnodes( './datafield[@tag=700]', $rec)){
		         $Marc::MARC700a = $xpc->findnodes('./subfield[@code="a"]', $el )->to_literal;
					# debug: 
					print $fh_report "Feld 700a: ".$Marc::MARC700a."\n";
					print $fh_report "Autor2: ".$Vari::author2."\n";					
					if ($Marc::MARC700a=~ m/$Vari::author2/i) { #kommt Autor2 in 700a vor? (ohne Gross-/Kleinschreibung zu beachten)
						$Match::AUTHORMATCH += 10; #füge 10 Punkte hinzu.
					} 
					# debug: 
					print $fh_report "AUTHORMATCH: ".$Match::AUTHORMATCH."\n";
		     	}
		 	}

			if ($Flag::HAS_AUTHORITY && $xpc->exists( './datafield[@tag="110"]', $rec)){
				foreach $el ($xpc->findnodes( './datafield[@tag=110]', $rec)){
		         $Marc::MARC110a = $xpc->findnodes('./subfield[@code="a"]', $el )->to_literal;
					# debug: 
					print $fh_report "Feld 110a: ".$Marc::MARC110a."\n";
					print $fh_report "Körperschaft: ".$Vari::author."\n";					
					if ($Marc::MARC110a=~ m/$Vari::author/i) { #kommt Körperschaft in 110a vor? (ohne Gross-/Kleinschreibung zu beachten)
						$Match::AUTHORMATCH = 10;
					} #else { $Match::AUTHORMATCH = 0; }
					# debug: 
					print $fh_report "AUTHORITYMATCH: ".$Match::AUTHORMATCH."\n";
		     	}
		 	}

			## CHECK TITLE: TODO subtitle, title addons, etc., other marc fields (246a, 245b, 246b)
		 	if ($xpc->exists('./datafield[@tag="245"]', $rec)){		     
		     	foreach $el ($xpc->findnodes( './datafield[@tag=245]', $rec)){
		         $Marc::MARC245a= $xpc->findnodes('./subfield[@code="a"]', $el )->to_literal;
					# debug: 
					print $fh_report "Feld 245a: ".$Marc::MARC245a. "\n";  
					print $fh_report "Titel: ".$Vari::title. "\n"; 

					if ($Marc::MARC245a =~m/$Vari::title/i) {#kommt Titel in 245a vor? (ohne Gross-/Kleinschreibung zu beachten)
						$Match::TITLEMATCH = 10;
					} elsif ((substr $Marc::MARC245a, 0,10) =~m/$Vari::shorttitle/i) { #TODO: Kurztitellänge anpassen? Hier: 10 Zeichen.
						$Match::TITLEMATCH = 5; 
					}
					# debug: 
					print $fh_report "TITLEMATCH: ".$Match::TITLEMATCH."\n";       
	     		}
			} 
			## Year: TODO: Feld 264 etc. bereinigen (nur Zahlen vergleichen)

		 	if ($Flag::HAS_YEAR && $xpc->exists('./datafield[@tag="264"]', $rec)){# 264
		     
		     foreach $el ($xpc->findnodes( './datafield[@tag=264]', $rec)){
		         $Marc::MARC264c = $xpc->findnodes('./subfield[@code="c"]', $el )->to_literal;

					# debug: 
					print $fh_report "Feld 264c: ".$Marc::MARC264c."\n";   
					print $fh_report "Jahr: ".$Vari::year."\n"; 
					if ($Vari::year eq $Marc::MARC264c) {
						$Match::YEARMATCH = 20;
					} elsif (($Vari::year+1) eq $Marc::MARC264c || ($Vari::year -1) eq $Marc::MARC264c) { #1 year off is okay.
						$Match::YEARMATCH = 10;
					} #else { 						$Match::YEARMATCH = 0; 					}
					# debug: 
					print $fh_report "YEARMATCH: ".$Match::YEARMATCH."\n"; 
		     	}

	 		} elsif ($Flag::HAS_YEAR && $xpc->exists('./datafield[@tag="260"]', $rec)) {#260
		     foreach $el ($xpc->findnodes( './datafield[@tag=260]', $rec)){
		         $Marc::MARC260c = $xpc->findnodes('./subfield[@code="c"]', $el )->to_literal;

					# debug: 
					print $fh_report "Feld 260c: ".$Marc::MARC260c."\n";   
					print $fh_report "Jahr: ".$Vari::year."\n"; 
					if ($Vari::year eq $Marc::MARC260c) {
						$Match::YEARMATCH = 20;
					} elsif (($Vari::year+1) eq $Marc::MARC260c || ($Vari::year -1) eq $Marc::MARC260c) { #+/- 1 year is ok.
						$Match::YEARMATCH = 10;
					} #else { $Match::YEARMATCH = 0; }
					# debug: 
					print $fh_report "YEARMATCH: ".$Match::YEARMATCH."\n"; 
		     	}

			} elsif ($Flag::HAS_YEAR && $xpc->exists('./datafield[@tag="773"]', $rec)) {#773
		     foreach $el ($xpc->findnodes( './datafield[@tag=773]', $rec)){
		         $Marc::MARC773g = $xpc->findnodes('./subfield[@code="g"]', $el )->to_literal;

					# debug: 
					print $fh_report "Feld 773g: ".$Marc::MARC773g."\n";   
					print $fh_report "Jahr: ".$Vari::year."\n"; 
					if ($Marc::MARC773g=~m/$Vari::year/i) {
						$Match::YEARMATCH = 20;
					} #else { $Match::YEARMATCH = 0; }
					# debug: 
					print $fh_report "J-Match: ".$Match::YEARMATCH."\n"; 
		     	}
			}
			# PLACE:

		 	if ($Flag::HAS_PLACE && $xpc->exists('./datafield[@tag="264"]', $rec)){ #264
		     
		     foreach $el ($xpc->findnodes( './datafield[@tag=264]', $rec)){
					$Marc::MARC264a = $xpc->findnodes('./subfield[@code="a"]', $el )->to_literal;
					# debug: 
					print $fh_report "Feld 264a: ".$Marc::MARC264a."\n";   
					print $fh_report "Ort: ".$Vari::place."\n"; 
					if ($Marc::MARC264a=~m/$Vari::place/i) {
						$Match::PLACEMATCH = 15;
					} #else { $Match::PLACEMATCH = 0; }
					# debug: 
					print $fh_report "P-Match: ".$Match::PLACEMATCH."\n"; 
		     	}

	 		} elsif ($Flag::HAS_PLACE && $xpc->exists('./datafield[@tag="260"]', $rec)) {# 260

		     foreach $el ($xpc->findnodes( './datafield[@tag=260]', $rec)){
					$Marc::MARC260a = $xpc->findnodes('./subfield[@code="a"]', $el )->to_literal;
					# debug: 
					print $fh_report "Feld 260a: ".$Marc::MARC260a."\n";   
					print $fh_report "Ort: ".$Vari::place."\n"; 
					if ($Marc::MARC260a=~m/$Vari::place/i) {
						$Match::PLACEMATCH = 15;
					} #else { $Match::PLACEMATCH = 0; }
					# debug: 
					print $fh_report "PLACEMATCH: ".$Match::PLACEMATCH."\n"; 
		     	}
			}

			# PUBLISHER: TODO: nur das 1. Wort vergleichen oder alles nach / abschneiden.

		 	if ($Flag::HAS_PUBLISHER && $xpc->exists('./datafield[@tag="264"]', $rec)){ #264
		     
		     foreach $el ($xpc->findnodes( './datafield[@tag=264]', $rec)){
					$Marc::MARC264b = $xpc->findnodes('./subfield[@code="b"]', $el )->to_literal;
					# debug: 
					print $fh_report "Feld 264b: ".$Marc::MARC264b."\n";   
					print $fh_report "Verlag: ".$Vari::publisher."\n"; 
					if ($Marc::MARC264b =~m/$Vari::publisher/i) {
						$Match::PUBLISHERMATCH = 10;
					} #else { $Match::PUBLISHERMATCH = 0; }
					# debug: 
					print $fh_report "V-Match: ".$Match::PUBLISHERMATCH."\n"; 
		     	}

	 		} elsif ($Flag::HAS_PUBLISHER && $xpc->exists('./datafield[@tag="260"]', $rec)) {# 260
		     foreach $el ($xpc->findnodes( './datafield[@tag=260]', $rec)){
					$Marc::MARC260b = $xpc->findnodes('./subfield[@code="b"]', $el )->to_literal;
					# debug: 
					print $fh_report "Feld 260b: ".$Marc::MARC260b."\n";   
					print $fh_report "Verlag: ".$Vari::publisher."\n"; 
					if ($Marc::MARC260b =~m/$Vari::publisher/i) {
						$Match::PUBLISHERMATCH = 10;
					} #else { $Match::PUBLISHERMATCH = 0; }
					# debug: 
					print $fh_report "PUBLISHERMATCH: ".$Match::PUBLISHERMATCH."\n"; 
		     	}
			}
			
			#PAGINATION: Leicht Abweichende Seitenzahlen --> keine numerischen Werte, Rechnung funktioniert nicht. 

		 	if ($Flag::HAS_PAGES && $xpc->exists('./datafield[@tag="300"]', $rec)){ #300
		     
		     foreach $el ($xpc->findnodes( './datafield[@tag=300]', $rec)){
					$Marc::MARC300a = $xpc->findnodes('./subfield[@code="a"]', $el )->to_literal;
					# debug: 					print $fh_report "Feld 300a: ".$Marc::MARC300a."\n"; 
					$Marc::MARC300a =~ s/[^0-9]//g; # keep only numbers
					print $fh_report "Feld 300a bereinigt: ".$Marc::MARC300a."\n"; 
					print $fh_report "Seiten: ".$Vari::pages."\n"; 
					if ($Marc::MARC300a =~m/$Vari::pages/i) {
						$Match::PAGEMATCH = 20;
					} #elsif ((int($Vari::pages) - int($Marc::MARC300a))<10 || (int($Vari::pages) - int($Marc::MARC300a)) >-10) { #TODO hier stimmt was nicht...
						#$Match::PAGEMATCH = 15;					} #else { $Match::PAGEMATCH = 0; }
					# debug: 
					print $fh_report "PAGEMATCH: ".$Match::PAGEMATCH."\n"; 
		     	}

	 		} elsif ($Flag::HAS_PAGERANGE && $xpc->exists('./datafield[@tag="773"]', $rec)) {# 773 / TODO: Seitenzahlen rausfiltern aus Feld 773g
		     foreach $el ($xpc->findnodes( './datafield[@tag=773]', $rec)){
					$Marc::MARC773g = $xpc->findnodes('./subfield[@code="g"]', $el )->to_literal;
					# debug: 
					print $fh_report "Feld 773g: ".$Marc::MARC773g."\n";   
					print $fh_report "Seiten: ".$Vari::pages."\n"; 
					if ($Marc::MARC773g =~m/$Vari::pages/i) {
						$Match::PAGEMATCH = 20;
					} #else { $Match::PAGEMATCH = 0; }
					# debug: 
					print $fh_report "PAGEMATCH: ".$Match::PAGEMATCH."\n"; 
		     	} 			## TODO: $HAS_PAGERANGE, field 773 subfield g, eg. "23 (1968), Nr. 7, S. 538-542", compare for not so exact pages...
			}
			## Posessing library network: search for HIFF in subfield F instead of bibnr. // TODO: das funktioniert nicht immer. Besser Feld 035.
		 	if ($xpc->exists('./datafield[@tag="949"]', $rec)){

		     	foreach $el ($xpc->findnodes( './datafield[@tag=949 ]', $rec)){
		         $Marc::MARC949B= $xpc->findnodes('./subfield[@code="B"]', $el )->to_literal;     
		         $Marc::MARC949F= $xpc->findnodes('./subfield[@code="F"]', $el )->to_literal;                   
					print $fh_report "Feld 949B: ".$Marc::MARC949B."\n";
					if ($Marc::MARC949B =~/IDSSG/) {# book found in IDSSG
						$Match::IDSSGMATCH = 1; 
						print $fh_report "--------------------------An HSG vorhanden\n"; 
						if ($Marc::MARC949F =~/HIFF/) {
							print $fh_report "Feld 949F: ".$Marc::MARC949F."\n";
							print $fh_report "--------------------------Leider schon vom IFF eingespielt...\n"; 
							$Match::IFFMATCH = 1;
						}

					} elsif ($Marc::MARC949B =~/IDSBB|IDSLU|NEBIS/) {
						print $fh_report "--------------------------OK! Im IDS vorhanden\n"; 
					} else {

						print $fh_report "--------------------------Nur im Rero/SNB vorhanden\n"; 
					}
		     	}
		 	} 

			## Posessing library network II: TODO: HIFF anpassen, s.oben
		 	if ($xpc->exists('./datafield[@tag="852"]', $rec)){

		     	foreach $el ($xpc->findnodes( './datafield[@tag=852 ]', $rec)){
		         $Marc::MARC852B = $xpc->findnodes('./subfield[@code="B"]', $el )->to_literal;            
					print $fh_report "Feld 852B: ".$Marc::MARC852B."\n";
					if ($Marc::MARC852B =~/IDSSG/) {# book or article found in IDSSG
						$Match::IDSSGMATCH += 1; 
						#get record nr.
						foreach $el ($xpc->findnodes( './datafield[@tag=035 ]', $rec)){
							$Match::bibnr = $xpc->findnodes('./subfield[@code="a"]', $el )->to_literal;
							if ($Match::bibnr =~/IDSSG/) { #wenn eine IDSSG-Bibnr. 
								print $fh_report "Bibnr: ".$Match::bibnr."\n";
								$Match::bibnr = substr $Match::bibnr, -7; #only the last 7 numbers
								if ($Match::bibnr > 990000) { #this is a new HSG record and therefore from IFF data
									$Match::IFFMATCH += 1;
									print $fh_report "--------------------------IDSSG - nur ein IFF-Katalogisat!\n"; 
								} else {								
									print $fh_report "------------------------IDSSG - ein altes HSG-Katalogisat!\n"; 
								}
								
							}
							#print $fh_report "Feld 035a: ".$bibnr."\n";
							

						}

					} elsif ($Marc::MARC949B =~/IDSBB|IDSLU|NEBIS/) {
						print $fh_report "--------------------------OK! Im IDS vorhanden\n"; 
					} 
		     	} 
		 	} 
			
		 	$i++;
			$Match::TOTALMATCH = ($Match::TITLEMATCH+$Match::AUTHORMATCH+$Match::YEARMATCH+$Match::PAGEMATCH+$Match::PUBLISHERMATCH+$Match::PLACEMATCH);

		 	print $fh_report "Totalmatch: ".$Match::TOTALMATCH."\n";
			$Match::matches{$Match::TOTALMATCH} = $rec; # add total and record to hash %matches;

			if ($Match::TOTALMATCH >=50 && $numberofrecords == 1) { #correct  match
				print $fh_report "Korrekter Match.\n";				

				if ($Match::IDSSGMATCH >0) {# available at HSG
					if ($Match::IFFMATCH == $Match::IDSSGMATCH) {
						print $fh_report "Es gibt nur das IFF-Kata. Keine Verbesserung möglich. Kata von Felix belassen.\n";
					} else {
						print $fh_report "Es gibt einen guten HSG-Treffer. Von Felix bereits angehängt.\n";
					}
					
				} else {
						print $fh_report "Bestes Kata aus anderem Verbund exportieren und IFF-Exemplar anhängen.\n";

				}
			} elsif ($Match::TOTALMATCH >=35 && $numberofrecords > 1){
				print $fh_report "Mehr als 1 guter Treffer.\n";
				# TODO: finde den Besten!
			} else {
				print $fh_report "Kein guter Match.\n";
			}
		 	print $fh_report "*****************************************************\n\n";
		}

		# TODO: if correct, write out as marcxml, if false, do another query with more parameters 
		push @found, "\n", $found_nr, $Vari::isbn, $Vari::title, $Vari::author, $Vari::year;
		$found_nr++;
	} else {
		# TODO: something wrong with query.
		if ($numberofrecords !=0) {
			print $fh_report "Suchparameter stimmen nicht !!!\n";	
		}
		print $fh_report "*****************************************************\n\n";

	}

}

$csv->eof or $csv->error_diag();
close $fh_in;

$csv->print ($fh_notfound, \@notfound);
$csv->print ($fh_found, \@found);

close $fh_found or die "found.csv: $!";
close $fh_notfound or die "notfound.csv: $!";
close $fh_report or die "report.txt: $!";

print "Total gefunden: ".$found_nr."\n";
print "Total nicht gefunden: ".$notfound_nr."\n";



####################

# SUBROUTINES

#####################

# reset all flags to default value

sub resetFlags {

	$Flag::HAS_ISBN=1;
	$Flag::HAS_ISBN2=0;
	$Flag::HAS_AUTHOR=1;
	$Flag::HAS_AUTHOR2=0;
	$Flag::HAS_AUTHORITY=0;
	$Flag::HAS_SUBTITLE=0;
	$Flag::HAS_VOLUME=0;
	$Flag::HAS_TITLEDATE=0;
	$Flag::HAS_YEAR=1;
	$Flag::HAS_PAGES=1;
	$Flag::HAS_PAGERANGE=0;
	$Flag::HAS_PLACE=1;
	$Flag::HAS_PUBLISHER=1;

}

# reset all match variables to default value

sub resetMatch {

	$Match::AUTHORMATCH=0;
	$Match::TITLEMATCH=0;
	$Match::YEARMATCH=0;
	$Match::PAGEMATCH=0;
	$Match::PUBLISHERMATCH=0;
	$Match::PLACEMATCH=0;
	$Match::IDSSGMATCH=0;
	$Match::IFFMATCH=0;
	$Match::TOTALMATCH=0;
}

