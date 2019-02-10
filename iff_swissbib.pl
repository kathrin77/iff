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

use Vari;
use Flag;
use Marc;
use Match;

##########################################################
#
#	DECLARE NECESSARY VARIABLES
#
##########################################################

my $row;
my $rowcounter = 0;
my @notfound;
my @unsure;
my @journals;
my @no_monograph;
my $found_nr    = 0;
my $notfound_nr = 0;
my $replace_nr  = 0;
my $unsure_nr   = 0;
my $journal_nr = 0;
my $no_monograph_nr = 0;

# regex:
my $HYPHEN_ONLY = qr/\A\-/;       # a '-' in the beginning
my $EMPTY_CELL  = qr/\A\Z/;       #nothing in the cell
my $TITLE_SPLIT = qr/\s{2,3}/;    #min 2, max 3 whitespaces

# testfiles
my $test30  = "data/test30.csv";     # 30 Dokumente
my $test200 = "data/test200.csv";    # 200 Dokumente

# input, output, filehandles:
my $csv;
my $fh_in;

#my $fh_found;
my $fh_notfound;
my $fh_unsure;
my $fh_report;
my $fh_export;
my $fh_journals;
my $fh_other;

# Swissbib SRU-Service for the complete content of Swissbib:
my $swissbib  = 'http://sru.swissbib.ch/sru/search/defaultdb?';
my $operation = '&operation=searchRetrieve';
my $schema    = '&recordSchema=info%3Asrw%2Fschema%2F1%2Fmarcxml-v1.1-light'
  ;    # MARC XML - swissbib (less namespaces)
my $max   = '&maximumRecords=10';    # swissbib default is 10 records
my $query = '&query=';

my $server_endpoint = $swissbib . $operation . $schema . $max . $query;

# needed queries
my $isbnquery   = '+dc.identifier+%3D+';
my $titlequery  = '+dc.title+%3D+';
my $yearquery   = '+dc.date+%3D+';
my $anyquery    = '+dc.anywhere+%3D+';

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
# Data: IFF_Katalog_FULL.csv contains all data, has been treated (removed \r etc.)
##########################################################

# open input/output:
$csv =
  Text::CSV->new( { binary => 1, sep_char => ";" } )    # CSV-Char-Separator = ;
  or die "Cannot use CSV: " . Text::CSV->error_diag();

open $fh_in, "<:encoding(utf8)", $test30 or die "$test30: $!";

#open $fh_in, "<:encoding(utf8)", $test200 or die "$test200: $!";
open $fh_notfound, ">:encoding(utf8)", "notfound.csv" or die "notfound.csv: $!";
open $fh_unsure,   ">:encoding(utf8)", "unsure.csv"   or die "unsure.csv: $!";
open $fh_journals, ">:encoding(utf8)", "journals.csv"   or die "journals.csv: $!";
open $fh_other, ">:encoding(utf8)", "other.csv"   or die "other.csv: $!";
open $fh_report,   ">:encoding(utf8)", "report.txt"   or die "report.txt: $!";
open $fh_export, ">:encoding(utf8)", "swissbibexport.xml"
  or die "swissbibexport.xml: $!";

