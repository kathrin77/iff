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
use POSIX;

##########################################################
#	DECLARE NECESSARY VARIABLES
##########################################################

my $row;
my (@notfound, @unsure, @journals, @iff_doc_missing, @iff2replace, @export, @re_import, @hsg_duplicate);

my ($rowcounter, $found_nr, $notfound_nr, $unsure_nr, $journal_nr);
my ($replace_nr, $hsg_duplicate_nr, $MARC035_counter, $replace_m_nr, $bestcase_nr, $iff_only_nr, $iff_update, $re_import);
$rowcounter = $found_nr = $notfound_nr = $replace_nr = $replace_m_nr = $hsg_duplicate_nr = $MARC035_counter = 0;
$unsure_nr = $journal_nr = $bestcase_nr = $iff_only_nr = $iff_update = $re_import = 0;

# Fehlercodes:
my $iff_doc_missing_E = 	"Error 101: IFF record not found on Swissbib";
my $notfound_E = 			"Error 102: No records found\n";
my $toomanyfound_E = 		"Error 103: Too many records found\n";
my $bestcase_E = 			"Error 104: cannot be 100% proven: ";

# regex:
my $HYPHEN_ONLY = qr/\A\-/;       # a '-' in the beginning
my $EMPTY_CELL  = qr/\A\Z/;       #nothing in the cell
my $TITLE_SPLIT = qr/\s{2,3}|\s-\s|\.|:/;    #min 2, max 3 whitespaces / ' - ' / ':' / '.'
my $NO_NAME =  qr/\A(NN|N\.N\.|N\.\sN\.)/; # contains only nn or n.n. or n. n.
my $CLEAN_TITLE = qr/\.|\(|\)|\'|\"|\/|\+|\[|\]/ ; #clean following characters: .()'"/+[]
my $CLEAN_PLACE = qr/D\.C\.|a\.M\.|a\/M/; #D.C., a.M.

# material codes:
my $analytica = qr/a|b/;
my $monograph = "m";
my $serial = "s";
my $loseblatt = qr/m|i/;


# testfiles
#my $test  = "data/test30.csv";     # 30 Dokumente
my $test  = "data/test50.csv";     # 50 Dokumente
#my $test = "data/test200.csv";    # 200 Dokumente
#my $test = "data/test_difficult.csv";    # tricky documents

# input, output, filehandles:
my $csv;
my ($fh_in, $fh_notfound, $fh_unsure, $fh_report, $fh_export, $fh_re_import, $fh_hsg_duplicate, $fh_journals, $fh_iff_doc_missing);

# Swissbib SRU-Service for the complete content of Swissbib: MARC XML-swissbib (less namespaces), default = 10 records
my $server_endpoint = 'http://sru.swissbib.ch/sru/search/defaultdb?&operation=searchRetrieve'.
'&recordSchema=info%3Asrw%2Fschema%2F1%2Fmarcxml-v1.1-light&maximumRecords=10&query=';

# needed queries
my $isbnquery   = '+dc.identifier+%3D+';
my $titlequery  = '+dc.title+%3D+';
#my $yearquery   = '+dc.date+%3D+';
my $year_st_query = '+dc.date+%3C%3D+'; # <=
my $year_gt_query = '+dc.date+%3E%3D+'; # >=
my $anyquery    = '+dc.anywhere+%3D+';
my $sruquery;

# XML-Variables
my ($dom, $xpc, $numberofrecords, $rec, $el, $i);
my @record;

# IFF values from CSV:
my (@authors, $author, $author2, @authority, $author_size, $escaped_author);
my (@titles, $title, $subtitle, $volume, $titledate, $escaped_title, $vol_title);
my ($isbn, $isbn2, $isbnlength, $source, $sourcetitle, $sourceauthor, $materialtype);
my ($pages, $material, $created, $addendum, $location, $callno, $place, $publisher, $year, $yearminus1, $yearplus1, $note);
my ($tsignature, $tsignature_1, $tsignature_2, $subj1, $subj2, $subj3);

# Flags
my ($HAS_ISBN, $HAS_ISBN2, $HAS_AUTHOR, $HAS_AUTHOR2, $HAS_AUTHORITY, $HAS_SUBTITLE, $HAS_VOLUME, $HAS_TITLEDATE);
my ($HAS_YEAR, $HAS_PAGES, $HAS_PAGERANGE, $HAS_PLACE, $HAS_PUBLISHER, $IS_ANALYTICA, $IS_SERIAL, $IS_LOSEBLATT);
my ($bestcase);

# Marc fields
my $field;
my ($LDR, $MARC008, $MARC001, $OCLCnr, $MARC035a);
my ($MARC949j, $MARC949F, $MARC852F, $MARC852B);

# Matching variables
my ($ISBNMATCH, $AUTHORMATCH, $TITLEMATCH, $YEARMATCH, $PUBLISHERMATCH, $PLACEMATCH, $MATERIALMATCH, $SOURCEMATCH);
my ($IFFTOTAL, $TOTALMATCH, $IDSSGMATCH, $IFFMATCH, $IDSMATCH, $REROMATCH, $SGBNMATCH);
my ($bibnr, @bestmatch);

##########################################################
# 	READ AND TREAT THE DATA
# Data: IFF_Katalog_FULL.csv contains all data, has been treated (removed \r etc.)
##########################################################

# open input/output:
$csv =
  Text::CSV->new( { binary => 1, sep_char => ";" } )    # CSV-Char-Separator = ;
  or die "Cannot use CSV: " . Text::CSV->error_diag();

