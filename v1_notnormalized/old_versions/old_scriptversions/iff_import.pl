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
use Time::HiRes qw ( time );

my $starttime = time();

##########################################################
#	DECLARE NECESSARY VARIABLES
##########################################################

# input variables from csv file
my ($row, $csv);
my ($bibnr, $swissbibnr, $callnr, $code1, $code2, $code3, $keyword1, $keyword2, $keyword3);
my $subject_map = "iff_subject_table.map";

# input, output, filehandles:
my ($fh_in, $fh_out);
#my $file_in = "export.csv";
my $file_in = "re_import.csv";
my $file_out = "metadata.xml";

# Swissbib SRU-Service for the complete content of Swissbib: MARC XML-swissbib (less namespaces), default = 10 records
# This programm only handles searches by id
my $server_endpoint = 'http://sru.swissbib.ch/sru/search/defaultdb?&operation=searchRetrieve'.
'&recordSchema=info%3Asrw%2Fschema%2F1%2Fmarcxml-v1.1-light&maximumRecords=10&query=+dc.id+%3D+';
my $sruquery;

# XML-Variables
my ($dom, $xpc, $numberofrecords, $rec, $delete, $append, $el, $i);
my @record;

# open input/output:
$csv =  Text::CSV->new( { binary => 1, sep_char => ";" } ) or die "Cannot use CSV: " . Text::CSV->error_diag();
open $fh_in, "<:encoding(utf8)", $file_in or die "$file_in: $!";
open $fh_out, ">:encoding(utf8)", $file_out or die "$file_out: $!";

# read each line and do...:

while ($row = $csv->getline($fh_in)) {
	
	#get all necessary variables	
	$callnr = $row->[9];
	$code1 = $row->[14];
	$code2 = $row->[15];
	$code3 = $row->[16];
	$keyword1 = $row->[17];
	$swissbibnr = $row->[20];
	$bibnr = $row->[21];
	
	$sruquery = $server_endpoint . $swissbibnr;
	
	print "URL: \n" . $sruquery . "\n";

    # load xml as DOM object, # register namespaces of xml
    $dom = XML::LibXML->load_xml( location => $sruquery );
    $xpc = XML::LibXML::XPathContext->new($dom);
    
    # get nodes of records with XPATH
    @record = $xpc->findnodes( '/searchRetrieveResponse/records/record/recordData/record');
        
   	if ($xpc->exists('/searchRetrieveResponse/numberOfRecords')) {
    	$numberofrecords = $xpc->findvalue('/searchRetrieveResponse/numberOfRecords');
    } 

    # debug:
    print "Treffer: " . $numberofrecords . "\n";
    
    foreach $rec (@record) {
    	# print "Original rec:\n".$rec;
    	# TODO: LDR anpassen? ZB Katalevel?
    	# delete all controllfields except 008?
    	for $delete ($rec->findnodes('./controlfield[@tag>="001" and @tag<="007"]')) {
    		$delete->unbindNode();
    	}

    	# delete all 035 fields     	# TODO: leave OCLCNR, or leave all of them?
    	for $delete ($rec->findnodes('./datafield[@tag="035"]')) {
    		$delete->unbindNode() ; #unless /OCoLC/
    	}
    	# append our code to 040: SzZuIDS HSG
    	# TODO: also $b ger, $e rda?    	
    	for $append ($rec-> findnodes('./datafield[@tag="040"]')) {
    		$append->appendWellBalancedChunk('<subfield code="d">SzZuIDS HSG</subfield>');
    	}
    	# TODO deal with linking fields, eg. 490, 77X, 78X
    	
    	# create 690 fields with keywords #TODO correct utf-8 (umlaut)
    	$rec->appendWellBalancedChunk('<datafield tag="690" ind1="H" ind2="D"><subfield code="8">'.$code1.'</subfield>'.
    	'<subfield code="a">'.$keyword1.'</subfield></datafield>'); # TODO: keywords from mapping table 
    	
    	# delete all 949 fields
    	# delete all 89# fields (Swissbib internal)
		for $delete ($rec->findnodes('./datafield[@tag="949"]')) {
    		$delete->unbindNode();
    	}  	    	

		for $delete ($rec->findnodes('./datafield[@tag>="890" and @tag<="899"]')) {
    		$delete->unbindNode();
    	}
    	
    	# TODO: 950-fields, what about them? convert to 690?

    	# create a new 949 field with callno. 
    	$rec->appendWellBalancedChunk('<datafield tag="949" ind1=" " ind2=" "><subfield code="B">IDSSG</subfield>'.
    	'<subfield code="F">HIFF</subfield><subfield code="c">BIB</subfield><subfield code="j">'.$callnr.'</subfield></datafield>');
    	
    	# print
    	print "Treated rec:\n".$rec;
    	
    	
    }
	
	
}