# read each line and do...:
while ( $row = $csv->getline($fh_in) ) {

    #get all necessary variables
    $Vari::author   = $row->[0];
    $Vari::title    = $row->[1];
    $Vari::isbn     = $row->[2];
    $Vari::pages    = $row->[3];
    $Vari::material = $row->[4];

    #$Vari::created = $row->[5];
    $Vari::addendum = $row->[6];

    #$Vari::location = $row->[7];
    $Vari::callno    = $row->[8];
    $Vari::place     = $row->[9];
    $Vari::publisher = $row->[10];
    $Vari::year      = $row->[11];

    #$Vari::note = $row->[12];
    #$Vari::tsignature = $row->[13];
    #$Vari::tsignature_1 = $row->[14];
    #$Vari::tsignature_2 = $row->[15];
    $Vari::subj1 = $row->[16];
    #$Vari::subj2 = $row->[17];
    #$Vari::subj3 = $row->[18];

    #reset all flags and counters:
    resetFlags();
    emptyVariables();
    $rowcounter++;
    print $fh_report "\nNEW ROW: #"
      . $rowcounter
      . "\n*********************************************************************************\n";
    $Match::bestmatch = 0;
    
    
    ##########################
    # Deal with ISBN:
    ##########################

    # 	remove all but numbers and X
    $Vari::isbn =~ s/[^0-9xX]//g;
    $Vari::isbnlength = length($Vari::isbn);

    if ( $Vari::isbnlength == 26 ) {    #there are two ISBN-13
        $Vari::isbn2 = substr $Vari::isbn, 13;
        $Vari::isbn  = substr $Vari::isbn, 0, 13;
        $Flag::HAS_ISBN2 = 1;
    }
    elsif ( $Vari::isbnlength == 20 ) {    #there are two ISBN-10
        $Vari::isbn2 = substr $Vari::isbn, 10;
        $Vari::isbn  = substr $Vari::isbn, 0, 10;
        $Flag::HAS_ISBN2 = 1;
    }
    elsif ( $Vari::isbnlength == 13 || $Vari::isbnlength == 10 )
    {                                      #one valid ISBN
        $Flag::HAS_ISBN = 1;
    }
    else {                                 #not a valid ISBN
        $Flag::HAS_ISBN = 0;
    }

    if ($Flag::HAS_ISBN) {
        print $fh_report "ISBN: " . $Vari::isbn . "\n";
    }

    if ($Flag::HAS_ISBN2) {
        print $fh_report "ISBN-2: " . $Vari::isbn2 . "\n";
    }

    #############################
    # Deal with AUTHOR/AUTORITIES
    #############################

    $Vari::author = trim($Vari::author);
    $Vari::author =~ s/\.//g;       #remove dots
    $Vari::author =~ s/\(|\)//g;    #remove ()

    #check if empty author or if author = NN or the like:
    if (   $Vari::author =~ /$EMPTY_CELL/
        || $Vari::author =~ /$HYPHEN_ONLY/
        || $Vari::author =~ /\ANN/
        || $Vari::author =~ /\AN\.N\./
        || $Vari::author =~ /\AN\.\sN\./ )
    {
        $Flag::HAS_AUTHOR = 0;
        $Vari::author     = '';
    }
    else {
        $Flag::HAS_AUTHOR = 1;
    }

    #TODO: Schweiz. ausschreiben? aber wie?

    #check if several authors: contains "/"?
    if ( $Flag::HAS_AUTHOR && $Vari::author =~ /[\/]/ ) {
        @Vari::authors     = split( '/', $Vari::author );
        $Vari::author      = $Vari::authors[0];
        $Vari::author2     = $Vari::authors[1];
        $Flag::HAS_AUTHOR2 = 1;
    }
    else {
        $Vari::author2 = '';
    }

    #check if authority rather than author:
    if ($Flag::HAS_AUTHOR) {

        if ( $Vari::author =~ /amt|Amt|kanzlei|Schweiz\.|institut|OECD/ )
        {    #probably an authority # TODO maybe more!
            $Flag::HAS_AUTHORITY = 1;
            $Vari::author_size   = 5;

#debug: 			print "Authority1: ". $HAS_AUTHORITY." authorsize1: ".$author_size."\n";
        }
        else {
            @Vari::authority   = split( ' ', $Vari::author );
            $Vari::author_size = scalar @Vari::authority;

            #debug:			print "Authorsize2: ". $author_size."\n";
        }

        if ( $Vari::author_size > 3 ) {    #probably an authority
            $Flag::HAS_AUTHORITY = 1;

#debug: 			print "Authority2: ". $HAS_AUTHORITY." authorsize2: ".$author_size."\n";
        }
        else {                             #probably a person
                                           # trim author's last name:
            if ( $Vari::author =~ /\Avon|\AVon|\Ade|\ADe|\ALe\s/ )
            {                              #TODO maybe more
                $Vari::author = ( split /\s/, $Vari::author, 3 )[1];

                #debug				print "Author: ".$author."\n";
            }
            else {
                $Vari::author = ( split /\s/, $Vari::author, 2 )[0];

                #debug				print "Author: ".$author."\n";
            }
            if ($Flag::HAS_AUTHOR2) {
                if ( $Vari::author2 =~ /\Avon|\AVon|\Ade|\ADe|\ALe\s/ )
                {                          #TODO maybe more
                    $Vari::author2 = ( split /\s/, $Vari::author2, 3 )[1];

                    #debug					print "Author2: ".$author2."\n";
                }
                else {
                    $Vari::author2 = ( split /\s/, $Vari::author2, 2 )[0];

                    #debug					print "Author2: ".$author2."\n";
                }
            }
        }
    }

    #Ausgabe in report:
    print $fh_report "Autor: "
      . $Vari::author
      . " --- Autor2: "
      . $Vari::author2 . "\n";

    ##########################
    # Deal with TITLE:
    ##########################

    $Vari::title = trim($Vari::title);

    #TODO: '+' im Titel ersetzen, aber womit?

    $Vari::title =~ s/\.//g;       #remove dots
    $Vari::title =~ s/\(|\)//g;    #remove ()
    $Vari::title =~ s/^L\'//g;     #remove L' in the beginning
    $Vari::title =~ s/\'//g;       #remove '

#check if title has subtitle that needs to be eliminated: (2 or 3 whitespaces) #TODO depends on how carriage returns are removed! works for now.
    if ( $Vari::title =~ /$TITLE_SPLIT/ ) {
        @Vari::titles       = ( split /$TITLE_SPLIT/, $Vari::title );
        $Vari::subtitle     = $Vari::titles[1];
        $Vari::title        = $Vari::titles[0];
        $Flag::HAS_SUBTITLE = 1;
    }
    elsif ( $Vari::title =~ /\:/ )
    {    #check if title has subtitle that needs to be eliminated: (':')
        @Vari::titles       = ( split /\:/, $Vari::title );
        $Vari::subtitle     = $Vari::titles[1];
        $Vari::title        = $Vari::titles[0];
        $Vari::title        = trim($Vari::title);
        $Vari::subtitle     = trim($Vari::subtitle);
        $Flag::HAS_SUBTITLE = 1;
    }
    else { $Vari::subtitle = ''; }

#check if title has volume information that needs to be removed: (usually: ... - Bd. ...)
    if ( $Vari::title =~
        /-\sBd|-\sVol|-\sReg|-\sGen|-\sTeil|-\s\d{1}\.\sTeil|-\sI{1,3}\.\sTeil/
      )
    {
        $Vari::volume = ( split / - /, $Vari::title, 2 )[1];
        $Vari::title  = ( split / - /, $Vari::title, 2 )[0];
        $Flag::HAS_VOLUME = 1;
    }
    else { $Vari::volume = ''; }

    #check if the title contains years or other dates and remove them:
    if ( $Vari::title =~ /-\s\d{1,4}/ ) {
        $Vari::titledate = ( split / - /, $Vari::title, 2 )[1];
        $Vari::title     = ( split / - /, $Vari::title, 2 )[0];
        $Flag::HAS_TITLEDATE = 1;
    }
    else { $Vari::titledate = ''; }

    if ( $Vari::title =~ /\s\d{1,4}\Z/ ) {    # Das Lohnsteuerrecht 1972
        $Vari::titledate     = substr $Vari::title, -4;
        $Vari::title         = ( split /\s\d{1,4}/, $Vari::title, 2 )[0];
        $Flag::HAS_TITLEDATE = 1;
    }
    elsif ( $Vari::title =~ /\s\d{4}\/\d{2}\Z/ )
    {                                         #Steuerberater-Jahrbuch 1970/71
        $Vari::titledate     = substr $Vari::title, -7;
        $Vari::title         = ( split /\s\d{4}\/\d{2}/, $Vari::title, 2 )[0];
        $Flag::HAS_TITLEDATE = 1;
    }
    elsif ( $Vari::title =~ /\s\d{4}\/\d{4}\Z/ )
    {                                         #Steuerberater-Jahrbuch 1970/1971
        $Vari::titledate     = substr $Vari::title, -9;
        $Vari::title         = ( split /\s\d{4}\/\d{4}/, $Vari::title, 2 )[0];
        $Flag::HAS_TITLEDATE = 1;
    }
    elsif ( $Vari::title =~ /\s\d{4}\-\d{4}\Z/ )
    {    #Sammlung der Verwaltungsentscheide 1947-1950
        $Vari::titledate     = substr $Vari::title, -9;
        $Vari::title         = ( split /\s\d{4}\-\d{4}/, $Vari::title, 2 )[0];
        $Flag::HAS_TITLEDATE = 1;
    }
    else { $Vari::titledate = ''; }

    $Vari::shorttitle = substr $Vari::title, 0, 10;

    #print "Kurztitel: ".$Vari::shorttitle."\n";

    print $fh_report "Titel: "
      . $Vari::title
      . " --- Untertitel: "
      . $Vari::subtitle
      . " --- Titeldatum: "
      . $Vari::titledate
      . " --- Band: "
      . $Vari::volume . "\n";

    #############################################
    # Deal with YEAR, PLACE, PUBLISHER
    #############################################

    if (   $Vari::year =~ /$EMPTY_CELL/
        || $Vari::year =~ /$HYPHEN_ONLY/
        || $Vari::year =~ /online/ )
    {
        $Flag::HAS_YEAR = 0;
        $Vari::year     = '';
    }
    else {
        $Flag::HAS_YEAR = 1;
    }

    if ( $Vari::pages =~ /$EMPTY_CELL/ || $Vari::pages =~ /$HYPHEN_ONLY/ ) {
        $Flag::HAS_PAGES = 0;
        $Vari::pages     = '';
    }
    elsif ( $Vari::pages =~ /\AS.\s/ || $Vari::pages =~ /\-/ )
    { #very likely not a monography but a volume or article, eg. S. 300ff or 134-567
        $Flag::HAS_PAGERANGE = 1;
        $Flag::HAS_PAGES     = 1;
    }
    else {
        $Flag::HAS_PAGES = 1;
    }

    if (   $Vari::place =~ /$EMPTY_CELL/
        || $Vari::place =~ /$HYPHEN_ONLY/
        || $Vari::place =~ /0/ )
    {
        $Flag::HAS_PLACE = 0;
        $Vari::place     = '';
    }
    else {
        $Flag::HAS_PLACE = 1;
    }

    #check if place has words that needs to be removed: (usually: D.C., a.M.)
    #TODO: remove everything after / or ,
    if ( $Vari::place =~ m/d\.c\.|a\.m\.|a\/m/i ) {
        $Vari::place = substr $Vari::place, 0, -5;

        #debug			print $Vari::place."\n";
    }

    if (   $Vari::publisher =~ /$EMPTY_CELL/
        || $Vari::publisher =~ /$HYPHEN_ONLY/ )
    {
        $Flag::HAS_PUBLISHER = 0;
        $Vari::publisher     = '';
    }
    else {
        $Flag::HAS_PUBLISHER = 1;
    }

#check if publisher has words that needs to be removed: (usually: Der die das The le la)
# TODO: Remove "Verlag" etc. from publishers name.
    if ( $Vari::publisher =~ m/der\s|die\s|das\s|the\s|le\s|la\s/i ) {
        $Vari::publisher = ( split /\s/, $Vari::publisher, 2 )[1];

        #debug		print $Vari::publisher."\n";
    }

    ##########################
    # Deal with Material type
    # TODO:
    # Entferne alle Zeilen, welche im Zusatz "in:" enthalten --> separate Datei: Fulldump-nur-in, knapp 1800 Zeilen (Analytica)
    # Entferne alle Zeilen, welche im Subj1 "Zeitschriften" enthalten --> separate Datei Fulldump-nur-zs-ohne-in, ca. 1550 Zeilen (Zeitschriften)
    ##########################
    
    if ($Vari::subj1 =~ /Zeitschrift/) {
        #TODO:  read next line
        $journal_nr++;
        push @journals, "\n", $journal_nr, $Vari::isbn, $Vari::title,
          $Vari::author, $Vari::year;
        
    }
    
    if ($Vari::material !~ /Druckerzeugnis/) {
        #TODO: Treat separately, read next line
        $no_monograph_nr++;
        push @no_monograph, "\n", $no_monograph_nr, $Vari::isbn, $Vari::title,
          $Vari::author, $Vari::year;
    }
    
    if ($Vari::addendum =~ m/in: /i) {
        #TODO: Treat separately, read next line
        #print "Analytica!\n";
        $no_monograph_nr++;
        push @no_monograph, "\n", $no_monograph_nr, $Vari::isbn, $Vari::title,
          $Vari::author, $Vari::year;
        
    }


    if ( $Flag::HAS_PAGERANGE || $Flag::HAS_VOLUME || $Flag::HAS_TITLEDATE )
    {    # ist ziemlich sicher keine Monographie
        $Flag::NO_MONOGRAPH = 'abcdis';    # possible LDR-pos (07)
    }

    print $fh_report "Ort: "
      . $Vari::place
      . " - Verlag: "
      . $Vari::publisher
      . " - Jahr: "
      . $Vari::year
      . " - Materialart: "
      . $Flag::NO_MONOGRAPH . "\n";

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

    $Vari::escaped_title  = uri_escape_utf8($Vari::title);
    $Vari::escaped_author = uri_escape_utf8($Vari::author);
    $sruquery =
        $server_endpoint
      . $titlequery
      . $Vari::escaped_title . "+AND"
      . $anyquery
      . $Vari::escaped_author;    # "any" query sucht auch in 245$c;

#note: all documents except journals have an "author" field in some kind, so it should never be empty.

    if ($Flag::HAS_YEAR) {

        $sruquery .= "+AND" . $yearquery . $Vari::year;

    }

    # Debug:
    print $fh_report "URL: " . $sruquery . "\n";

    # load xml as DOM object, # register namespaces of xml
    $dom = XML::LibXML->load_xml( location => $sruquery );
    $xpc = XML::LibXML::XPathContext->new($dom);

    # get nodes of records with XPATH
    @record = $xpc->findnodes(
        '/searchRetrieveResponse/records/record/recordData/record');

    $numberofrecords =
      $xpc->findvalue('/searchRetrieveResponse/numberOfRecords');

    #$numberofrecords = int($numberofrecords);

    # debug:
    print $fh_report "Treffer: " . $numberofrecords . "\n";

### debug output:
    if ( $numberofrecords == 0 ) {
        #repeat query without year or with isbn:
        $sruquery = "";
        if ($Flag::HAS_ISBN) {
            $sruquery = $server_endpoint . $isbnquery . $Vari::isbn;
        }
        else {
            $sruquery =
                $server_endpoint
              . $anyquery
              . $Vari::escaped_title . "+AND"
              . $anyquery
              . $Vari::escaped_author;
        }

        print $fh_report "URL geaendert, da 0 Treffer: " . $sruquery . "\n";

        #Suche wiederholen mit neuer query:
        # load xml as DOM object, # register namespaces of xml
        $dom = XML::LibXML->load_xml( location => $sruquery );
        $xpc = XML::LibXML::XPathContext->new($dom);

        # get nodes of records with XPATH
        @record = $xpc->findnodes(
            '/searchRetrieveResponse/records/record/recordData/record');

        $numberofrecords =
          $xpc->findvalue('/searchRetrieveResponse/numberOfRecords');

        if ( $numberofrecords > 0 && $numberofrecords <= 10 ) {
            print $fh_report "Treffer mit geaendertem Suchstring: "
              . $numberofrecords . "\n";
        }
        else {
            #debug
            print $fh_report "Diese Suche taugt auch nichts.\n";
            print $fh_report "OOOOOOOOOO\n\n";
        }

        # TODO: Fehlercode auswerten.
        # TODO: make a new query with other parameters, if still 0:
        push @notfound, "\n", $notfound_nr, $Vari::isbn, $Vari::title,
          $Vari::author, $Vari::year;
        $notfound_nr++;

    }
    if ( $numberofrecords > 10 ) {
        if ($Flag::HAS_PUBLISHER) {
            $sruquery .= "+AND" . $anyquery . $Vari::publisher;

        }
        elsif ($Flag::HAS_PLACE) {
            $sruquery .= "+AND" . $anyquery . $Vari::place;

        }
        else {
            #debug
            print $fh_report
"Treffermenge zu hoch!!! Keine gute Suche moeglich (Verlag/Ort nicht vorh.).\n";
            print $fh_report "OOOOOOOOOO\n\n";

            # TODO: Treffer auswerten.
            # TODO: make a new query with other parameters, if still over 10:
            push @notfound, "\n", $notfound_nr, $Vari::isbn, $Vari::title,
              $Vari::author, $Vari::year;
            $notfound_nr++;

        }
        print $fh_report "URL erweitert: " . $sruquery . "\n";

        #Suche wiederholen mit neuer query:
        # load xml as DOM object, # register namespaces of xml
        $dom = XML::LibXML->load_xml( location => $sruquery );
        $xpc = XML::LibXML::XPathContext->new($dom);

        # get nodes of records with XPATH
        @record = $xpc->findnodes(
            '/searchRetrieveResponse/records/record/recordData/record');

        $numberofrecords =
          $xpc->findvalue('/searchRetrieveResponse/numberOfRecords');

        if ( $numberofrecords <= 10 ) {
            print $fh_report "Treffer mit erweitertem Suchstring: "
              . $numberofrecords . "\n";
        }
        else {
            #debug
            print $fh_report
              "Treffermenge immer noch zu hoch!!! Trotz erweiterter Suche!\n";
            print $fh_report "OOOOOOOOOO\n\n";
        }

    }

    if ( $numberofrecords >= 1 && $numberofrecords <= 10 ) {

        # compare fields in record:
        $i = 1;
        foreach $rec (@record) {
            print $fh_report "\n#Document $i:\n";
            resetMatch();    # setze für jeden Record die MATCHES wieder auf 0.

            #TODO: check isbn
            
            #CHECK AUTHORS & AUTHORITIES:

            if ($Flag::HAS_AUTHOR) {
                if ( hasTag( "100", $xpc, $rec ) ) {     
                    foreach $el ( $xpc->findnodes( './datafield[@tag=100]', $rec ) )
                    {
                        $Marc::MARC100a =
                          $xpc->findnodes( './subfield[@code="a"]', $el )
                          ->to_literal;

                        # debug:
                        print $fh_report "Feld 100a: " . $Marc::MARC100a . "\n";

                        #print $fh_report "Autor: ".$Vari::author."\n";
                        if ( $Vari::author =~ m/$Marc::MARC100a/i )
                        { #kommt Autor in 100a vor? (ohne Gross-/Kleinschreibung zu beachten)
                            $Match::AUTHORMATCH = 10;
                        }    #else { $Match::AUTHORMATCH = 0; }
                             # debug:
                        print $fh_report "AUTHORMATCH: "
                          . $Match::AUTHORMATCH . "\n";
                    }

                }
                if (hasTag( "700", $xpc, $rec ) ) {
                    foreach $el ( $xpc->findnodes( './datafield[@tag=700]', $rec ) )
                    {
                        $Marc::MARC700a =
                          $xpc->findnodes( './subfield[@code="a"]', $el )
                          ->to_literal;

                        # debug:
                        print $fh_report "Feld 700a: " . $Marc::MARC700a . "\n";

                        #print $fh_report "Autor: ".$Vari::author."\n";
                        if ( $Marc::MARC700a =~ m/$Vari::author/i || $Marc::MARC700a =~ m/$Vari::author2/i)
                        { #kommt Autor oder Autor-2 in 700a vor? (ohne Gross-/Kleinschreibung zu beachten)
                            $Match::AUTHORMATCH += 10; # add 10 points
                        }    #else { $Match::AUTHORMATCH = 0; }
                             # debug:
                        print $fh_report "AUTHORMATCH: "
                          . $Match::AUTHORMATCH . "\n";
                    }   
                }
                if (hasTag("110", $xpc, $rec)) {
                    foreach $el ( $xpc->findnodes( './datafield[@tag=110]', $rec ) )
                    {
                        $Marc::MARC110a =
                          $xpc->findnodes( './subfield[@code="a"]', $el )
                          ->to_literal;

                        # debug:
                        print $fh_report "Feld 110a: " . $Marc::MARC110a . "\n";

                        if ( $Vari::author =~ m/$Marc::MARC110a/i )
                        { #kommt Autor in 110a vor? (ohne Gross-/Kleinschreibung zu beachten)
                            $Match::AUTHORMATCH += 10;
                        }    #else { $Match::AUTHORMATCH = 0; }
                             # debug:
                        print $fh_report "AUTHORMATCH: "
                          . $Match::AUTHORMATCH . "\n";
                    }
                }
                if (hasTag("710", $xpc, $rec)) {
                    foreach $el ( $xpc->findnodes( './datafield[@tag=710]', $rec ) )
                    {
                        $Marc::MARC710a =
                          $xpc->findnodes( './subfield[@code="a"]', $el )
                          ->to_literal;

                        # debug:
                        print $fh_report "Feld 710a: " . $Marc::MARC710a . "\n";

                        if ( $Vari::author =~ m/$Marc::MARC710a/i )
                        { #kommt Autor in 710a vor? (ohne Gross-/Kleinschreibung zu beachten)
                            $Match::AUTHORMATCH += 10;
                        }    #else { $Match::AUTHORMATCH = 0; }
                             # debug:
                        print $fh_report "AUTHORMATCH: "
                          . $Match::AUTHORMATCH . "\n";
                    }
                }
            }



            ## CHECK TITLE: TODO subtitle, title addons, etc., other marc fields (245b, 246b)
            
            if (hasTag("245",$xpc,$rec)){
                foreach $el ($xpc->findnodes('./datafield[@tag=245]', $rec)) {
                    $Match::TITLEMATCH = getMatchValue("a",$xpc,$el,$Vari::title,10);
                    print $fh_report "TITLEMATCH mit getMatchValue: " . $Match::TITLEMATCH . "\n";
                    
                }
            } 
            if (hasTag("246",$xpc,$rec)) {
                foreach $el ($xpc->findnodes('./datafield[@tag=246]', $rec)) {
                    $Match::TITLEMATCH = getMatchValue("a",$xpc,$el,$Vari::title,5);
                    print $fh_report "TITLEMATCH mit getMatchValue: " . $Match::TITLEMATCH . "\n";
                }
            } 
            
            # OLD TITLE CHECK:
            
            if ( $xpc->exists( './datafield[@tag="245"]', $rec ) ) {
                foreach $el ( $xpc->findnodes( './datafield[@tag=245]', $rec ) )
                {
                    $Marc::MARC245a =
                      $xpc->findnodes( './subfield[@code="a"]', $el )
                      ->to_literal;

                    # debug:
                    print $fh_report "Feld 245a: " . $Marc::MARC245a . "\n";

                    #print $fh_report "Titel: ".$Vari::title. "\n";

                    if ( $Marc::MARC245a =~ m/$Vari::title/i )
                    { #kommt Titel in 245a vor? (ohne Gross-/Kleinschreibung zu beachten)
                        $Match::TITLEMATCH = 10;
                    }
                    elsif ( ( substr $Marc::MARC245a, 0, 10 ) =~
                        m/$Vari::shorttitle/i )
                    {    #TODO: Kurztitellänge anpassen? Hier: 10 Zeichen.
                        $Match::TITLEMATCH = 5;
                    }

                    # debug:
                    print $fh_report "TITLEMATCH: " . $Match::TITLEMATCH . "\n";
                }
            }
            ## Year: Feld 008: pos. 07-10 - Date 1

            if (   $Flag::HAS_YEAR
                && $xpc->exists( './controlfield[@tag="008"]', $rec ) )
            {
                foreach $el (
                    $xpc->findnodes( './controlfield[@tag=008]', $rec ) )
                {
                    $Marc::MARC008 = $el->to_literal;
                    $Marc::MARC008 = substr $Marc::MARC008, 7, 4;

                    # debug:
                    print $fh_report "Feld 008: " . $Marc::MARC008 . "\n";

                    if ( $Marc::MARC008 eq $Vari::year ) {
                        $Match::YEARMATCH = 10;
                    }

                    # debug:
                    print $fh_report "YEARMATCH: " . $Match::YEARMATCH . "\n";
                }
            }
            
            # Place new:
            
            if ($Flag::HAS_PLACE) {
                if (hasTag("264", $xpc, $rec) || hasTag("260", $xpc, $rec)) {
                    foreach $el ( $xpc->findnodes( './datafield[@tag=264 or @tag=260]', $rec ) ) {
                        $Match::PLACEMATCH = getMatchValue("a",$xpc,$el,$Vari::place,5);
                        print $fh_report "PlaceMatch with getMatchValue: " . $Match::PLACEMATCH . "\n";
                    }
                }
            }

            # PLACE old:

            if (   $Flag::HAS_PLACE
                && $xpc->exists( './datafield[@tag="264"]', $rec ) )
            {    #264

                foreach $el ( $xpc->findnodes( './datafield[@tag=264]', $rec ) )
                {
                    $Marc::MARC264a =
                      $xpc->findnodes( './subfield[@code="a"]', $el )
                      ->to_literal;

                    # debug:
                    print $fh_report "Feld 264a: " . $Marc::MARC264a . "\n";

                    #print $fh_report "Ort: ".$Vari::place."\n";
                    if ( $Marc::MARC264a =~ m/$Vari::place/i ) {
                        $Match::PLACEMATCH = 5;
                    }    #else { $Match::PLACEMATCH = 0; }
                         # debug:
                    print $fh_report "P-Match: " . $Match::PLACEMATCH . "\n";
                }

            }
            elsif ($Flag::HAS_PLACE
                && $xpc->exists( './datafield[@tag="260"]', $rec ) )
            {            # 260

                foreach $el ( $xpc->findnodes( './datafield[@tag=260]', $rec ) )
                {
                    $Marc::MARC260a =
                      $xpc->findnodes( './subfield[@code="a"]', $el )
                      ->to_literal;

                    # debug:
                    print $fh_report "Feld 260a: " . $Marc::MARC260a . "\n";

                    #print $fh_report "Ort: ".$Vari::place."\n";
                    if ( $Marc::MARC260a =~ m/$Vari::place/i ) {
                        $Match::PLACEMATCH = 5;
                    }    #else { $Match::PLACEMATCH = 0; }
                         # debug:
                    print $fh_report "PLACEMATCH: " . $Match::PLACEMATCH . "\n";
                }
            }
            
            #Publisher new:
            
            if ($Flag::HAS_PUBLISHER) {
                if (hasTag("264", $xpc, $rec) || hasTag("260", $xpc, $rec)) {
                    foreach $el ( $xpc->findnodes( './datafield[@tag=264 or @tag=260]', $rec ) ) {
                        $Match::PUBLISHERMATCH = getMatchValue("b",$xpc,$el,$Vari::publisher,5);
                        print $fh_report "Publisher-Match with getMatchValue: " . $Match::PUBLISHERMATCH . "\n";
                    }
                }
            }

            # PUBLISHER OLD: TODO: nur das 1. Wort vergleichen oder alles nach / abschneiden.

            if (   $Flag::HAS_PUBLISHER
                && $xpc->exists( './datafield[@tag="264"]', $rec ) )
            {            #264

                foreach $el ( $xpc->findnodes( './datafield[@tag=264]', $rec ) )
                {
                    $Marc::MARC264b =
                      $xpc->findnodes( './subfield[@code="b"]', $el )
                      ->to_literal;

                    # debug:
                    print $fh_report "Feld 264b: " . $Marc::MARC264b . "\n";

                    #print $fh_report "Verlag: ".$Vari::publisher."\n";
                    if ( $Marc::MARC264b =~ m/$Vari::publisher/i ) {
                        $Match::PUBLISHERMATCH = 5;
                    }    #else { $Match::PUBLISHERMATCH = 0; }
                         # debug:
                    print $fh_report "PUBLISHERMATCH: "
                      . $Match::PUBLISHERMATCH . "\n";
                }

            }
            elsif ($Flag::HAS_PUBLISHER
                && $xpc->exists( './datafield[@tag="260"]', $rec ) )
            {            # 260
                foreach $el ( $xpc->findnodes( './datafield[@tag=260]', $rec ) )
                {
                    $Marc::MARC260b =
                      $xpc->findnodes( './subfield[@code="b"]', $el )
                      ->to_literal;

                    # debug:
                    print $fh_report "Feld 260b: " . $Marc::MARC260b . "\n";

                    #print $fh_report "Verlag: ".$Vari::publisher."\n";
                    if ( $Marc::MARC260b =~ m/$Vari::publisher/i ) {
                        $Match::PUBLISHERMATCH = 5;
                    }    #else { $Match::PUBLISHERMATCH = 0; }
                         # debug:
                    print $fh_report "PUBLISHERMATCH: "
                      . $Match::PUBLISHERMATCH . "\n";
                }
            }

            #MATERIAL: LDR-Werte
            if ( $xpc->exists( './leader', $rec ) ) {
                foreach $el ( $xpc->findnodes( './leader', $rec ) ) {
                    $Marc::LDR = $el->to_literal;
                    $Marc::LDR = substr $Marc::LDR, 7, 1;

                    # debug:
                    print $fh_report "LDR Materialart: " . $Marc::LDR . "\n";

                    if ( $Flag::NO_MONOGRAPH =~ m/$Marc::LDR/ ) {
                        $Match::MATERIALMATCH = 15;
                    }

                    # debug:
                    print $fh_report "MATERIALMATCH: "
                      . $Match::MATERIALMATCH . "\n";
                }
            }

            #Get Swissbib System Nr., Field 001: 
            #http://www.swissbib.org/wiki/index.php?title=Swissbib_marc

            if ( $xpc->exists( './controlfield[@tag="001"]', $rec ) ) {
                foreach $el (
                    $xpc->findnodes( './controlfield[@tag=001]', $rec ) )
                {
                    $Marc::MARC001 = $el->to_literal;

                    # debug:
                    print $fh_report "Swissbibnr.: " . $Marc::MARC001 . "\n";

                }
            }

            #Get 035 Field and check if old IFF data.
            if ( $xpc->exists( './datafield[@tag="035"]', $rec ) ) {
                foreach $el (
                    $xpc->findnodes( './datafield[@tag=035 ]', $rec ) )
                {
                    $Marc::MARC035a =
                      $xpc->findnodes( './subfield[@code="a"]', $el )
                      ->to_literal;
                    print $fh_report "Feld 035a: " . $Marc::MARC035a . "\n"
                      unless ( $Marc::MARC035a =~ /OCoLC/ );

                    if ( $Marc::MARC035a =~ /IDSSG/ ) {    # book found in IDSSG
                        $Match::bibnr = substr $Marc::MARC035a,
                          -7;    #only the last 7 numbers
                        if ( $Match::bibnr > 990000 ) {   #this is an IFF record
                            $Match::IFFMATCH = 15;        # negative points
                            $Flag::iff2replace = $Marc::MARC001;
                            print $fh_report "Abzug fuer IFF_MATCH: -"
                              . $Match::IFFMATCH . "\n";
                        }
                        else {
                            $Match::IDSSGMATCH = 21;    # a lot of plus points!
                            print $fh_report
                              "Zuschlag fuer altes HSG-Katalogisat: "
                              . $Match::IDSSGMATCH . "\n";
                            if ( $xpc->exists( './datafield[@tag="949"]', $rec )
                              )
                            {
                                foreach $el (
                                    $xpc->findnodes(
                                        './datafield[@tag=949 ]', $rec
                                    )
                                  )
                                {
                                    $Marc::MARC949F =
                                      $xpc->findnodes( './subfield[@code="F"]',
                                        $el )->to_literal;
                                    if ( $Marc::MARC949F =~ /HIFF/ ) {
                                        print $fh_report "Feld 949: "
                                          . $Marc::MARC949F . "\n";
                                        $Match::IDSSGMATCH += 10;
                                        print $fh_report
                                          "HIFF already attached, IDSSGMATCH = "
                                          . $Match::IDSSGMATCH . "\n";
                                        $Flag::iff2replace = $Marc::MARC001;
                                        $Flag::bestcase    = 1;
                                    }

                                }

                            }
                        }

                    }
                    else {
                        if ( $Marc::MARC035a =~ m/RERO/ )
                        {    #book from RERO slightly preferred to others
                            $Match::IDSMATCH = 4;
                            print $fh_report "REROMATCH: "
                              . $Match::IDSMATCH . "\n";
                        }
                        if ( $Marc::MARC035a =~ m/SGBN/ )
                        { #book from SGBN  slight preference over others if not IDS

                            $Match::IDSMATCH = 6;
                            print $fh_report "SGBNMATCH: "
                              . $Match::IDSMATCH . "\n";
                        }
                        if (   $Marc::MARC035a =~ m/IDS/
                            || $Marc::MARC035a =~ /NEBIS/ )
                        {    #book from IDS Library preferred

                            $Match::IDSMATCH = 9;
                            print $fh_report "IDSMATCH: "
                              . $Match::IDSMATCH . "\n";
                        }

                    }
                }
            }

            $i++;
            $Match::TOTALMATCH =
              ( $Match::TITLEMATCH +
                  $Match::AUTHORMATCH +
                  $Match::YEARMATCH +
                  $Match::PUBLISHERMATCH +
                  $Match::PLACEMATCH +
                  $Match::MATERIALMATCH +
                  $Match::IDSMATCH +
                  $Match::IDSSGMATCH -
                  $Match::IFFMATCH );

            print $fh_report "Totalmatch: " . $Match::TOTALMATCH . "\n";

            if ( $Match::TOTALMATCH > $Match::bestmatch )
            { #ist aktueller Match-Total der höchste aus Trefferliste? wenn ja:
                $Match::bestmatch  = $Match::TOTALMATCH; # schreibe in bestmatch
                $Match::bestrecord = $rec;               # speichere record weg.
                $Match::bestrecordnr =
                  $Marc::MARC001;    # Swissbib-Nr. des records
            }

        }

# TODO: if correct, write out as marcxml, if false, do another query with more parameters
#        push @found, "\n", $found_nr, $Vari::isbn, $Vari::title, $Vari::author, $Vari::year;
        $found_nr++;

        print $fh_report "Bestmatch: "
          . $Match::bestmatch
          . ", Bestrecordnr: "
          . $Match::bestrecordnr . "\n";

        if ( $Match::bestmatch >= 25 ) {    #wenn guter Treffer gefunden

            if ( $Flag::iff2replace eq $Match::bestrecordnr ) {
                if ($Flag::bestcase) {
                    print $fh_report
                      "Best case scenario: IFF and HSG already matched!\n";
                }
                else {
                    print $fh_report
                      "Only IFF data available. Best solution from Felix.\n";

                }
            }
            else {
                $replace_nr++;
                if ( $Flag::iff2replace !~ /$EMPTY_CELL/ ) {
                    print $fh_report "Ersetzen: alt "
                      . $Flag::iff2replace
                      . " mit neu "
                      . $Match::bestrecordnr . "\n";
                }
                else {
                    print $fh_report
"Ersetzen. FEHLER: IFF_Kata nicht gefunden. Manuell suchen und ersetzen mit "
                      . $Match::bestrecordnr . "\n";
                }

                #IFF-Signatur anhängen
                $Match::bestrecord->appendWellBalancedChunk(
'<datafield tag="949" ind1=" " ind2=" "><subfield code="B">IDSSG</subfield><subfield code="F">HIFF</subfield><subfield code="c">BIB</subfield><subfield code="j">'
                      . $Vari::callno
                      . '</subfield></datafield>' );

                #TODO: Schlagworte IFF einfügen
                #TODO: unnötige Exemplardaten etc. rauslöschen.
                print $fh_export $Match::bestrecord->toString . "\n";
            }

        }
        else {
            print $fh_report "BESTMATCH ziemlich tief, überprüfen!";
            push @unsure, "\n", $unsure_nr, $Vari::isbn, $Vari::title,
              $Vari::author, $Vari::year;
            $unsure_nr++;
        }
    }
    else {
        # TODO: something wrong with query.
        if ( $numberofrecords != 0 ) {
            print $fh_report "Suchparameter stimmen nicht !!!\n";
        }        
        print $fh_report
          "*****************************************************\n\n";

    }

}