open $fh_in, "<:encoding(utf8)", $test or die "$test: $!";
open $fh_notfound, ">:encoding(utf8)", "notfound.csv" or die "notfound.csv: $!";
open $fh_unsure,   ">:encoding(utf8)", "unsure.csv"   or die "unsure.csv: $!";
open $fh_journals, ">:encoding(utf8)", "journals.csv"   or die "journals.csv: $!";
open $fh_iff_doc_missing, ">:encoding(utf8)", "iff_doc_missing.csv"   or die "iff_doc_missing.csv: $!";
open $fh_report,   ">:encoding(utf8)", "report.txt"   or die "report.txt: $!";
open $fh_export, ">:encoding(utf8)", "export.csv"  or die "export.csv: $!";
open $fh_re_import, ">:encoding(utf8)", "re_import.csv"  or die "re_import.csv: $!";
open $fh_hsg_duplicate, ">:encoding(utf8)", "hsg_duplicate.csv"  or die "hsg_duplicate.csv: $!";

# read each line and do...:
while ( $row = $csv->getline($fh_in) ) {
	
	emptyVariables(); #empty all variables from last row's values

    #get all necessary variables
    $author = $row->[0]; $title = $row->[1]; $isbn = $row->[2]; $pages = $row->[3]; $material = $row->[4]; $addendum = $row->[6]; 
    $callno = $row->[8]; $place = $row->[9]; $publisher = $row->[10]; $year = $row->[11]; $subj1 = $row->[16];
    $location = $row->[7]; $note = $row->[12]; 
    $tsignature = $row->[13]; $tsignature_1 = $row->[14]; $tsignature_2 = $row->[15]; $subj2 = $row->[17]; $subj3 = $row->[18];
    
    resetFlags(); #reset all flags and counters
    
    $rowcounter++;
    print $fh_report "\nNEW ROW: #"
      . $rowcounter
      . "\n*********************************************************************************\n";
       
    
    ##########################
    # Deal with ISBN:
    ##########################

    # 	remove all but numbers and X
    $isbn =~ s/[^0-9xX]//g;
    $isbnlength = length($isbn);

    if ( $isbnlength == 26 ) {    #there are two ISBN-13
        $isbn2 = substr $isbn, 13;
        $isbn  = substr $isbn, 0, 13;
        $HAS_ISBN = $HAS_ISBN2 = 1;
    }
    elsif ( $isbnlength == 20 ) {    #there are two ISBN-10
        $isbn2 = substr $isbn, 10;
        $isbn  = substr $isbn, 0, 10;
        $HAS_ISBN = $HAS_ISBN2 = 1;
    }
    elsif ( $isbnlength == 13 || $isbnlength == 10 )
    {                                      #one valid ISBN
        $HAS_ISBN = 1;
    }
	#debug
	print $fh_report "ISBN: " . $isbn . "  ISBN-2: " . $isbn2 . "\n";

    #############################
    # Deal with AUTHOR/AUTORITIES
    #############################
	
    #replace Schweiz. 
    if ($author =~ /Schweiz\./) {
    	if ($author =~/Nationalfonds|Wissenschaftsrat/i) { # schweizerischer
    		$author =~ s/Schweiz./Schweizerischer/i;
    	} else {
    		$author =~ s/Schweiz./Schweizerische/i;
    	}
    }
    $author = trim($author);
    $author =~ s/\.//g;       #remove dots
    $author =~ s/\(|\)//g;    #remove ()

    #check if empty author or if author = NN or the like:
    if (   $author =~ /$EMPTY_CELL/  || $author =~ /$HYPHEN_ONLY/ || $author =~ /$NO_NAME/)
    {
        $HAS_AUTHOR = 0;
        $author     = '';
    }



    #check if several authors: contains "/"?
    if ( $HAS_AUTHOR && $author =~ /[\/]/ ) {
        @authors     = split( '/', $author );
        $author      = $authors[0];
        $author2     = $authors[1];
        $HAS_AUTHOR2 = 1;
    }

    #check if authority rather than author: check for typical words or if more than 3 words long:

    if ($HAS_AUTHOR) {
        if ( $author =~ /amt|Amt|kanzlei|Schweiz|institut|OECD/ ) 
        {    # TODO maybe more!
            $HAS_AUTHORITY = 1;
            $author_size   = 5;
        }
        else {
            @authority   = split( ' ', $author );
            $author_size = scalar @authority;
        }

        if ( $author_size > 3 ) {    
            $HAS_AUTHORITY = 1;
        } 
        else {                             #probably a person, trim author's last name:                                           
            if ( $author =~ /\Avon|\AVon|\Ade|\ADe|\ALe\s/ )
            {                              #TODO maybe more
                $author = ( split /\s/, $author, 3 )[1];
            }
            else {
                $author = ( split /\s/, $author, 2 )[0];
            }
            if ($HAS_AUTHOR2) {
                if ( $author2 =~ /\Avon|\AVon|\Ade|\ADe|\ALe\s/ )
                {                          #TODO maybe more
                    $author2 = ( split /\s/, $author2, 3 )[1];
                }
                else {
                    $author2 = ( split /\s/, $author2, 2 )[0];
                }
            }
        }

    }

    #Debug:
    print $fh_report "Autor: "      . $author      . " --- Autor2: "      . $author2 . "\n";
    
    ##########################
    # Deal with ADDENDUM:
    ##########################
    
    $addendum = trim($addendum);
    $addendum =~s/$CLEAN_TITLE//g;

    ##########################
    # Deal with TITLE:
    ##########################

    $title = trim($title);
    $title =~ s/^L\'//g;     #remove L' in the beginning
    
    #check for eidg. in title:  
    # check umlaut: $title =~ s/eidg\./eidgen\xc3\xb6ssischen/i;

	#check if title has subtitle that needs to be eliminated: (2 or 3 whitespaces)
    if ( $title =~ /$TITLE_SPLIT/ ) {
        @titles       = ( split /$TITLE_SPLIT/, $title );
        $subtitle     = $titles[1];
        $title        = $titles[0];
        $HAS_SUBTITLE = 1;
    }

    $title =~s/$CLEAN_TITLE//g;

	#check if title has volume information that needs to be removed: (usually: ... - Bd. ...)
    if ( $title =~
        /-\sBd|-\sVol|-\sReg|-\sGen|-\sTeil|-\s\d{1}\.\sTeil|-\sI{1,3}\.\sTeil/
      )
    {
        $volume = ( split / - /, $title, 2 )[1];
        $title  = ( split / - /, $title, 2 )[0];
        $HAS_VOLUME = 1;
        if ($addendum !~ $EMPTY_CELL) {
        	$vol_title = $addendum;
        }

    }

    #check if the title contains years or other dates and remove them:
    if ( $title =~ /-\s\d{1,4}/ ) {
        $titledate = ( split / - /, $title, 2 )[1];
        $title     = ( split / - /, $title, 2 )[0];
        $HAS_TITLEDATE = 1;
    }

    if ( $title =~ /\s\d{1,4}\Z/ ) {    # Das Lohnsteuerrecht 1972
        $titledate     = substr $title, -4;
        $title         = ( split /\s\d{1,4}/, $title, 2 )[0];
        $HAS_TITLEDATE = 1;
    }
    elsif ( $title =~ /\s\d{4}\/\d{2}\Z/ )
    {                                         #Steuerberater-Jahrbuch 1970/71
        $titledate     = substr $title, -7;
        $title         = ( split /\s\d{4}\/\d{2}/, $title, 2 )[0];
        $HAS_TITLEDATE = 1;
    }
    elsif ( $title =~ /\s\d{4}\/\d{4}\Z/ )
    {                                         #Steuerberater-Jahrbuch 1970/1971
        $titledate     = substr $title, -9;
        $title         = ( split /\s\d{4}\/\d{4}/, $title, 2 )[0];
        $HAS_TITLEDATE = 1;
    }
    elsif ( $title =~ /\s\d{4}\-\d{4}\Z/ )
    {    #Sammlung der Verwaltungsentscheide 1947-1950
        $titledate     = substr $title, -9;
        $title         = ( split /\s\d{4}\-\d{4}/, $title, 2 )[0];
        $HAS_TITLEDATE = 1;
    }
    
    print $fh_report "Titel: $title \nUntertitel: $subtitle  --- Titeldatum: $titledate --- Band: $volume --- Bandtitel: $vol_title\n";

    #############################################
    # Deal with YEAR
    #############################################

    if (   $year =~ /$EMPTY_CELL/        || $year =~ /$HYPHEN_ONLY/        || $year =~ /online/ )
    {
        if ($titledate =~ /$EMPTY_CELL/) {
			$HAS_YEAR = 0;
        	$year     = '';
        } else {
        	$year = $titledate;
        }
    }
    
    if (defined $year) {
    	$yearminus1 = ($year -1);
    	$yearplus1 = ($year + 1);
    }
    
    #############################################
    # Deal with PAGES
    #############################################

    if ( $pages =~ /$EMPTY_CELL/ || $pages =~ /$HYPHEN_ONLY/ ) {
        $HAS_PAGES = 0;
        $pages     = '';
    }
    elsif ( $pages =~ /\AS.\s/ || $pages =~ /\-/ || $pages =~ /ff/)
    { #very likely not a monography but a volume or article, eg. S. 300ff or 134-567
        $HAS_PAGERANGE = 1;
    }
    
    #############################################
    # Deal with PLACE 
    #############################################

    if (   $place =~ /$EMPTY_CELL/
        || $place =~ /$HYPHEN_ONLY/
        || $place =~ /0/ )
    {
        $HAS_PLACE = 0;
        $place     = '';
    }

    $place =~s/$CLEAN_PLACE//g;
    $place =~s/\,.*//; #remove everything after ,
    $place =~s/\/.*//; #remove everything after /
    $place =~s/St\.Gallen/St\. Gallen/; #write St. Gallen always with whitespace
   
    #############################################
    # Deal with PUBLISHER
    #############################################

    if (   $publisher =~ /$EMPTY_CELL/
        || $publisher =~ /$HYPHEN_ONLY/ )
    {
        $HAS_PUBLISHER = 0;
        $publisher     = '';
    }

	#check if publisher has words that needs to be removed: (usually: Der die das The le la)
    if ( $publisher =~ m/der\s|die\s|das\s|the\s|le\s|la\s/i ) {
        $publisher = ( split /\s/, $publisher, 2 )[1];

    }
    # Remove "Verlag" etc. from publishers name.
    $publisher =~ s/Verlag|Verl\.|Verlagsbuchhandlung|Druck|Druckerei|publisher|publishers|\'//g;
    
    ##########################
    # Deal with Material type
    ##########################
    
    if (($subj1 =~ /Zeitschrift/) || ($title =~ /jahrbuch|yearbook|cahiers de droit fiscal international|ifst-schrift|Steuerentscheid StE/i)) {
        $IS_SERIAL = 1; 
        $materialtype = $serial;
    }
    
    if ($material =~ /Loseblatt/) {
		$IS_LOSEBLATT = 1;
		$materialtype = $loseblatt;
		$HAS_YEAR = 0; # year for Loseblatt is usually wrong and leads to zero search results.
    }
    
    if (($addendum =~ m/in: /i) || ($HAS_PAGERANGE)) {
        $IS_ANALYTICA = 1; 
        $materialtype = $analytica;
        $source = $addendum; 
        $source =~ s/^in: //i; #replace "in: "    
        $HAS_ISBN = 0; # ISBN for Analytica is confusing for search (ISBN for source, not analytica)
        $sourcetitle = (split /: /, $source, 2)[1];
        $sourceauthor = (split /: /, $source, 2 )[0];
    }
    
    
    print $fh_report "Ort: $place --- Verlag: $publisher --- Jahr: $year --- Materialart: $materialtype --- Seitenzahlen: $pages\n";
    if (defined $sourcetitle) {print $fh_report "Sourcetitle: $sourcetitle, Sourceauthor: $sourceauthor\n";}
    if (defined $addendum ) {print $fh_report "Addendum: $addendum\n";}
    
    ############################
    # Serials: skip, next row
    ############################
    
    if ($IS_SERIAL) {
    	print $fh_report "ZEITSCHRIFT, JAHRBUCH ODER CAHIERS DE DROIT INTERNATIONAL...0000000000000000000000000000000000000\n";
    	push @journals, $row;
    	$journal_nr++;
    	next;    	
    }

    ######################################################################
    # START SEARCH ON SWISSBIB
    # Documentation of Swissbib SRU Service:    # http://www.swissbib.org/wiki/index.php?title=SRU    #
    ######################################################################

    # Build Query:
    $sruquery = '';

    $escaped_title  = uri_escape_utf8($title);
    $escaped_author = uri_escape_utf8($author);
    $sruquery =
        $server_endpoint
      . $titlequery
      . $escaped_title . "+AND"
      . $anyquery
      . $escaped_author;    # "any" query also searches 245$c;

	#note: all documents except journals have an "author" field in some kind, so it should never be empty.
    if ($HAS_YEAR) {
       # $sruquery .= "+AND" . $yearquery . $year;
       $sruquery .= "+AND" . $year_st_query . $yearplus1 . "+AND" . $year_gt_query . $yearminus1; 
    }

    # Debug:
    print $fh_report "URL: " . $sruquery . "\n";

    # load xml as DOM object, # register namespaces of xml
    $dom = XML::LibXML->load_xml( location => $sruquery );
    $xpc = XML::LibXML::XPathContext->new($dom);

    # get nodes of records with XPATH
    @record = $xpc->findnodes(
        '/searchRetrieveResponse/records/record/recordData/record');
        
    if ($xpc->exists('/searchRetrieveResponse/numberOfRecords')) {
    	$numberofrecords =
      $xpc->findvalue('/searchRetrieveResponse/numberOfRecords');
    } else {
    	$numberofrecords = 0;

    }

    # debug:
    print $fh_report "Treffer: " . $numberofrecords . "\n";
    
    ##################################################
    # Handle bad results: $numberofrecords = 0 
	##################################################
	
    if ( $numberofrecords == 0 ) {
        #repeat query without year or with isbn:
        $sruquery = "";
        if ($HAS_ISBN) {
            $sruquery = $server_endpoint . $isbnquery . $isbn;
        }
        else { 
            $sruquery =
                $server_endpoint
              . $anyquery
              . $escaped_title . "+AND"
              . $anyquery
              . $escaped_author;
        }
        #TODO try other variations without title

        print $fh_report "URL geaendert, da 0 Treffer: " . $sruquery . "\n";

        #Repeat search with new query:
        $dom = XML::LibXML->load_xml( location => $sruquery );
        $xpc = XML::LibXML::XPathContext->new($dom);
        @record = $xpc->findnodes(
            '/searchRetrieveResponse/records/record/recordData/record');
            
        if ($xpc->exists('/searchRetrieveResponse/numberOfRecords')) {
			$numberofrecords = $xpc->findvalue('/searchRetrieveResponse/numberOfRecords');
        } else {$numberofrecords = 0;}

        if ( $numberofrecords > 0 && $numberofrecords <= 10 ) {
            print $fh_report "Treffer mit geaendertem Suchstring: "
              . $numberofrecords . "\n";
        }
        else {
            #debug
            print $fh_report "$notfound_E\n". 
            "ooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooo\n\n";
            $notfound_nr++;
            push @notfound, $row;
        }

    }
    
    ##################################################
    # Handle bad results: $numberofrecords > 10
	##################################################
	
    if ( $numberofrecords > 10 ) {
        if ($HAS_PUBLISHER) {
            $sruquery .= "+AND" . $anyquery . $publisher;
        }
        elsif ($HAS_PLACE) {
            $sruquery .= "+AND" . $anyquery . $place;
        }
        else {
            #debug
            print $fh_report "$toomanyfound_E\n";
            print $fh_report "OOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOO\n\n";
            $notfound_nr++;
            push @notfound, $row;
        }
        print $fh_report "URL erweitert: " . $sruquery . "\n";

        #Repeat search with new query:
        $dom = XML::LibXML->load_xml( location => $sruquery );
        $xpc = XML::LibXML::XPathContext->new($dom);
        @record = $xpc->findnodes(
            '/searchRetrieveResponse/records/record/recordData/record');
            
        if ($xpc->exists('/searchRetrieveResponse/numberOfRecords')) {
        	$numberofrecords = $xpc->findvalue('/searchRetrieveResponse/numberOfRecords');        	
        } else {$numberofrecords = 0;}


        if ( $numberofrecords <= 10 && $numberofrecords >0) {
            print $fh_report "Treffer mit erweitertem Suchstring: "
              . $numberofrecords . "\n";
        }
        else {
            #debug
            print $fh_report "$toomanyfound_E\n".
            print $fh_report "OOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOO\n\n";
            $notfound_nr++;
            push @notfound, $row;
        }

    }
    
    #########################################
    # Handle good result set
    #########################################

    if ( $numberofrecords >= 1 && $numberofrecords <= 10 ) {

        # compare fields in record:
        $i = 1;
        foreach $rec (@record) {
            print $fh_report "\n#Document $i:\n";
            # reset all match variables to default value
            $AUTHORMATCH = $TITLEMATCH = $YEARMATCH = $PUBLISHERMATCH = $PLACEMATCH = $SOURCEMATCH = 0;
            $ISBNMATCH  = $MATERIALMATCH = $TOTALMATCH  = $IFFTOTAL = $MARC035_counter = 0;
    		$IDSSGMATCH = $IFFMATCH = $SGBNMATCH = $IDSMATCH = $REROMATCH = 0;
    		$bibnr = 0;

            ############################################
            # CHECK ISBN MATCH
            ############################################    
            
            if ($HAS_ISBN) {
            	if (hasTag("020", $xpc,$rec)) {
            		foreach $el ( $xpc->findnodes( './datafield[@tag=020]', $rec ) ) {
            			$field = $xpc->findnodes( './subfield[@code="a"]', $el )->to_literal;
            			$field =~ s/[^0-9xX]//g;
            			print $fh_report "\$a: ".$field."\n";
            			if ($isbn =~ m/$field/i) {
            				$ISBNMATCH = 10;
            			}
						if ($HAS_ISBN2 && $isbn2 =~ m/$field/i ) {
            				$ISBNMATCH += 5;
            			}
            		}
            		print $fh_report "ISBNMATCH: ".$ISBNMATCH ."\n";
            	}
            }       
                  
            ############################################
            # CHECK AUTHORS & AUTHORITIES MATCH
            ############################################ 

            if ($HAS_AUTHOR) {
                if ( hasTag( "100", $xpc, $rec ) ) {     
                    foreach $el ( $xpc->findnodes( './datafield[@tag=100]', $rec ) )
                    {
						$AUTHORMATCH = getMatchValue("a",$xpc,$el,$author,10) ;
                    }

                } elsif (hasTag( "700", $xpc, $rec ) ) {
                    foreach $el ( $xpc->findnodes( './datafield[@tag=700]', $rec ) )
                    {
						$AUTHORMATCH += getMatchValue("a",$xpc,$el,$author,10) ;
                    } 
                }
                if (hasTag("110", $xpc, $rec)) {
                    foreach $el ( $xpc->findnodes( './datafield[@tag=110]', $rec ) )
                    {
						$AUTHORMATCH += getMatchValue("a",$xpc,$el,$author,10) ;
                    }
                } elsif (hasTag("710", $xpc, $rec)) {
                    foreach $el ( $xpc->findnodes( './datafield[@tag=710]', $rec ) )
                    {
						$AUTHORMATCH += getMatchValue("a",$xpc,$el,$author,10) ;
                    }
                }
                # debug:
                print $fh_report "AUTHOR-1-MATCH: ". $AUTHORMATCH . "\n";
            }
            
            if ($HAS_AUTHOR2) {
            	if (hasTag("700", $xpc, $rec)) {
					foreach $el ( $xpc->findnodes( './datafield[@tag=700]', $rec ) )
                    {
						$AUTHORMATCH += getMatchValue("a",$xpc,$el,$author2,10) ;
                    }
                    print $fh_report "AUTHOR-2-MATCH: ". $AUTHORMATCH . "\n"; 
            	}          	     	
            }

            ############################################
            # CHECK TITLE MATCH
            ############################################

            # TODO subtitle, title addons, etc., other marc fields (245b, 246b)
            
            if (hasTag("245",$xpc,$rec)){
                foreach $el ($xpc->findnodes('./datafield[@tag=245]', $rec)) {
                    $TITLEMATCH = getMatchValue("a",$xpc,$el,$title,10);
                    print $fh_report "TITLEMATCH: " . $TITLEMATCH . "\n";                   
                }
            }
             
            if (hasTag("246",$xpc,$rec)) {
                foreach $el ($xpc->findnodes('./datafield[@tag=246]', $rec)) {
                    $TITLEMATCH += getMatchValue("a",$xpc,$el,$title,5);
                    print $fh_report "TITLEMATCH: " . $TITLEMATCH . "\n";
                }
            } 
                        
            ############################################
            # CHECK YEAR MATCH
            ############################################
            
            # OLD Year: Feld 008: pos. 07-10 - Date 1
            
            if ($HAS_YEAR) {
            	if (hasTag("260", $xpc, $rec) || hasTag("264", $xpc, $rec)) {
            		foreach $el ($xpc->findnodes('./datafield[@tag=264 or @tag=260]', $rec)) {
            			$YEARMATCH = getMatchValue("c",$xpc,$el,$year,10);
            			print $fh_report "YEARMATCH: " . $YEARMATCH . "\n";		
            		}            		
            	}
            }

            ############################################
            # CHECK PLACE MATCH
            ############################################
            
            if ($HAS_PLACE) {
                if (hasTag("264", $xpc, $rec) || hasTag("260", $xpc, $rec)) {
                    foreach $el ( $xpc->findnodes( './datafield[@tag=264 or @tag=260]', $rec )) {
                        $PLACEMATCH += getMatchValue("a",$xpc,$el,$place,5);
                        print $fh_report "PLACEMATCH: " . $PLACEMATCH . "\n";
                    }
                }
            }

            ############################################
            # CHECK PUBLISHER MATCH
            ############################################
                        
            if ($HAS_PUBLISHER) {
                if (hasTag("264", $xpc, $rec) || hasTag("260", $xpc, $rec)) {
                    foreach $el ( $xpc->findnodes( './datafield[@tag=264 or @tag=260]', $rec ) ) {
                        $PUBLISHERMATCH += getMatchValue("b",$xpc,$el,$publisher,5);
                        print $fh_report "PUBLISHERMATCH: " . $PUBLISHERMATCH . "\n";
                    }
                }
            }
            
            ###########################################
            # CHECK MEHRBAENDIGE
            ###########################################
            
            if ($HAS_VOLUME) {            	
            	if (hasTag("505", $xpc, $rec)) {
            		foreach $el ($xpc->findnodes('./datafield[@tag=505]', $rec)) {
            			if (!$TITLEMATCH) {# if title has not matched yet
            				$TITLEMATCH += getMatchValue("t",$xpc,$el, $title,10); # check 505 for title
            				print $fh_report "TITLEMATCH 505 title: $TITLEMATCH \n";
            			} else {
            				$TITLEMATCH += getMatchValue("t",$xpc,$el, $vol_title,10); # check 505 for addendum
            				print $fh_report "TITLEMATCH 505 volumetitle: $TITLEMATCH \n";
            			}
            		}   
            	}
            }
            
            ###########################################
            # CHECK ANALYTICA # TODO: 580?
            ###########################################
            
            if ($IS_ANALYTICA) {
            	if (hasTag("773", $xpc, $rec)) {
            		foreach $el ($xpc->findnodes('./datafield[@tag=773]', $rec)){
                       	$SOURCEMATCH = getMatchValue("t", $xpc, $el,$sourcetitle,10); 
						print $fh_report "SOURCEMATCH Analytica: $SOURCEMATCH \n";		
            		}					
            	}            	
            }            
            
            ############################################
            # CHECK MATERIAL MATCH (LDR)
            ############################################
            
            if ( $xpc->exists( './leader', $rec ) ) {
                foreach $el ( $xpc->findnodes( './leader', $rec ) ) {
                    $LDR = $el->to_literal;
                    $LDR = substr $LDR, 7, 1;

                    # debug:
                    print $fh_report "LDR Materialart: " . $LDR . "\n";

                    if ( $materialtype =~ m/$LDR/ ) {
                        $MATERIALMATCH = 15;
                    }

                    # debug:
                    print $fh_report "MATERIALMATCH: "
                      . $MATERIALMATCH . "\n";
                }
            }

            ###########################################
            # Get Swissbib System Nr., Field 001:
            ########################################### 
            # http://www.swissbib.org/wiki/index.php?title=Swissbib_marc

            if ( $xpc->exists( './controlfield[@tag="001"]', $rec ) ) {
                foreach $el (
                    $xpc->findnodes( './controlfield[@tag=001]', $rec ) )
                {
                    $MARC001 = $el->to_literal;

                    # debug:
                    print $fh_report "Swissbibnr.: " . $MARC001 . "\n";

                }
            }
            
            ############################################
            # Get 035 Field and check if old IFF data
            ############################################
            
            if ( hasTag("035", $xpc, $rec) ) {
                foreach $el (
                    $xpc->findnodes( './datafield[@tag=035 ]', $rec ) )
                {
                   	$MARC035a = $xpc->findnodes( './subfield[@code="a"]', $el )->to_literal;
                    #print $fh_report $MARC035a . "\n" unless ( $MARC035a =~ /OCoLC/ );
                    $MARC035_counter++ unless ( $MARC035a =~ /OCoLC/ );

                    if ( $MARC035a =~ /IDSSG/ ) {    # book found in IDSSG
                        $bibnr = substr $MARC035a,-7;    #only the last 7 numbers
                        if ( $bibnr > 990000 ) {   #this is an IFF record
                        	if ($IS_ANALYTICA && ($numberofrecords = 1)) {
                        		$IFFMATCH = 1;        # few negative points if analytica and only one hit.
                        	} else {
                        		$IFFMATCH = 15;        # negative points                        		
                        	}
                        	# get intermediate totalmatch
                        	$IFFTOTAL = $ISBNMATCH + $TITLEMATCH + $AUTHORMATCH + $YEARMATCH + $PUBLISHERMATCH + $PLACEMATCH + $MATERIALMATCH + $SOURCEMATCH;
                        	#check if this IFF document has better value than the one already in the replace-array
                        	if (defined $iff2replace[0] && ($iff2replace[2]>$IFFTOTAL)) {
                        		#do nothing! debug: print "das bereits gefundene IFF-Dokument ist besser!"                        		
                        	} else {
                        		push @iff2replace, $MARC001, $bibnr, $IFFTOTAL;
                        	}

                            print $fh_report "$MARC035a: Abzug fuer IFF_MATCH: -". $IFFMATCH . "\n";
                            
                            if ($MARC035_counter>1) { # other libraries have added to this bibrecord since upload from IFF => reimport
                            	print $fh_report "Re-Import this document: $bibnr, No. of 035-fields: $MARC035_counter \n";
                            	$re_import = 1;
                            	
                            }
                        }
                        else {
                            $IDSSGMATCH = 25;    # a lot of plus points so that it definitely becomes $bestmatch.
                            print $fh_report
                              "$MARC035a Zuschlag fuer altes HSG-Katalogisat: $IDSSGMATCH \n";
                            if ( $xpc->exists( './datafield[@tag="949"]', $rec ) )
                            {
                                foreach $el ($xpc->findnodes('./datafield[@tag=949 ]', $rec))
                                {
                                    $MARC949F =  $xpc->findnodes( './subfield[@code="F"]', $el )->to_literal;
                                    if ($xpc->exists('./subfield[@code="j"]', $el)) {
                                    	$MARC949j =  $xpc->findnodes( './subfield[@code="j"]', $el )->to_literal;                                    	
                                    }
                                    if ( $MARC949F =~ /HIFF/ && $MARC949j =~/$callno/) { # check if this is the same IFF record as $row
                                        print $fh_report "Feld 949: $MARC949F Signatur: $MARC949j --- callno: $callno \n";
                                        $IDSSGMATCH += 10;
                                        print $fh_report "Best case: IFF attached, IDSSGMATCH = $IDSSGMATCH \n";
                                        push @iff2replace, $MARC001, $bibnr, $IFFTOTAL;
                                        $bestcase    = 1;
                                    } elsif ($MARC949F =~ /HIFF/) {
                                    	print $fh_report "Feld 949: $MARC949F Signatur: $MARC949j --- callno: $callno \n";
                                        $IDSSGMATCH += 5;
                                        print $fh_report "$bestcase_E Best case: IFF attached, IDSSGMATCH = $IDSSGMATCH \n";
                                        push @iff2replace, $MARC001, $bibnr, $IFFTOTAL;
                                        $bestcase    = 1;
                                    }

                                }

                            }
                        }

                    }
                    else {
                        if ( $MARC035a =~ m/RERO/ )
                        {    #book from RERO slightly preferred to others
                            $REROMATCH = 6;
                            #print $fh_report "REROMATCH: ". $REROMATCH . "\n";
                        }
                        if ( $MARC035a =~ m/SGBN/ )
                        { #book from SGBN  slight preference over others if not IDS

                            $SGBNMATCH = 4;
                            #print $fh_report "SGBNMATCH: " . $SGBNMATCH . "\n";
                        }
                        if (   $MARC035a =~ m/IDS/ || $MARC035a =~ /NEBIS/ )
                        {    #book from IDS Library preferred

                            $IDSMATCH = 11;
                            #print $fh_report "IDSMATCH: " . $IDSMATCH . "\n";
                        }

                    }
                }
                
                    print $fh_report "Number of 035 fields: $MARC035_counter\n";
                    print $fh_report "Matchpoints: IDS: $IDSMATCH, Rero: $REROMATCH, SGBN: $SGBNMATCH\n";
            }

            $i++;
            $TOTALMATCH =
              ( $ISBNMATCH + $TITLEMATCH + $AUTHORMATCH + $YEARMATCH +
                  $PUBLISHERMATCH + $PLACEMATCH + $MATERIALMATCH + $SOURCEMATCH +
                  $REROMATCH + $SGBNMATCH + $IDSMATCH + $IDSSGMATCH - $IFFMATCH );

            print $fh_report "Totalmatch: " . $TOTALMATCH . "\n";

            if ( $TOTALMATCH > $bestmatch[0])
            { #ist aktueller Match-Total der hoechste aus Trefferliste? wenn ja: 
            	@bestmatch = (); #clear @bestmatch
            	push @bestmatch, $TOTALMATCH, $MARC001, $rec, $bibnr;
            }

        }

        print $fh_report "Bestmatch: $bestmatch[0], Bestrecordnr: $bestmatch[1], bestrecordnr-HSG: $bestmatch[3]\n";

        if ( $bestmatch[0] >= 25 ) {  # a good match was found
            $found_nr++;            
            if (defined $iff2replace[0]) { # an IFF record to replace was found
            
            	if ( $iff2replace[0] eq $bestmatch[1] ) { # IFF-replace matches with HSG-record
	                if ($bestcase) {
	                	$bestcase_nr++;
	                    print $fh_report "Best case scenario: IFF and HSG already matched!\n";                      
	                }
	                else {
	                	if ($re_import) { # IFF-replace can be improved by reimporting
		                    $iff_update++;
		                    print $fh_report "RE-IMPORT this document! Better data available from other libraries.\n";
		                    push @re_import, $bibnr, $MARC001, $callno;
		                    push @re_import, $tsignature, $tsignature_1, $tsignature_2, $subj1, $subj2, $subj3;
		                    push @re_import, "\n";
		                } else {
		                    $iff_only_nr++;
		                   	print $fh_report "Only IFF data available. Best solution from Felix.\n";
		                }
             		}
         		} else { # IFF-replace and bestmatch are not the same;
         		
         			if ($bestmatch[3] != 0) { # bestmatch has a $bibnr and is therefore a HSG document 
         				# export in separate file
         				$hsg_duplicate_nr++;
         				print $fh_report "HSB01 duplicate! Replace $iff2replace[1] with $bestmatch[3], see: hsg_duplicate.csv\n";
	                    push @hsg_duplicate, $iff2replace[1], $bestmatch[3], $callno;
	                    push @hsg_duplicate, $tsignature, $tsignature_1, $tsignature_2, $subj1, $subj2, $subj3;
	                    push @hsg_duplicate, "\r";
         				
         			} else {			
         				$replace_nr++;
	                    print $fh_report "Replace $iff2replace[0] with $bestmatch[1], see: export.csv\n";
	                    push @export, $iff2replace[1], $bestmatch[1], $callno;
	                    push @export, $tsignature, $tsignature_1, $tsignature_2, $subj1, $subj2, $subj3;
	                    push @export, "\r";
         			}

                }

            } else { # no IFF-replace was found
            	$replace_m_nr++;
                print $fh_report "$iff_doc_missing_E. Output: replace CSV line $rowcounter with $bestmatch[1]\n";
                push @iff_doc_missing, $rowcounter, $bestmatch[1], $callno;
                push @iff_doc_missing, $tsignature, $tsignature_1, $tsignature_2, $subj1, $subj2, $subj3;
                push @iff_doc_missing, "\r";;
            }

        }
        else { # no good match was found
        	$unsure_nr++;
            print $fh_report "BESTMATCH ziemlich tief, ueberpruefen!\n\n";
            push @unsure, $row;
        }
    }
}

