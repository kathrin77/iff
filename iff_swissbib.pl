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
my (@notfound, @unsure, @journals, @no_monograph);

my ($rowcounter, $found_nr, $notfound_nr, $replace_nr, $replace_m_nr);
my ($unsure_nr, $journal_nr, $no_monograph_nr, $bestcase_nr, $iff_only_nr);
$rowcounter = $found_nr = $notfound_nr = $replace_nr = $replace_m_nr = 0;
$unsure_nr = $journal_nr = $no_monograph_nr = $bestcase_nr = $iff_only_nr = 0;

# regex:
my $HYPHEN_ONLY = qr/\A\-/;       # a '-' in the beginning
my $EMPTY_CELL  = qr/\A\Z/;       #nothing in the cell
my $TITLE_SPLIT = qr/\s{2,3}/;    #min 2, max 3 whitespaces
my $NO_NAME =  qr/\A(NN|N\.N\.|N\.\sN\.)/; # contains only nn or n.n. or n. n.


# testfiles
my $test  = "data/test30.csv";     # 30 Dokumente
#my $test = "data/test200.csv";    # 200 Dokumente
#my $test = "data/test_difficult.csv";    # tricky documents

# input, output, filehandles:
my $csv;
my ($fh_in, $fh_notfound, $fh_unsure, $fh_report, $fh_export, $fh_journals, $fh_no_monograph);

# Swissbib SRU-Service for the complete content of Swissbib: MARC XML-swissbib (less namespaces), default = 10 records
my $server_endpoint = 'http://sru.swissbib.ch/sru/search/defaultdb?&operation=searchRetrieve'.
'&recordSchema=info%3Asrw%2Fschema%2F1%2Fmarcxml-v1.1-light&maximumRecords=10&query=';

# needed queries
my $isbnquery   = '+dc.identifier+%3D+';
my $titlequery  = '+dc.title+%3D+';
my $yearquery   = '+dc.date+%3D+';
my $anyquery    = '+dc.anywhere+%3D+';
my $sruquery;

# XML-Variables
my ($dom, $xpc, $numberofrecords, $rec, $el, $i);
my @record;

# IFF values from CSV:
my (@authors, $author, $author2, @authority, $author_size, $escaped_author);
my (@titles, $title, $subtitle, $volume, $titledate, $escaped_title, $shorttitle);
my ($isbn, $isbn2, $isbnlength);
my ($pages, $material, $created, $addendum, $location, $callno, $place, $publisher, $year, $note);
my ($tsignature, $tsignature_1, $tsignature_2, $subj1, $subj2, $subj3);

# Flags
my ($HAS_ISBN, $HAS_ISBN2, $HAS_AUTHOR, $HAS_AUTHOR2, $HAS_AUTHORITY, $HAS_SUBTITLE, $HAS_VOLUME, $HAS_TITLEDATE);
my ($HAS_YEAR, $HAS_PAGES, $HAS_PAGERANGE, $HAS_PLACE, $HAS_PUBLISHER, $NO_MONOGRAPH);
my ($iff2replace, $bestcase);

# Marc fields
my $field;
my ($LDR, $MARC008, $MARC001, $OCLCnr, $MARC035a);
my ($MARC100a, $MARC110a, $MARC700a, $MARC710a, $MARC245a, $MARC246a);
my ($MARC264c, $MARC264b, $MARC264a, $MARC260c, $MARC260b, $MARC260a, $MARC300a);
my ($MARC773g, $MARC949B, $MARC949F, $MARC852F, $MARC852B);

# Matching variables
my ($ISBNMATCH, $AUTHORMATCH, $TITLEMATCH, $YEARMATCH, $PUBLISHERMATCH, $PLACEMATCH, $MATERIALMATCH);
my ($TOTALMATCH, $IDSSGMATCH, $IFFMATCH, $IDSMATCH, $REROMATCH, $SGBNMATCH);
my ($bibnr, $bestmatch, $bestrecord, $bestrecordnr);

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
open $fh_no_monograph, ">:encoding(utf8)", "no_monograph.csv"   or die "no_monograph.csv: $!";
open $fh_report,   ">:encoding(utf8)", "report.txt"   or die "report.txt: $!";
open $fh_export, ">:encoding(utf8)", "swissbibexport.xml"  or die "swissbibexport.xml: $!";