$csv->eof or $csv->error_diag();
close $fh_in;

$csv->print( $fh_notfound, \@notfound );
$csv->print( $fh_unsure,   \@unsure );
$csv->print($fh_journals, \@journals);
$csv->print($fh_other, \@no_monograph); # not working for some reason (value undefined))

close $fh_notfound or die "notfound.csv: $!";
close $fh_unsure   or die "unsure.csv: $!";
close $fh_journals or die "journals.csv: $!";
close $fh_other or die "no_monograph.csv: $!";
close $fh_report   or die "report.txt: $!";
close $fh_export   or die "swissbibexport.xml: $!";

print "Total found: " . $found_nr . "\n";
print "Total to replace: " . $replace_nr . "\n";
print "Total unsure: " . $unsure_nr . "\n";
print "Total journals: " . $journal_nr. "\n";
print "Total not monographs: " . $no_monograph_nr. "\n";
print "Total not found: " . $notfound_nr . "\n";

####################

# SUBROUTINES

#####################

# reset all flags to default value

sub resetFlags {

    $Flag::HAS_ISBN      = 1;
    $Flag::HAS_ISBN2     = 0;
    $Flag::HAS_AUTHOR    = 1;
    $Flag::HAS_AUTHOR2   = 0;
    $Flag::HAS_AUTHORITY = 0;
    $Flag::HAS_SUBTITLE  = 0;
    $Flag::HAS_VOLUME    = 0;
    $Flag::HAS_TITLEDATE = 0;
    $Flag::HAS_YEAR      = 1;
    $Flag::HAS_PAGES     = 1;
    $Flag::HAS_PAGERANGE = 0;
    $Flag::HAS_PLACE     = 1;
    $Flag::HAS_PUBLISHER = 1;
    $Flag::NO_MONOGRAPH  = 'm';
    $Flag::iff2replace   = "";
    $Flag::bestcase      = 0;

    #$Flag::HAS_HIFF      = 0;

}

# reset all match variables to default value

sub resetMatch {

    $Match::AUTHORMATCH    = 0;
    $Match::TITLEMATCH     = 0;
    $Match::YEARMATCH      = 0;
    $Match::PUBLISHERMATCH = 0;
    $Match::PLACEMATCH     = 0;
    $Match::MATERIALMATCH  = 0;
    $Match::IDSSGMATCH     = 0;
    $Match::IFFMATCH       = 0;
    $Match::TOTALMATCH     = 0;
    $Match::IDSMATCH       = 0;

}

# empty Variables

sub emptyVariables {

    $Vari::isbn2 = "";

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
    my $path   = $_[1];     #xpc
    my $element = $_[2];    #el
    my $vari  = $_[3];    #orignal data from csv
    my $posmatch = $_[4];    #which match value shoud be assigned to positive match?
    my $matchvalue;
    my $marcfield = '';
    my $shortvari = substr $vari, 0,10;
    
    
    $marcfield = $path->findnodes( './subfield[@code=' . $code . ']', $element)->to_literal;
    #$marcfield = $path->findvalue( './subfield[@code=' . $code . ']', $element);

    # debug: this does not work, why???
    #print $fh_report "marcfield: " . $marcfield . "\n";
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