$csv->eof or $csv->error_diag();
close $fh_in;

$csv->say($fh_notfound, $_) for @notfound;
$csv->say($fh_unsure, $_) for @unsure;
$csv->say($fh_journals, $_) for @journals;
$csv->say($fh_iff_doc_missing, $_) for \@iff_doc_missing;
$csv->say($fh_re_import, $_) for \@re_import;
$csv->say($fh_export, $_) for \@export;
$csv->say($fh_hsg_duplicate, $_) for \@hsg_duplicate;
#print Dumper (@export);

close $fh_notfound or die "notfound.csv: $!";
close $fh_unsure   or die "unsure.csv: $!";
close $fh_journals or die "journals.csv: $!";
close $fh_iff_doc_missing or die "iff_doc_missing.csv: $!";
close $fh_report   or die "report.txt: $!";
close $fh_export   or die "export.csv: $!";
close $fh_re_import or die "re_import.csv: $!";
close $fh_hsg_duplicate or die "hsg_duplicate.csv: $!";

print "Total not found (notfound.csv): " . $notfound_nr . "\n";
print "Total unsure (unsure.csv): " . $unsure_nr . "\n";
print "Total journals (journals.csv): " . $journal_nr. "\n";

print "Total found: " . $found_nr . "\n";

print "-----------------\nTo do with found: \n";
print "Total to replace (export.csv): " . $replace_nr . "\n";
print "Total HSB01 duplicates, to be reattached in HSB01 (hsg_duplicates.csv): $hsg_duplicate_nr \n";
print "Total to replace where IFF-record not found (iff_doc_missing.csv): ".$replace_m_nr."\n";
print "Total already matched: " . $bestcase_nr. "\n";
print "Total that cannot be improved: ".$iff_only_nr."\n";
print "Total that can be improved by re-importing: (re_import.csv) ".$iff_update."\n";