# read each line and do...:
while ( $row = $csv->getline($fh_in) ) {
	
	emptyVariables(); #empty all variables from last row's values

    #get all necessary variables
    $author = $row->[0]; $title = $row->[1]; $isbn = $row->[2]; $pages = $row->[3]; $material = $row->[4]; $addendum = $row->[6]; 
    $callno = $row->[8]; $place = $row->[9]; $publisher = $row->[10]; $year = $row->[11]; $subj1 = $row->[16];
    #$location = $row->[7]; $note = $row->[12]; $tsignature = $row->[13]; $tsignature_1 = $row->[14];
    #$tsignature_2 = $row->[15]; $subj2 = $row->[17]; $subj3 = $row->[18];
    
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

    $author = trim($author);
    $author =~ s/\.//g;       #remove dots
    $author =~ s/\(|\)//g;    #remove ()

    #check if empty author or if author = NN or the like:
    if (   $author =~ /$EMPTY_CELL/  || $author =~ /$HYPHEN_ONLY/ || $author =~ /$NO_NAME/)
    {
        $HAS_AUTHOR = 0;
        $author     = '';
    }

    #TODO: Schweiz. ausschreiben? aber wie?

    #check if several authors: contains "/"?
    if ( $HAS_AUTHOR && $author =~ /[\/]/ ) {
        @authors     = split( '/', $author );
        $author      = $authors[0];
        $author2     = $authors[1];
        $HAS_AUTHOR2 = 1;
    }

    #check if authority rather than author: check for typical words or if more than 3 words long:
    
    if ($HAS_AUTHOR) {
        if ( $author =~ /amt|Amt|kanzlei|Schweiz\.|institut|OECD/ ) 
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
    # Deal with TITLE:
    ##########################

    $title = trim($title);
    $title =~ s/\.//g;       #remove dots
    $title =~ s/\(|\)//g;    #remove ()
    $title =~ s/^L\'//g;     #remove L' in the beginning
    $title =~ s/\'//g;       #replace ' 
    $title =~s/\// /g;		#replace / with whitespace
    $title =~ s/\+//g;	#replace + 

	#check if title has subtitle that needs to be eliminated: (2 or 3 whitespaces)
    if ( $title =~ /$TITLE_SPLIT/ ) {
        @titles       = ( split /$TITLE_SPLIT/, $title );
        $subtitle     = $titles[1];
        $title        = $titles[0];
        $HAS_SUBTITLE = 1;
    }
    elsif ( $title =~ /\:/ )
    {    #check if title has subtitle that needs to be eliminated: (':')
        @titles       = ( split /\:/, $title );
        $subtitle     = $titles[1];
        $title        = $titles[0];
        $title        = trim($title);
        $subtitle     = trim($subtitle);
        $HAS_SUBTITLE = 1;
    }

	#check if title has volume information that needs to be removed: (usually: ... - Bd. ...)
    if ( $title =~
        /-\sBd|-\sVol|-\sReg|-\sGen|-\sTeil|-\s\d{1}\.\sTeil|-\sI{1,3}\.\sTeil/
      )
    {
        $volume = ( split / - /, $title, 2 )[1];
        $title  = ( split / - /, $title, 2 )[0];
        $HAS_VOLUME = 1;
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

    $shorttitle = substr $title, 0, 10;    

    print $fh_report "Titel: "      . $title      . " --- Untertitel: "      . $subtitle      . " --- Titeldatum: "
      . $titledate      . " --- Band: "      . $volume . "\n";

    #############################################
    # Deal with YEAR, PLACE, PUBLISHER
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

    if ( $pages =~ /$EMPTY_CELL/ || $pages =~ /$HYPHEN_ONLY/ ) {
        $HAS_PAGES = 0;
        $pages     = '';
    }
    elsif ( $pages =~ /\AS.\s/ || $pages =~ /\-/ )
    { #very likely not a monography but a volume or article, eg. S. 300ff or 134-567
        $HAS_PAGERANGE = 1;
    }

    if (   $place =~ /$EMPTY_CELL/
        || $place =~ /$HYPHEN_ONLY/
        || $place =~ /0/ )
    {
        $HAS_PLACE = 0;
        $place     = '';
    }

    #check if place has words that needs to be removed: (usually: D.C., a.M.)
    #TODO: remove everything after / or ,
    if ( $place =~ m/d\.c\.|a\.m\.|a\/m/i ) {
        $place = substr $place, 0, -5;

        #debug			print $place."\n";
    }

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
    $publisher =~ s/Verlag|Verl\.|Druck|publisher|publishers//g;
    
    ##########################
    # Deal with Material type
    ##########################
    
    if ($subj1 =~ /Zeitschrift/) {
        #TODO:  Treat manually, read next line
        $journal_nr++;
        $NO_MONOGRAPH = 'abcdis';
        push @journals, "\n", $journal_nr, $isbn, $title,$author, $year;        
    }
    
    if ($material !~ /Druckerzeugnis/) {
        #TODO: Treat separately, read next line
        $no_monograph_nr++;
        $NO_MONOGRAPH = 'abcdis';
        push @no_monograph, "\n", $no_monograph_nr, $isbn, $title,$author, $year;
    }
    
    if ($addendum =~ m/in: /i) {
        #TODO: Treat separately, read next line
        $no_monograph_nr++;
        $NO_MONOGRAPH = 'abcdis';
        push @no_monograph, "\n", $no_monograph_nr, $isbn, $title,$author, $year;        
    }


    if ( $HAS_PAGERANGE || $HAS_VOLUME || $HAS_TITLEDATE )
    {   #TODO: Treat separately, read next line
        $no_monograph_nr++;
        $NO_MONOGRAPH = 'abcdis';
        push @no_monograph, "\n", $no_monograph_nr, $isbn, $title,$author, $year; 
    }

    print $fh_report "Ort: "      . $place      . " - Verlag: "      . $publisher      . " - Jahr: "      
    . $year      . " - Materialart: "      . $NO_MONOGRAPH . "\n";
    if (defined $addendum ) {print $fh_report "Addendum: ".$addendum."\n";}

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
        $sruquery .= "+AND" . $yearquery . $year;
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
            print $fh_report "Diese Suche taugt nichts.\n". 
            "ooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooooo\n\n";
            #TODO handle manually
            $notfound_nr++;
            push @notfound, "\n", $notfound_nr, $isbn, $title,$author, $year;
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
            print $fh_report
			"Treffermenge zu hoch!!! Keine gute Suche moeglich (Verlag/Ort nicht vorh.).\n"
            . "OOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOO\n\n";

            # TODO: make a new query with other parameters, if still over 10:
            $notfound_nr++;
            push @notfound, "\n", $notfound_nr, $isbn, $title,$author, $year;
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
            print $fh_report
              "Treffermenge immer noch zu hoch oder Null!!! Trotz erweiterter Suche!\n".
              "OOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOOO\n\n";
            # TODO: make a new query with other parameters, if still over 10:
            $notfound_nr++;
            push @notfound, "\n", $notfound_nr, $isbn, $title,$author, $year;
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
            $AUTHORMATCH = $TITLEMATCH = $YEARMATCH = $PUBLISHERMATCH = $PLACEMATCH = $MATERIALMATCH = 0;
    		$IDSSGMATCH = $IFFMATCH = $TOTALMATCH = $IDSMATCH = $REROMATCH = 0;

            ############################################
            # CHECK ISBN MATCH
            ############################################   
            
            if ($HAS_ISBN) {
            	if ( $xpc->exists( './datafield[@tag="020"]', $rec ) ) {
                	foreach $el ( $xpc->findnodes( './datafield[@tag=020]', $rec ) )
                	{
					$ISBNMATCH = getMatchValue("a",$xpc,$el,$isbn,10);

                    # debug:
                    print $fh_report "ISBNMATCH: " . $ISBNMATCH . "\n";
                	}
            	}  
            } 
            
                  
            ############################################
            # CHECK AUTHORS & AUTHORITIES MATCH
            ############################################

            if ($HAS_AUTHOR) {
                if ( hasTag( "100", $xpc, $rec ) ) {     
                    foreach $el ( $xpc->findnodes( './datafield[@tag=100]', $rec ) )
                    {
                        $MARC100a =  $xpc->findnodes( './subfield[@code="a"]', $el )->to_literal;

                        # debug:
                        print $fh_report "Feld 100a: " . $MARC100a . "\n";

                        if ( $author =~ m/$MARC100a/i )
                        { 
                            $AUTHORMATCH = 10;
                        }    
                             # debug:
                        print $fh_report "AUTHORMATCH: ". $AUTHORMATCH . "\n";
                    }

                }
                if (hasTag( "700", $xpc, $rec ) ) {
                    foreach $el ( $xpc->findnodes( './datafield[@tag=700]', $rec ) )
                    {
                        $MARC700a =
                          $xpc->findnodes( './subfield[@code="a"]', $el )
                          ->to_literal;

                        # debug:
                        print $fh_report "Feld 700a: " . $MARC700a . "\n";

                        if ( $MARC700a =~ m/$author/i || $MARC700a =~ m/$author2/i)
                        { 
                            $AUTHORMATCH += 10; # add 10 points
                        }   
                             # debug:
                        print $fh_report "AUTHORMATCH: "
                          . $AUTHORMATCH . "\n";
                    }   
                }
                if (hasTag("110", $xpc, $rec)) {
                    foreach $el ( $xpc->findnodes( './datafield[@tag=110]', $rec ) )
                    {
                        $MARC110a =
                          $xpc->findnodes( './subfield[@code="a"]', $el )
                          ->to_literal;

                        # debug:
                        print $fh_report "Feld 110a: " . $MARC110a . "\n";

                        if ( $author =~ m/$MARC110a/i )
                        { 
                            $AUTHORMATCH += 10;
                        }   
                             # debug:
                        print $fh_report "AUTHORMATCH: "  . $AUTHORMATCH . "\n";
                    }
                }
                if (hasTag("710", $xpc, $rec)) {
                    foreach $el ( $xpc->findnodes( './datafield[@tag=710]', $rec ) )
                    {
                        $MARC710a =
                          $xpc->findnodes( './subfield[@code="a"]', $el )
                          ->to_literal;

                        # debug:
                        print $fh_report "Feld 710a: " . $MARC710a . "\n";

                        if ( $author =~ m/$MARC710a/i )
                        { 
                            $AUTHORMATCH += 10;
                        }   
                             # debug:
                        print $fh_report "AUTHORMATCH: "  . $AUTHORMATCH . "\n";
                    }
                }
            }

            ############################################
            # CHECK TITLE MATCH
            ############################################

            # TODO subtitle, title addons, etc., other marc fields (245b, 246b)
            
            if (hasTag("245",$xpc,$rec)){
                foreach $el ($xpc->findnodes('./datafield[@tag=245]', $rec)) {
                    $TITLEMATCH = getMatchValue("a",$xpc,$el,$title,10);
                    print $fh_report "TITLEMATCH mit getMatchValue: " . $TITLEMATCH . "\n";
                    
                }
            } 
            if (hasTag("246",$xpc,$rec)) {
                foreach $el ($xpc->findnodes('./datafield[@tag=246]', $rec)) {
                    $TITLEMATCH = getMatchValue("a",$xpc,$el,$title,5);
                    print $fh_report "TITLEMATCH mit getMatchValue: " . $TITLEMATCH . "\n";
                }
            } 
            
            # OLD TITLE CHECK:
            
            if ( $xpc->exists( './datafield[@tag="245"]', $rec ) ) {
                foreach $el ( $xpc->findnodes( './datafield[@tag=245]', $rec ) )
                {
                    $MARC245a =
                      $xpc->findnodes( './subfield[@code="a"]', $el )
                      ->to_literal;

                    # debug:
                    print $fh_report "Feld 245a: " . $MARC245a . "\n";

                    #print $fh_report "Titel: ".$title. "\n";

                    if ( $MARC245a =~ m/$title/i )
                    { #kommt Titel in 245a vor? (ohne Gross-/Kleinschreibung zu beachten)
                        $TITLEMATCH = 10;
                    }
                    elsif ( ( substr $MARC245a, 0, 10 ) =~
                        m/$shorttitle/i )
                    {    #TODO: Kurztitellänge anpassen? Hier: 10 Zeichen.
                        $TITLEMATCH = 5;
                    }

                    # debug:
                    print $fh_report "TITLEMATCH: " . $TITLEMATCH . "\n";
                }
            }
            ## Year: Feld 008: pos. 07-10 - Date 1

            if (   $HAS_YEAR
                && $xpc->exists( './controlfield[@tag="008"]', $rec ) )
            {
                foreach $el (
                    $xpc->findnodes( './controlfield[@tag=008]', $rec ) )
                {
                    $MARC008 = $el->to_literal;
                    $MARC008 = substr $MARC008, 7, 4;

                    # debug:
                    print $fh_report "Feld 008: " . $MARC008 . "\n";

                    if ( $MARC008 eq $year ) {
                        $YEARMATCH = 10;
                    }

                    # debug:
                    print $fh_report "YEARMATCH: " . $YEARMATCH . "\n";
                }
            }
            
            # Place new:
            
            if ($HAS_PLACE) {
                if (hasTag("264", $xpc, $rec) || hasTag("260", $xpc, $rec)) {
                    foreach $el ( $xpc->findnodes( './datafield[@tag=264 or @tag=260]', $rec ) ) {
                        $PLACEMATCH = getMatchValue("a",$xpc,$el,$place,5);
                        print $fh_report "PlaceMatch with getMatchValue: " . $PLACEMATCH . "\n";
                    }
                }
            }

            # PLACE old:

            if (   $HAS_PLACE
                && $xpc->exists( './datafield[@tag="264"]', $rec ) )
            {    #264

                foreach $el ( $xpc->findnodes( './datafield[@tag=264]', $rec ) )
                {
                    $MARC264a =
                      $xpc->findnodes( './subfield[@code="a"]', $el )
                      ->to_literal;

                    # debug:
                    print $fh_report "Feld 264a: " . $MARC264a . "\n";

                    #print $fh_report "Ort: ".$place."\n";
                    if ( $MARC264a =~ m/$place/i ) {
                        $PLACEMATCH = 5;
                    }    #else { $PLACEMATCH = 0; }
                         # debug:
                    print $fh_report "P-Match: " . $PLACEMATCH . "\n";
                }

            }
            elsif ($HAS_PLACE
                && $xpc->exists( './datafield[@tag="260"]', $rec ) )
            {            # 260

                foreach $el ( $xpc->findnodes( './datafield[@tag=260]', $rec ) )
                {
                    $MARC260a =
                      $xpc->findnodes( './subfield[@code="a"]', $el )
                      ->to_literal;

                    # debug:
                    print $fh_report "Feld 260a: " . $MARC260a . "\n";

                    #print $fh_report "Ort: ".$place."\n";
                    if ( $MARC260a =~ m/$place/i ) {
                        $PLACEMATCH = 5;
                    }    #else { $PLACEMATCH = 0; }
                         # debug:
                    print $fh_report "PLACEMATCH: " . $PLACEMATCH . "\n";
                }
            }
            
            #Publisher new:
            
            if ($HAS_PUBLISHER) {
                if (hasTag("264", $xpc, $rec) || hasTag("260", $xpc, $rec)) {
                    foreach $el ( $xpc->findnodes( './datafield[@tag=264 or @tag=260]', $rec ) ) {
                        $PUBLISHERMATCH = getMatchValue("b",$xpc,$el,$publisher,5);
                        print $fh_report "Publisher-Match with getMatchValue: " . $PUBLISHERMATCH . "\n";
                    }
                }
            }

            # PUBLISHER OLD: TODO: nur das 1. Wort vergleichen oder alles nach / abschneiden.

            if (   $HAS_PUBLISHER
                && $xpc->exists( './datafield[@tag="264"]', $rec ) )
            {            #264

                foreach $el ( $xpc->findnodes( './datafield[@tag=264]', $rec ) )
                {
                    $MARC264b =
                      $xpc->findnodes( './subfield[@code="b"]', $el )
                      ->to_literal;

                    # debug:
                    print $fh_report "Feld 264b: " . $MARC264b . "\n";

                    #print $fh_report "Verlag: ".$publisher."\n";
                    if ( $MARC264b =~ m/$publisher/i ) {
                        $PUBLISHERMATCH = 5;
                    }    #else { $PUBLISHERMATCH = 0; }
                         # debug:
                    print $fh_report "PUBLISHERMATCH: "
                      . $PUBLISHERMATCH . "\n";
                }

            }
            elsif ($HAS_PUBLISHER
                && $xpc->exists( './datafield[@tag="260"]', $rec ) )
            {            # 260
                foreach $el ( $xpc->findnodes( './datafield[@tag=260]', $rec ) )
                {
                    $MARC260b =
                      $xpc->findnodes( './subfield[@code="b"]', $el )
                      ->to_literal;

                    # debug:
                    print $fh_report "Feld 260b: " . $MARC260b . "\n";

                    #print $fh_report "Verlag: ".$publisher."\n";
                    if ( $MARC260b =~ m/$publisher/i ) {
                        $PUBLISHERMATCH = 5;
                    }    #else { $PUBLISHERMATCH = 0; }
                         # debug:
                    print $fh_report "PUBLISHERMATCH: "
                      . $PUBLISHERMATCH . "\n";
                }
            }

            #MATERIAL: LDR-Werte
            if ( $xpc->exists( './leader', $rec ) ) {
                foreach $el ( $xpc->findnodes( './leader', $rec ) ) {
                    $LDR = $el->to_literal;
                    $LDR = substr $LDR, 7, 1;

                    # debug:
                    print $fh_report "LDR Materialart: " . $LDR . "\n";

                    if ( $NO_MONOGRAPH =~ m/$LDR/ ) {
                        $MATERIALMATCH = 15;
                    }

                    # debug:
                    print $fh_report "MATERIALMATCH: "
                      . $MATERIALMATCH . "\n";
                }
            }

            #Get Swissbib System Nr., Field 001: 
            #http://www.swissbib.org/wiki/index.php?title=Swissbib_marc

            if ( $xpc->exists( './controlfield[@tag="001"]', $rec ) ) {
                foreach $el (
                    $xpc->findnodes( './controlfield[@tag=001]', $rec ) )
                {
                    $MARC001 = $el->to_literal;

                    # debug:
                    print $fh_report "Swissbibnr.: " . $MARC001 . "\n";

                }
            }

            #Get 035 Field and check if old IFF data.
            if ( $xpc->exists( './datafield[@tag="035"]', $rec ) ) {
                foreach $el (
                    $xpc->findnodes( './datafield[@tag=035 ]', $rec ) )
                {
                    $MARC035a =
                      $xpc->findnodes( './subfield[@code="a"]', $el )
                      ->to_literal;
                    print $fh_report "Feld 035a: " . $MARC035a . "\n"
                      unless ( $MARC035a =~ /OCoLC/ );

                    if ( $MARC035a =~ /IDSSG/ ) {    # book found in IDSSG
                        $bibnr = substr $MARC035a,
                          -7;    #only the last 7 numbers
                        if ( $bibnr > 990000 ) {   #this is an IFF record
                            $IFFMATCH = 15;        # negative points
                            $iff2replace = $MARC001;
                            print $fh_report "Abzug fuer IFF_MATCH: -"
                              . $IFFMATCH . "\n";
                        }
                        else {
                            $IDSSGMATCH = 21;    # a lot of plus points!
                            print $fh_report
                              "Zuschlag fuer altes HSG-Katalogisat: "
                              . $IDSSGMATCH . "\n";
                            if ( $xpc->exists( './datafield[@tag="949"]', $rec )
                              )
                            {
                                foreach $el (
                                    $xpc->findnodes(
                                        './datafield[@tag=949 ]', $rec
                                    )
                                  )
                                {
                                    $MARC949F =
                                      $xpc->findnodes( './subfield[@code="F"]',
                                        $el )->to_literal;
                                    if ( $MARC949F =~ /HIFF/ ) {
                                        print $fh_report "Feld 949: "
                                          . $MARC949F . "\n";
                                        $IDSSGMATCH += 10;
                                        print $fh_report
                                          "HIFF already attached, IDSSGMATCH = "
                                          . $IDSSGMATCH . "\n";
                                        $iff2replace = $MARC001;
                                        $bestcase    = 1;
                                    }

                                }

                            }
                        }

                    }
                    else {
                        if ( $MARC035a =~ m/RERO/ )
                        {    #book from RERO slightly preferred to others
                            $IDSMATCH = 4;
                            print $fh_report "REROMATCH: "
                              . $IDSMATCH . "\n";
                        }
                        if ( $MARC035a =~ m/SGBN/ )
                        { #book from SGBN  slight preference over others if not IDS

                            $IDSMATCH = 6;
                            print $fh_report "SGBNMATCH: "
                              . $IDSMATCH . "\n";
                        }
                        if (   $MARC035a =~ m/IDS/
                            || $MARC035a =~ /NEBIS/ )
                        {    #book from IDS Library preferred

                            $IDSMATCH = 9;
                            print $fh_report "IDSMATCH: "
                              . $IDSMATCH . "\n";
                        }

                    }
                }
            }

            $i++;
            $TOTALMATCH =
              ( $TITLEMATCH +
                  $AUTHORMATCH +
                  $YEARMATCH +
                  $PUBLISHERMATCH +
                  $PLACEMATCH +
                  $MATERIALMATCH +
                  $IDSMATCH +
                  $IDSSGMATCH -
                  $IFFMATCH );

            print $fh_report "Totalmatch: " . $TOTALMATCH . "\n";

            if ( $TOTALMATCH > $bestmatch )
            { #ist aktueller Match-Total der höchste aus Trefferliste? wenn ja:
                $bestmatch  = $TOTALMATCH; # schreibe in bestmatch
                $bestrecord = $rec;               # speichere record weg.
                $bestrecordnr =
                  $MARC001;    # Swissbib-Nr. des records
            }

        }

		# TODO: if correct, write out as marcxml, if false, do another query with more parameters
        $found_nr++;

        print $fh_report "Bestmatch: "
          . $bestmatch
          . ", Bestrecordnr: "
          . $bestrecordnr . "\n";

        if ( $bestmatch >= 25 ) {    #wenn guter Treffer gefunden

            if ( $iff2replace eq $bestrecordnr ) {
                if ($bestcase) {
                	$bestcase_nr++;
                    print $fh_report
                      "Best case scenario: IFF and HSG already matched!\n";
                      
                }
                else {
                	$iff_only_nr++;
                    print $fh_report
                      "Only IFF data available. Best solution from Felix.\n";
                }
            }
            else {
                $replace_nr++;
                if ( $iff2replace !~ /$EMPTY_CELL/ ) {
                    print $fh_report "Ersetzen: alt "
                      . $iff2replace
                      . " mit neu "
                      . $bestrecordnr . "\n";
                }
                else {
                	$replace_m_nr++;
                    print $fh_report
"Ersetzen. FEHLER: IFF_Kata nicht gefunden. Manuell suchen und ersetzen mit "
                      . $bestrecordnr . "\n";
                }

                #IFF-Signatur anhängen
                $bestrecord->appendWellBalancedChunk(
'<datafield tag="949" ind1=" " ind2=" "><subfield code="B">IDSSG</subfield><subfield code="F">HIFF</subfield><subfield code="c">BIB</subfield><subfield code="j">'
                      . $callno
                      . '</subfield></datafield>' );

                #TODO: Schlagworte IFF einfügen
                #TODO: unnötige Exemplardaten etc. rauslöschen.
                print $fh_export $bestrecord->toString . "\n";
            }

        }
        else {
        	$unsure_nr++;
            print $fh_report "BESTMATCH ziemlich tief, überprüfen!";
            push @unsure, "\n", $unsure_nr, $isbn, $title,
              $author, $year;
        }
    }
}