####################

# SUBROUTINES

#####################

# reset all flags to default value

sub resetFlags {

    $HAS_ISBN      = 0;
    $HAS_ISBN2     = 0;
    $HAS_AUTHOR    = 1; # except journals, everything has an author (with few exceptions)
    $HAS_AUTHOR2   = 0;
    $HAS_AUTHORITY = 0;
    $HAS_SUBTITLE  = 0;
    $HAS_VOLUME    = 0;
    $HAS_TITLEDATE = 0;
    $HAS_YEAR      = 1; #default, most titles have a year
    $HAS_PAGES     = 1; #default, most documents have pages
    $HAS_PAGERANGE = 0;
    $HAS_PLACE     = 1; #default, most documents have a place
    $HAS_PUBLISHER = 1; #default, most documents have a publisher
    $IS_SERIAL = 0;
    $IS_LOSEBLATT = 0;
    $IS_ANALYTICA = 0;
    @iff2replace   = ();
    $bestcase      = 0;
    $bestmatch[0] = 0; 
    $re_import = 0;
}



# empty Variables

sub emptyVariables {

    $isbn = '';     $isbn2 = '';     $isbnlength = '';
    $author = '';     $author2 = '';     $author_size = '';
    $title = '';     $subtitle = '';     $volume = '';     $titledate = ''; $vol_title='';
    $pages= ''; $source='';     $sourcetitle=''; $sourceauthor=''; $material= '';
    $addendum= '';     $location= '';     $callno= '';     $place= '';     $publisher= '';
    $year= '';    $yearminus1 = ''; $yearplus1 = '';  $note= '';
    $tsignature= ''; $tsignature_1= ''; $tsignature_2 = ''; $subj1= ''; $subj2= ''; $subj3= '';
    $materialtype = $monograph; # default: most documents are monographs

}