$csv->eof or $csv->error_diag();
close $fh_in;

$csv->print( $fh_notfound, \@notfound );
$csv->print( $fh_unsure,   \@unsure );
$csv->print($fh_journals, \@journals);
$csv->print($fh_no_monograph, \@no_monograph); # not working for some reason (value undefined))

close $fh_notfound or die "notfound.csv: $!";
close $fh_unsure   or die "unsure.csv: $!";
close $fh_journals or die "journals.csv: $!";
close $fh_no_monograph or die "no_monograph.csv: $!";
close $fh_report   or die "report.txt: $!";
close $fh_export   or die "swissbibexport.xml: $!";

print "Total found: " . $found_nr . "\n";
print "Total to replace: " . $replace_nr . "\n";
print "Total to replace where IFF-record not found: ".$replace_m_nr."\n";
print "Total already matched: " . $bestcase_nr. "\n";
print "Total that cannot be improved: ".$iff_only_nr."\n";

print "Total unsure: " . $unsure_nr . "\n";
print "Total journals: " . $journal_nr. "\n";
print "Total not monographs: " . $no_monograph_nr. "\n";
print "Total not found: " . $notfound_nr . "\n";

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
    $NO_MONOGRAPH  = 'm';
    $iff2replace   = "";
    $bestcase      = 0;
    $bestmatch = 0; 


}



# empty Variables

sub emptyVariables {

    $isbn = '';     $isbn2 = '';     $isbnlength = '';
    $author = '';     $author2 = '';     $author_size = '';
    $title = '';     $subtitle = '';     $volume = '';     $titledate = '';
    $pages= ''; 
    $material= '';
    $addendum= '';
    $location= '';
    $callno= '';
    $place= '';
    $publisher= '';
    $year= '';
    $note= '';
    $tsignature= ''; $tsignature_1= ''; $tsignature_2 = ''; $subj1= ''; $subj2= ''; $subj3= '';

}

sub hasTag {
    my $tag = $_[0];    # Marc tag
    my $xpc = $_[1];    # xpc path
    my $rec = $_[2];    # record path
    if ( $xpc->exists( './datafield[@tag=' . $tag . ']', $rec ) ) {
        #debug
        print $fh_report "hasTag(".$tag.")\n";
        return 1;
    }
    else {
        return 0;
    }

}

sub getMatchValue {
    my $code   = $_[0];    #subfield
    my $xpc   = $_[1];     #xpc
    my $el = $_[2];    #el
    my $vari  = $_[3];    #orignal data from csv
    my $posmatch = $_[4];    #which match value shoud be assigned to positive match?
    my $matchvalue;
    my $marcfield;
    my $shortvari = substr $vari, 0,10;
    
    
    $marcfield = $xpc->findnodes( './subfield[@code=' . $code . ']', $el)->to_literal;
    #$marcfield = $xpc->findvalue( './subfield[@code=' . $code . ']', $el);

    # debug: this does not work, why???
    print $fh_report "marcfield: " . $marcfield . "\n";
    #my $length = length ($marcfield);
    #my $halflength = ceil($length/2);
    my $marcshort = substr $marcfield, 0,10;
	
    if ( ($vari =~ m/$marcfield/i ) || ($marcfield =~m/$vari/i)){ #Marc Data matches CSV Data
        #debug: 
        print $fh_report "marcfield full match! \n";
        $matchvalue = $posmatch;
    } elsif (($shortvari =~ m/$marcshort/i ) || ($marcshort =~m/$shortvari/i)) { #First 10 characters match
        #debug: this never works, why?
        print $fh_report "marcfield short match! \n";
        $matchvalue = abs($posmatch/2);
    } else {$matchvalue = 0;}
    
    return $matchvalue;
	
}