sub hasTag {
    my $tag = $_[0];    # Marc tag
    my $xpath1 = $_[1];    # xpc path
    my $record = $_[2];    # record path
    if ( $xpath1->exists( './datafield[@tag=' . $tag . ']', $record ) ) {
        #debug
        print $fh_report "MARC $tag ";
        return 1;
    }
    else {
        return 0;
    }

}

sub getMatchValue {
    my $code   = $_[0];    #subfield
    my $xpath   = $_[1];     #xpc
    my $element = $_[2];    #el
    my $vari  = $_[3];    #orignal data from csv
    my $posmatch = $_[4];    #which match value shoud be assigned to positive match?
    my $matchvalue;
    my $marcfield;
    #my $shortvari = substr $vari, 0,10; # first 10 letters 
    
    $marcfield = $xpath->findnodes( './subfield[@code="' . $code . '"]', $element)->to_literal;
    $marcfield =~ s/\[|\]|\'|\"|\(|\)//g;    # clean fields from special characters

    # debug: 
    print $fh_report "\$".$code.": " . $marcfield . "\n";
    my $length = length ($marcfield);
    my $halflength = ceil($length/2);
    my $marcshort = substr $marcfield, 0,$halflength;
    my $shortvari = substr $vari, 0, $halflength;
	
    if ( ($vari =~ m/$marcfield/i ) || ($marcfield =~m/$vari/i)){ #Marc Data matches IFF Data
        #debug:        print $fh_report "marcfield full match! \n";
        $matchvalue = $posmatch;
    } elsif (($shortvari =~ m/$marcshort/i ) || ($marcshort =~m/$shortvari/i)) { #half the strings match
        #debug: TODO, this does not work properly yet.
        print $fh_report "marcfield short match! \n";
        $matchvalue = abs($posmatch/2);
    } else {$matchvalue = 0;}
    
    return $matchvalue;
	
}